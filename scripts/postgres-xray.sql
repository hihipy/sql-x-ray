-- =====================================================================
-- postgres-xray.sql
-- =====================================================================
-- sql-x-ray: See the structure, not the data.
-- https://github.com/hihipy/sql-x-ray
--
-- Privacy-safe PostgreSQL schema introspection for LLM context.
--
-- WHAT THIS DOES
--   Outputs a single jsonb document describing the SHAPE of a PostgreSQL
--   database: tables, columns, types, relationships, indexes, and
--   constraint existence. Designed to be fed to any LLM as priming
--   context so it can write accurate queries against your schema.
--
-- WHAT THIS DELIBERATELY DOES NOT INCLUDE
--   This script never extracts values that could carry sensitive data:
--     - No enum value labels (could be clinical / financial / personal)
--     - No check constraint expressions (could contain literal values)
--     - No default-value literals (could contain literal values)
--     - No view definitions or function bodies (could contain logic
--       that filters or describes sensitive data)
--     - No table/column descriptions (free text, could be anything)
--     - No row data of any kind
--   It DOES include the *existence* and *count* of each of the above,
--   so an LLM knows the construct is there without seeing what's in it.
--
-- COMPATIBILITY
--   PostgreSQL 12 or newer. No extensions required.
--   Tested on PostgreSQL 17 (with PostGIS) and PostgreSQL 18.
--
-- USAGE
--   Edit the `params` CTE below to target a schema, then run.
--   Result is a single cell containing a pretty-printed JSON document.
--   Save the cell contents as schema.json and feed to your LLM.
--
-- LICENSE
--   CC BY-NC-SA 4.0 - https://creativecommons.org/licenses/by-nc-sa/4.0/
-- =====================================================================

WITH params AS (
    SELECT
        ------------------------------------------------------------------
        -- Schema filter. Examples:
        --   'public'            single schema
        --   'app_%'             LIKE pattern
        --   '%'                 every non-system schema
        ------------------------------------------------------------------
        '%'::text  AS schema_filter,

        ------------------------------------------------------------------
        -- When TRUE, the default schema 'public' is excluded if empty.
        -- Avoids noise on databases that don't use the public schema.
        ------------------------------------------------------------------
        TRUE       AS exclude_empty_public,

        ------------------------------------------------------------------
        -- Include estimated row counts and on-disk sizes.
        -- Useful for LLM to understand scale; slightly slower on huge DBs.
        ------------------------------------------------------------------
        TRUE       AS include_stats,

        ------------------------------------------------------------------
        -- Pretty-print the JSON output (line breaks, indentation).
        ------------------------------------------------------------------
        TRUE       AS pretty_print
),

-- ---------------------------------------------------------------------
-- Extension-owned relations: tables, views, and sequences created by
-- installed extensions (PostGIS spatial_ref_sys/geometry_columns,
-- Supabase auth.users, pg_stat_statements, etc.). Excluded so the dump
-- shows only the user's actual schema, not the plumbing.
-- ---------------------------------------------------------------------
extension_owned AS (
    SELECT d.objid AS oid
    FROM pg_depend d
    WHERE d.deptype = 'e'
      AND d.classid = 'pg_class'::regclass
),

-- ---------------------------------------------------------------------
-- Resolve target schemas, optionally dropping empty public schemas.
-- The "empty" check ignores extension-owned objects, so a schema that
-- only holds PostGIS or Supabase plumbing still counts as empty.
-- ---------------------------------------------------------------------
candidate_schemas AS (
    SELECT n.oid AS schema_oid, n.nspname AS schema_name
    FROM pg_namespace n
    CROSS JOIN params
    WHERE n.nspname LIKE params.schema_filter
      AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
      AND n.nspname NOT LIKE 'pg_temp_%'
      AND n.nspname NOT LIKE 'pg_toast_temp_%'
),
target_schemas AS (
    SELECT cs.schema_oid, cs.schema_name
    FROM candidate_schemas cs
    CROSS JOIN params
    WHERE NOT (
        params.exclude_empty_public
        AND cs.schema_name = 'public'
        AND NOT EXISTS (
            SELECT 1 FROM pg_class c
            WHERE c.relnamespace = cs.schema_oid
              AND c.relkind IN ('r', 'p', 'f', 'v', 'm', 'S')
              AND NOT EXISTS (
                  SELECT 1 FROM extension_owned eo WHERE eo.oid = c.oid
              )
        )
    )
),

-- =====================================================================
-- COLUMNS (structure only, no defaults, no descriptions)
-- =====================================================================
cols AS (
    SELECT
        ts.schema_name,
        c.relname AS table_name,
        jsonb_agg(
            jsonb_build_object(
                'name',         a.attname,
                'position',     a.attnum,
                'data_type',    format_type(a.atttypid, a.atttypmod),
                'nullable',     NOT a.attnotnull,
                'is_identity',  a.attidentity <> '',
                'is_generated', a.attgenerated <> '',
                'has_default',  ad.adbin IS NOT NULL
            )
            ORDER BY a.attnum
        ) AS columns
    FROM pg_class c
    JOIN target_schemas ts ON ts.schema_oid = c.relnamespace
    JOIN pg_attribute a ON a.attrelid = c.oid
    LEFT JOIN pg_attrdef ad ON ad.adrelid = a.attrelid AND ad.adnum = a.attnum
    WHERE c.relkind IN ('r', 'p', 'f')
      AND a.attnum > 0
      AND NOT a.attisdropped
      AND NOT EXISTS (SELECT 1 FROM extension_owned eo WHERE eo.oid = c.oid)
    GROUP BY ts.schema_name, c.relname
),

-- =====================================================================
-- PRIMARY KEYS
-- =====================================================================
pks AS (
    SELECT
        ts.schema_name,
        c.relname AS table_name,
        jsonb_build_object(
            'columns', (
                SELECT jsonb_agg(att.attname ORDER BY u.ord)
                FROM unnest(con.conkey) WITH ORDINALITY AS u(attnum, ord)
                JOIN pg_attribute att
                  ON att.attrelid = con.conrelid AND att.attnum = u.attnum
            )
        ) AS primary_key
    FROM pg_constraint con
    JOIN pg_class c ON c.oid = con.conrelid
    JOIN target_schemas ts ON ts.schema_oid = c.relnamespace
    WHERE con.contype = 'p'
      AND NOT EXISTS (SELECT 1 FROM extension_owned eo WHERE eo.oid = c.oid)
),

-- =====================================================================
-- FOREIGN KEYS (the relationship map)
-- =====================================================================
fks AS (
    SELECT
        ts.schema_name,
        c.relname AS table_name,
        jsonb_agg(
            jsonb_build_object(
                'from_columns', (
                    SELECT jsonb_agg(att.attname ORDER BY u.ord)
                    FROM unnest(con.conkey) WITH ORDINALITY AS u(attnum, ord)
                    JOIN pg_attribute att
                      ON att.attrelid = con.conrelid AND att.attnum = u.attnum
                ),
                'to_schema',  rn.nspname,
                'to_table',   rc.relname,
                'to_columns', (
                    SELECT jsonb_agg(att.attname ORDER BY u.ord)
                    FROM unnest(con.confkey) WITH ORDINALITY AS u(attnum, ord)
                    JOIN pg_attribute att
                      ON att.attrelid = con.confrelid AND att.attnum = u.attnum
                ),
                'on_update', CASE con.confupdtype
                                WHEN 'a' THEN 'NO ACTION'
                                WHEN 'r' THEN 'RESTRICT'
                                WHEN 'c' THEN 'CASCADE'
                                WHEN 'n' THEN 'SET NULL'
                                WHEN 'd' THEN 'SET DEFAULT'
                             END,
                'on_delete', CASE con.confdeltype
                                WHEN 'a' THEN 'NO ACTION'
                                WHEN 'r' THEN 'RESTRICT'
                                WHEN 'c' THEN 'CASCADE'
                                WHEN 'n' THEN 'SET NULL'
                                WHEN 'd' THEN 'SET DEFAULT'
                             END
            )
            ORDER BY con.conname
        ) AS foreign_keys
    FROM pg_constraint con
    JOIN pg_class c  ON c.oid = con.conrelid
    JOIN target_schemas ts ON ts.schema_oid = c.relnamespace
    JOIN pg_class rc ON rc.oid = con.confrelid
    JOIN pg_namespace rn ON rn.oid = rc.relnamespace
    WHERE con.contype = 'f'
      AND NOT EXISTS (SELECT 1 FROM extension_owned eo WHERE eo.oid = c.oid)
    GROUP BY ts.schema_name, c.relname
),

-- =====================================================================
-- UNIQUE CONSTRAINTS
-- =====================================================================
uqs AS (
    SELECT
        ts.schema_name,
        c.relname AS table_name,
        jsonb_agg(
            jsonb_build_object(
                'columns', (
                    SELECT jsonb_agg(att.attname ORDER BY u.ord)
                    FROM unnest(con.conkey) WITH ORDINALITY AS u(attnum, ord)
                    JOIN pg_attribute att
                      ON att.attrelid = con.conrelid AND att.attnum = u.attnum
                )
            )
            ORDER BY con.conname
        ) AS unique_constraints
    FROM pg_constraint con
    JOIN pg_class c ON c.oid = con.conrelid
    JOIN target_schemas ts ON ts.schema_oid = c.relnamespace
    WHERE con.contype = 'u'
      AND NOT EXISTS (SELECT 1 FROM extension_owned eo WHERE eo.oid = c.oid)
    GROUP BY ts.schema_name, c.relname
),

-- =====================================================================
-- CHECK CONSTRAINT COUNTS (existence only, no expressions)
-- =====================================================================
checks AS (
    SELECT
        ts.schema_name,
        c.relname AS table_name,
        COUNT(*)::int AS check_constraint_count
    FROM pg_constraint con
    JOIN pg_class c ON c.oid = con.conrelid
    JOIN target_schemas ts ON ts.schema_oid = c.relnamespace
    WHERE con.contype = 'c'
      AND NOT EXISTS (SELECT 1 FROM extension_owned eo WHERE eo.oid = c.oid)
    GROUP BY ts.schema_name, c.relname
),

-- =====================================================================
-- INDEXES (with proper handling of expression columns and INCLUDE)
-- Excludes indexes backing PK / unique constraints to avoid duplication.
-- Expression indexes (e.g. lower(name)) emit "<expression>" in place of
-- the column name to signal existence without revealing content.
-- =====================================================================
idx AS (
    SELECT
        ts.schema_name,
        c.relname AS table_name,
        jsonb_agg(
            jsonb_build_object(
                'name',    i.relname,
                'method',  am.amname,
                'unique',  ix.indisunique,
                'partial', ix.indpred IS NOT NULL,
                'columns', (
                    SELECT jsonb_agg(
                        CASE
                            WHEN u.attnum = 0 THEN '<expression>'
                            ELSE att.attname
                        END
                        ORDER BY u.ord
                    )
                    FROM unnest(ix.indkey::int[]) WITH ORDINALITY AS u(attnum, ord)
                    LEFT JOIN pg_attribute att
                      ON att.attrelid = ix.indrelid AND att.attnum = u.attnum
                    WHERE u.ord <= ix.indnkeyatts
                ),
                'included_columns', CASE
                    WHEN array_length(ix.indkey::int[], 1) > ix.indnkeyatts THEN (
                        SELECT jsonb_agg(att.attname ORDER BY u.ord)
                        FROM unnest(ix.indkey::int[]) WITH ORDINALITY AS u(attnum, ord)
                        LEFT JOIN pg_attribute att
                          ON att.attrelid = ix.indrelid AND att.attnum = u.attnum
                        WHERE u.ord > ix.indnkeyatts
                    )
                END
            )
            ORDER BY i.relname
        ) AS indexes
    FROM pg_index ix
    JOIN pg_class c  ON c.oid = ix.indrelid
    JOIN pg_class i  ON i.oid = ix.indexrelid
    JOIN pg_am   am  ON am.oid = i.relam
    JOIN target_schemas ts ON ts.schema_oid = c.relnamespace
    WHERE NOT ix.indisprimary
      AND NOT EXISTS (
          SELECT 1 FROM pg_constraint con
          WHERE con.conindid = ix.indexrelid AND con.contype = 'u'
      )
      AND NOT EXISTS (SELECT 1 FROM extension_owned eo WHERE eo.oid = c.oid)
    GROUP BY ts.schema_name, c.relname
),

-- =====================================================================
-- TRIGGER COUNTS (existence only, no definitions)
-- =====================================================================
trgs AS (
    SELECT
        ts.schema_name,
        c.relname AS table_name,
        COUNT(*)::int AS trigger_count
    FROM pg_trigger t
    JOIN pg_class c ON c.oid = t.tgrelid
    JOIN target_schemas ts ON ts.schema_oid = c.relnamespace
    WHERE NOT t.tgisinternal
      AND NOT EXISTS (SELECT 1 FROM extension_owned eo WHERE eo.oid = c.oid)
    GROUP BY ts.schema_name, c.relname
),

-- =====================================================================
-- INHERITANCE / PARTITION PARENTS
-- =====================================================================
inh AS (
    SELECT
        ts.schema_name,
        child.relname AS table_name,
        jsonb_agg(
            jsonb_build_object(
                'schema', pn.nspname,
                'table',  parent.relname
            )
            ORDER BY parent.relname
        ) AS inherits_from
    FROM pg_inherits h
    JOIN pg_class child  ON child.oid  = h.inhrelid
    JOIN pg_class parent ON parent.oid = h.inhparent
    JOIN pg_namespace pn ON pn.oid     = parent.relnamespace
    JOIN target_schemas ts ON ts.schema_oid = child.relnamespace
    WHERE NOT EXISTS (SELECT 1 FROM extension_owned eo WHERE eo.oid = child.oid)
    GROUP BY ts.schema_name, child.relname
),

-- =====================================================================
-- TABLE METADATA (kind, partition flag)
-- =====================================================================
tbl_meta AS (
    SELECT
        ts.schema_name,
        c.relname AS table_name,
        CASE c.relkind
            WHEN 'r' THEN 'table'
            WHEN 'p' THEN 'partitioned_table'
            WHEN 'f' THEN 'foreign_table'
        END AS kind,
        c.relispartition AS is_partition
    FROM pg_class c
    JOIN target_schemas ts ON ts.schema_oid = c.relnamespace
    WHERE c.relkind IN ('r', 'p', 'f')
      AND NOT EXISTS (SELECT 1 FROM extension_owned eo WHERE eo.oid = c.oid)
),

stats AS (
    SELECT
        s.schemaname AS schema_name,
        s.relname    AS table_name,
        s.n_live_tup AS row_count_estimate,
        pg_total_relation_size(format('%I.%I', s.schemaname, s.relname)) AS total_size_bytes
    FROM pg_stat_user_tables s
    JOIN target_schemas ts ON ts.schema_name = s.schemaname
    WHERE (SELECT include_stats FROM params)
      AND NOT EXISTS (SELECT 1 FROM extension_owned eo WHERE eo.oid = s.relid)
),

-- =====================================================================
-- ASSEMBLE TABLES
-- =====================================================================
tables_json AS (
    SELECT jsonb_agg(
        jsonb_strip_nulls(jsonb_build_object(
            'schema',                  tm.schema_name,
            'name',                    tm.table_name,
            'kind',                    tm.kind,
            'is_partition',            CASE WHEN tm.is_partition THEN TRUE END,
            'row_count_estimate',      st.row_count_estimate,
            'total_size_bytes',        st.total_size_bytes,
            'inherits_from',           inh.inherits_from,
            'primary_key',             pks.primary_key,
            'foreign_keys',            fks.foreign_keys,
            'unique_constraints',      uqs.unique_constraints,
            'check_constraint_count',  COALESCE(checks.check_constraint_count, 0),
            'indexes',                 idx.indexes,
            'trigger_count',           COALESCE(trgs.trigger_count, 0),
            'columns',                 cols.columns
        ))
        ORDER BY tm.schema_name, tm.table_name
    ) AS payload
    FROM tbl_meta tm
    LEFT JOIN cols   ON cols.schema_name   = tm.schema_name AND cols.table_name   = tm.table_name
    LEFT JOIN pks    ON pks.schema_name    = tm.schema_name AND pks.table_name    = tm.table_name
    LEFT JOIN fks    ON fks.schema_name    = tm.schema_name AND fks.table_name    = tm.table_name
    LEFT JOIN uqs    ON uqs.schema_name    = tm.schema_name AND uqs.table_name    = tm.table_name
    LEFT JOIN checks ON checks.schema_name = tm.schema_name AND checks.table_name = tm.table_name
    LEFT JOIN idx    ON idx.schema_name    = tm.schema_name AND idx.table_name    = tm.table_name
    LEFT JOIN trgs   ON trgs.schema_name   = tm.schema_name AND trgs.table_name   = tm.table_name
    LEFT JOIN inh    ON inh.schema_name    = tm.schema_name AND inh.table_name    = tm.table_name
    LEFT JOIN stats  st ON st.schema_name  = tm.schema_name AND st.table_name     = tm.table_name
),

-- =====================================================================
-- VIEWS / MATERIALIZED VIEWS (existence + column list only)
-- =====================================================================
view_cols AS (
    SELECT
        ts.schema_name,
        c.relname AS view_name,
        jsonb_agg(
            jsonb_build_object(
                'name',      a.attname,
                'position',  a.attnum,
                'data_type', format_type(a.atttypid, a.atttypmod),
                'nullable',  NOT a.attnotnull
            )
            ORDER BY a.attnum
        ) AS columns
    FROM pg_class c
    JOIN target_schemas ts ON ts.schema_oid = c.relnamespace
    JOIN pg_attribute a ON a.attrelid = c.oid
    WHERE c.relkind IN ('v', 'm')
      AND a.attnum > 0
      AND NOT a.attisdropped
      AND NOT EXISTS (SELECT 1 FROM extension_owned eo WHERE eo.oid = c.oid)
    GROUP BY ts.schema_name, c.relname
),

views_json AS (
    SELECT jsonb_agg(
        jsonb_build_object(
            'schema',  ts.schema_name,
            'name',    c.relname,
            'kind',    CASE c.relkind
                          WHEN 'v' THEN 'view'
                          WHEN 'm' THEN 'materialized_view'
                       END,
            'columns', vc.columns
        )
        ORDER BY ts.schema_name, c.relname
    ) AS payload
    FROM pg_class c
    JOIN target_schemas ts ON ts.schema_oid = c.relnamespace
    LEFT JOIN view_cols vc
      ON vc.schema_name = ts.schema_name AND vc.view_name = c.relname
    WHERE c.relkind IN ('v', 'm')
      AND NOT EXISTS (SELECT 1 FROM extension_owned eo WHERE eo.oid = c.oid)
),

-- =====================================================================
-- ROUTINES (signatures only, no bodies)
-- Filters extension-owned and built-in C/internal functions.
-- =====================================================================
routines_json AS (
    SELECT jsonb_agg(
        jsonb_build_object(
            'schema',     ts.schema_name,
            'name',       p.proname,
            'kind',       CASE p.prokind
                              WHEN 'f' THEN 'function'
                              WHEN 'p' THEN 'procedure'
                              WHEN 'a' THEN 'aggregate'
                              WHEN 'w' THEN 'window'
                          END,
            'language',   l.lanname,
            'returns',    pg_get_function_result(p.oid),
            'arguments',  pg_get_function_arguments(p.oid),
            'is_trigger', pg_get_function_result(p.oid) = 'trigger'
        )
        ORDER BY ts.schema_name, p.proname
    ) AS payload
    FROM pg_proc p
    JOIN pg_language l ON l.oid = p.prolang
    JOIN target_schemas ts ON ts.schema_oid = p.pronamespace
    WHERE l.lanname NOT IN ('c', 'internal')
      AND NOT EXISTS (
          SELECT 1 FROM pg_depend d
          WHERE d.objid = p.oid AND d.deptype = 'e'
      )
),

-- =====================================================================
-- SEQUENCES (metadata only)
-- =====================================================================
sequences_json AS (
    SELECT jsonb_agg(
        jsonb_build_object(
            'schema',    s.sequence_schema,
            'name',      s.sequence_name,
            'data_type', s.data_type
        )
        ORDER BY s.sequence_schema, s.sequence_name
    ) AS payload
    FROM information_schema.sequences s
    JOIN target_schemas ts ON ts.schema_name = s.sequence_schema
),

-- =====================================================================
-- USER-DEFINED TYPES (kind and count only, no value labels)
-- For domains we include the base type since it's a structural fact, not
-- a constraint value (e.g. domain `email` is built on `text`).
-- =====================================================================
types_json AS (
    SELECT jsonb_agg(
        jsonb_strip_nulls(jsonb_build_object(
            'schema',      ts.schema_name,
            'name',        t.typname,
            'kind',        CASE t.typtype
                              WHEN 'e' THEN 'enum'
                              WHEN 'c' THEN 'composite'
                              WHEN 'd' THEN 'domain'
                              WHEN 'r' THEN 'range'
                           END,
            'value_count', CASE WHEN t.typtype = 'e' THEN (
                              SELECT COUNT(*)::int FROM pg_enum e
                              WHERE e.enumtypid = t.oid
                           ) END,
            'base_type',   CASE WHEN t.typtype = 'd' THEN
                              format_type(t.typbasetype, t.typtypmod)
                           END
        ))
        ORDER BY ts.schema_name, t.typname
    ) AS payload
    FROM pg_type t
    JOIN target_schemas ts ON ts.schema_oid = t.typnamespace
    WHERE t.typtype IN ('e', 'c', 'd', 'r')
      AND t.typname NOT LIKE 'pg_%'
      AND NOT EXISTS (
          SELECT 1 FROM pg_class c WHERE c.reltype = t.oid
      )
      AND NOT EXISTS (
          SELECT 1 FROM pg_depend d
          WHERE d.objid = t.oid AND d.deptype = 'e'
      )
)

-- =====================================================================
-- FINAL ASSEMBLY
-- =====================================================================
SELECT
    CASE
        WHEN (SELECT pretty_print FROM params) THEN jsonb_pretty(result)
        ELSE result::text
    END AS schema_dump
FROM (
    SELECT jsonb_strip_nulls(jsonb_build_object(
        'metadata', jsonb_build_object(
            'tool_name',        'sql-x-ray',
            'engine',           'postgresql',
            'engine_version',   split_part(current_setting('server_version'), ' ', 1),
            'database',         current_database(),
            'generated_at',     to_char(now() AT TIME ZONE 'UTC',
                                       'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
            'schema_filter',    (SELECT schema_filter FROM params),
            'schemas',          (SELECT jsonb_agg(schema_name ORDER BY schema_name)
                                 FROM target_schemas),
            'privacy_note',
                'This document contains only structural metadata. '
             || 'It deliberately excludes: default value literals, '
             || 'check constraint expressions, view and function bodies, '
             || 'enum value labels, descriptions/comments, and all row data. '
             || 'Existence is recorded via counts (e.g. check_constraint_count); '
             || 'contents are not. Expression indexes are marked as '
             || '"<expression>" in column lists.'
        ),
        'tables',    COALESCE((SELECT payload FROM tables_json),    '[]'::jsonb),
        'views',     COALESCE((SELECT payload FROM views_json),     '[]'::jsonb),
        'routines',  COALESCE((SELECT payload FROM routines_json),  '[]'::jsonb),
        'sequences', COALESCE((SELECT payload FROM sequences_json), '[]'::jsonb),
        'types',     COALESCE((SELECT payload FROM types_json),     '[]'::jsonb)
    )) AS result
) final;