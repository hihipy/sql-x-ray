-- =====================================================================
-- sql-x-ray for SQLite 3.44+
-- =====================================================================
-- Generates a privacy-safe structural JSON dump of a database schema,
-- suitable as priming context for an LLM.
--
-- Repository: https://github.com/hihipy/sql-x-ray
-- License:    CC BY-NC-SA 4.0
--
-- Target: SQLite 3.44+
--   Requires native JSON functions (json_object, json_group_array,
--   json) bundled since 3.38, and ORDER BY inside json_group_array
--   added in 3.44. Pragma table-valued functions (pragma_table_info,
--   pragma_foreign_key_list, etc.) require 3.16+.
--
-- Catalog source: sqlite_master.
--   SQLite has no schema concept beyond attached databases. The
--   script reports objects in the main database and emits "main"
--   as the schema name for cross-engine field parity.
--
-- Usage:
--   1. Run this script against any SQLite 3.44+ database.
--   2. The result is a single column schema_dump containing one
--      row of JSON.
--
-- What's captured:
--   tables     base tables with primary key, foreign keys, indexes
--              (excluding auto-created PK/UNIQUE indexes),
--              trigger_count, and columns
--   views      name and column list with types
--   routines   empty array (SQLite has no stored procedures or
--              user-defined functions)
--   sequences  empty array (SQLite has no sequence objects;
--              autoincrement is per-table metadata)
--   packages   empty array (no package concept)
--
-- What's deliberately excluded for privacy:
--   - column default value literals (presence flag only)
--   - CHECK constraint expressions (SQLite stores these inside the
--     full CREATE TABLE SQL; we deliberately don't parse that to
--     avoid surfacing literal values)
--   - view bodies, trigger bodies
--   - data row contents
--
-- SQLite-specific notes:
--   - PRAGMA returns reserved-word column names ("from", "to",
--     "table", "unique", "notnull"), which we quote with double
--     quotes.
--   - pragma_table_info.pk is 0 for non-PK columns, 1+ for the
--     column's position in a composite PK.
--   - pragma_index_list.origin: 'c' = CREATE INDEX, 'u' = UNIQUE
--     constraint, 'pk' = PRIMARY KEY. We filter to 'c' so the
--     indexes section only shows explicitly-created indexes.
--   - SQLite stores types as declared text; we emit them directly
--     without normalizing.
-- =====================================================================

WITH

-- =====================================================================
-- COLUMNS
--
-- pragma_table_info returns: cid (column id, 0-indexed), name, type,
-- notnull (0/1), dflt_value, pk (0 if not PK, else position in PK).
-- We add 1 to cid for cross-engine position parity (1-indexed).
-- =====================================================================
cols AS (
    SELECT
        m.name AS table_name,
        json_group_array(
            json_object(
                'name',         p.name,
                'position',     p.cid + 1,
                'data_type',    p.type,
                'nullable',     CASE p."notnull" WHEN 1 THEN json('false') ELSE json('true') END,
                'has_default',  CASE WHEN p.dflt_value IS NOT NULL THEN json('true') ELSE json('false') END,
                'is_pk',        CASE WHEN p.pk > 0 THEN json('true') ELSE json('false') END
            )
            ORDER BY p.cid
        ) AS columns
    FROM sqlite_master m, pragma_table_info(m.name) p
    WHERE m.type = 'table'
      AND m.name NOT LIKE 'sqlite_%'
    GROUP BY m.name
),

-- =====================================================================
-- PRIMARY KEYS
--
-- pragma_table_info's pk column gives 0 for non-PK columns or 1+ for
-- the position in a composite PK. We aggregate names ordered by pk.
-- =====================================================================
pks AS (
    SELECT
        m.name AS table_name,
        json_object(
            'columns', json_group_array(p.name ORDER BY p.pk)
        ) AS primary_key
    FROM sqlite_master m, pragma_table_info(m.name) p
    WHERE m.type = 'table'
      AND m.name NOT LIKE 'sqlite_%'
      AND p.pk > 0
    GROUP BY m.name
),

-- =====================================================================
-- FOREIGN KEYS
--
-- pragma_foreign_key_list returns: id, seq, table, from, to,
-- on_update, on_delete, match. The id groups columns belonging to
-- the same FK (composite FKs have multiple rows with the same id).
-- We need double-quotes around "from", "to", "table" because these
-- are SQL reserved words.
-- =====================================================================
fk_grouped AS (
    SELECT
        m.name AS table_name,
        f.id AS fk_id,
        f."table" AS to_table,
        f.on_delete,
        json_group_array(f."from" ORDER BY f.seq) AS from_columns,
        json_group_array(f."to" ORDER BY f.seq) AS to_columns
    FROM sqlite_master m, pragma_foreign_key_list(m.name) f
    WHERE m.type = 'table'
      AND m.name NOT LIKE 'sqlite_%'
    GROUP BY m.name, f.id, f."table", f.on_delete
),
fks AS (
    SELECT
        table_name,
        json_group_array(
            json_object(
                'from_columns', json(from_columns),
                'to_table',     to_table,
                'to_columns',   json(to_columns),
                'on_delete',    on_delete
            )
            ORDER BY fk_id
        ) AS foreign_keys
    FROM fk_grouped
    GROUP BY table_name
),

-- =====================================================================
-- INDEXES (excludes PK-backing and unique-backing indexes)
--
-- pragma_index_list returns: seq, name, unique (0/1), origin
-- ('c'/'u'/'pk'), partial (0/1). We keep only origin = 'c' since
-- 'u' and 'pk' are auto-created from UNIQUE/PRIMARY KEY constraints
-- and would duplicate constraint information.
-- =====================================================================
idx_cols AS (
    SELECT
        m.name AS table_name,
        il.name AS index_name,
        il."unique" AS is_unique,
        json_group_array(ii.name ORDER BY ii.seqno) AS columns
    FROM sqlite_master m,
         pragma_index_list(m.name) il,
         pragma_index_info(il.name) ii
    WHERE m.type = 'table'
      AND m.name NOT LIKE 'sqlite_%'
      AND il.origin = 'c'
    GROUP BY m.name, il.name, il."unique"
),
idx AS (
    SELECT
        table_name,
        json_group_array(
            json_object(
                'name',    index_name,
                'method',  'btree',
                'unique',  CASE is_unique WHEN 1 THEN json('true') ELSE json('false') END,
                'columns', json(columns)
            )
            ORDER BY index_name
        ) AS indexes
    FROM idx_cols
    GROUP BY table_name
),

-- =====================================================================
-- TRIGGER COUNTS
-- =====================================================================
trigger_counts AS (
    SELECT
        tbl_name AS table_name,
        COUNT(*) AS trigger_count
    FROM sqlite_master
    WHERE type = 'trigger'
    GROUP BY tbl_name
),

-- =====================================================================
-- TABLES
-- =====================================================================
tables_json AS (
    SELECT json_group_array(
        json_object(
            'schema',                 'main',
            'name',                   m.name,
            'kind',                   'table',
            'is_partitioned',         json('false'),
            'primary_key',            json(pks.primary_key),
            'foreign_keys',           json(fks.foreign_keys),
            'unique_constraints',     json('[]'),
            'check_constraint_count', 0,
            'indexes',                json(idx.indexes),
            'trigger_count',          COALESCE(tc.trigger_count, 0),
            'columns',                json(cols.columns)
        )
        ORDER BY m.name
    ) AS payload
    FROM sqlite_master m
    LEFT JOIN cols           ON cols.table_name = m.name
    LEFT JOIN pks            ON pks.table_name  = m.name
    LEFT JOIN fks            ON fks.table_name  = m.name
    LEFT JOIN idx            ON idx.table_name  = m.name
    LEFT JOIN trigger_counts tc ON tc.table_name = m.name
    WHERE m.type = 'table'
      AND m.name NOT LIKE 'sqlite_%'
),

-- =====================================================================
-- VIEWS
--
-- SQLite views: pragma_table_info works on views too, giving the
-- same column-info shape as tables.
-- =====================================================================
view_cols AS (
    SELECT
        m.name AS view_name,
        json_group_array(
            json_object(
                'name',      p.name,
                'position',  p.cid + 1,
                'data_type', p.type,
                'nullable',  CASE p."notnull" WHEN 1 THEN json('false') ELSE json('true') END
            )
            ORDER BY p.cid
        ) AS columns
    FROM sqlite_master m, pragma_table_info(m.name) p
    WHERE m.type = 'view'
      AND m.name NOT LIKE 'sqlite_%'
    GROUP BY m.name
),
views_json AS (
    SELECT json_group_array(
        json_object(
            'schema',  'main',
            'name',    m.name,
            'kind',    'view',
            'columns', json(COALESCE(vc.columns, '[]'))
        )
        ORDER BY m.name
    ) AS payload
    FROM sqlite_master m
    LEFT JOIN view_cols vc ON vc.view_name = m.name
    WHERE m.type = 'view'
      AND m.name NOT LIKE 'sqlite_%'
),

-- =====================================================================
-- METADATA
-- =====================================================================
meta AS (
    SELECT json_object(
        'tool_name',      'sql-x-ray',
        'engine',         'sqlite',
        'engine_version', sqlite_version(),
        'database',       'main',
        'generated_at',   strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
        'schema_filter',  'main',
        'schemas',        json_array('main'),
        'object_counts',  json_object(
            'tables', (SELECT COUNT(*) FROM sqlite_master
                       WHERE type = 'table'
                         AND name NOT LIKE 'sqlite_%'),
            'views',  (SELECT COUNT(*) FROM sqlite_master
                       WHERE type = 'view')
        ),
        'privacy_note',
            'This document contains only structural metadata. ' ||
            'It deliberately excludes default value literals, ' ||
            'check constraint expressions (SQLite stores these ' ||
            'inside CREATE TABLE SQL which we do not parse), ' ||
            'view and trigger bodies, and all row data. Existence ' ||
            'is recorded via counts (e.g. trigger_count); ' ||
            'contents are not.'
    ) AS payload
)

-- =====================================================================
-- FINAL ASSEMBLY
-- =====================================================================
SELECT json_object(
    'metadata',  json((SELECT payload FROM meta)),
    'tables',    json(COALESCE((SELECT payload FROM tables_json), '[]')),
    'views',     json(COALESCE((SELECT payload FROM views_json),  '[]')),
    'routines',  json('[]'),
    'sequences', json('[]'),
    'packages',  json('[]'),
    'types',     json('[]')
) AS schema_dump;
