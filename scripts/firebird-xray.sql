-- =====================================================================
-- sql-x-ray for Firebird 4.0+
-- =====================================================================
-- Generates a privacy-safe structural Markdown dump of a database
-- schema, suitable as priming context for an LLM.
--
-- Repository: https://github.com/hihipy/sql-x-ray
-- License:    CC BY-NC-SA 4.0
--
-- Target: Firebird 4.0+
--   Uses RDB$ system catalog (RDB$RELATIONS, RDB$RELATION_FIELDS,
--   RDB$FIELDS, etc.), LIST() aggregate with derived-table
--   ordering, ASCII_CHAR(10) for line breaks, and standard SQL
--   CTEs. Tested against Firebird's bundled Employee database.
--
-- Catalog source: RDB$ system tables.
--   Firebird has a single namespace per database (schemas were
--   proposed but not implemented as of 4.0). The output does not
--   include any schema prefix on object names.
--
-- Why Markdown instead of JSON:
--   Firebird 4.0 has no native JSON functions. JSON_OBJECT,
--   JSON_ARRAYAGG, JSON_QUERY etc. are still in proposal stage for
--   future Firebird releases (likely 6.0+). Building JSON manually
--   in Firebird 4.0 would require full string concatenation with
--   explicit quote escaping for every key and value. Markdown
--   construction is simpler since it doesn't need structural
--   delimiters or escape rules for content. The output is still
--   single-column text and still LLM-friendly, just not parseable
--   as JSON. This is the one outlier among sql-x-ray engines.
--
-- Usage:
--   1. Connect to the target Firebird database.
--   2. Run this script. The result is a single column containing
--      one row of Markdown.
--
-- What's captured:
--   tables       base tables with primary key, foreign keys, unique
--                constraints, check_constraint_count, indexes,
--                trigger_count, and columns
--   views        name and column list with types
--   procedures   standalone stored procedures (name, arguments,
--                return type), no bodies
--   functions    standalone user-defined functions
--   sequences    generators (Firebird's term for sequences)
--   packages     PSQL packages (name only)
--   gtts         global temporary tables
--
-- What's deliberately excluded for privacy:
--   - column default value literals (presence flag only)
--   - check constraint expressions (count only)
--   - view bodies, routine bodies, trigger bodies, package bodies
--   - row counts and size estimates (Firebird's catalog doesn't
--     expose table-level stats reliably)
--   - column comments and table comments
--   - data row contents
--
-- Ordering caveat:
--   Firebird's LIST() aggregate does not support ORDER BY directly.
--   The script wraps row sources in derived tables with ORDER BY,
--   which causes the optimizer to feed LIST() rows in that order
--   in practice. On small sample databases this is reliable; with
--   parallel execution on large databases, ordering may vary.
-- =====================================================================

WITH

-- =====================================================================
-- TYPE RENDERING
--
-- Firebird stores column types via two columns in RDB$FIELDS:
--   RDB$FIELD_TYPE    numeric type code
--   RDB$FIELD_SUB_TYPE  0/1/2 (for INTEGER family: 1=NUMERIC, 2=DECIMAL)
--                       or BLOB subtype (0=binary, 1=text, ...)
-- Plus RDB$FIELD_LENGTH, RDB$FIELD_PRECISION, RDB$FIELD_SCALE, and
-- RDB$CHARACTER_LENGTH for typed lengths.
--
-- A NUMERIC(p,s) or DECIMAL(p,s) is stored as SMALLINT/INTEGER/BIGINT
-- with negative scale and sub_type 1 or 2. We render those as
-- NUMERIC(p,s) or DECIMAL(p,s) instead of the underlying integer.
--
-- BLOB types render as BLOB SUB_TYPE TEXT (subtype 1) or BLOB
-- SUB_TYPE BINARY (subtype 0). Other subtypes appear as
-- BLOB SUB_TYPE n.
-- =====================================================================
type_lookup AS (
    SELECT
        TRIM(f.rdb$field_name) AS field_source,
        CASE f.rdb$field_type
            WHEN 7 THEN
                CASE
                    WHEN f.rdb$field_sub_type = 1 THEN
                        'NUMERIC(' || f.rdb$field_precision || ',' || (-f.rdb$field_scale) || ')'
                    WHEN f.rdb$field_sub_type = 2 THEN
                        'DECIMAL(' || f.rdb$field_precision || ',' || (-f.rdb$field_scale) || ')'
                    ELSE 'SMALLINT'
                END
            WHEN 8 THEN
                CASE
                    WHEN f.rdb$field_sub_type = 1 THEN
                        'NUMERIC(' || f.rdb$field_precision || ',' || (-f.rdb$field_scale) || ')'
                    WHEN f.rdb$field_sub_type = 2 THEN
                        'DECIMAL(' || f.rdb$field_precision || ',' || (-f.rdb$field_scale) || ')'
                    ELSE 'INTEGER'
                END
            WHEN 10 THEN 'FLOAT'
            WHEN 12 THEN 'DATE'
            WHEN 13 THEN 'TIME'
            WHEN 14 THEN
                'CHAR(' || COALESCE(f.rdb$character_length, f.rdb$field_length) || ')'
            WHEN 16 THEN
                CASE
                    WHEN f.rdb$field_sub_type = 1 THEN
                        'NUMERIC(' || f.rdb$field_precision || ',' || (-f.rdb$field_scale) || ')'
                    WHEN f.rdb$field_sub_type = 2 THEN
                        'DECIMAL(' || f.rdb$field_precision || ',' || (-f.rdb$field_scale) || ')'
                    ELSE 'BIGINT'
                END
            WHEN 23 THEN 'BOOLEAN'
            WHEN 24 THEN 'DECFLOAT(16)'
            WHEN 25 THEN 'INT128'
            WHEN 26 THEN 'DECFLOAT(34)'
            WHEN 27 THEN 'DOUBLE PRECISION'
            WHEN 28 THEN 'TIME WITH TIME ZONE'
            WHEN 29 THEN 'TIMESTAMP WITH TIME ZONE'
            WHEN 35 THEN 'TIMESTAMP'
            WHEN 37 THEN
                'VARCHAR(' || COALESCE(f.rdb$character_length, f.rdb$field_length) || ')'
            WHEN 40 THEN
                'CSTRING(' || COALESCE(f.rdb$character_length, f.rdb$field_length) || ')'
            WHEN 261 THEN
                CASE f.rdb$field_sub_type
                    WHEN 0 THEN 'BLOB SUB_TYPE BINARY'
                    WHEN 1 THEN 'BLOB SUB_TYPE TEXT'
                    ELSE 'BLOB SUB_TYPE ' || f.rdb$field_sub_type
                END
            ELSE 'UNKNOWN(type=' || f.rdb$field_type || ')'
        END AS type_name
    FROM rdb$fields f
),

-- =====================================================================
-- USER RELATIONS
--
-- RDB$RELATION_TYPE values:
--   0 = persistent table
--   1 = view
--   2 = external table
--   3 = virtual (monitoring tables, treated as system)
--   4 = global temp table (preserve rows on commit)
--   5 = global temp table (delete rows on commit)
-- We exclude system-flagged relations (RDB$SYSTEM_FLAG <> 0).
-- =====================================================================
user_tables AS (
    SELECT TRIM(rdb$relation_name) AS relation_name
    FROM rdb$relations
    WHERE COALESCE(rdb$system_flag, 0) = 0
      AND rdb$relation_type IN (0, 2)
),
user_views AS (
    SELECT TRIM(rdb$relation_name) AS relation_name
    FROM rdb$relations
    WHERE COALESCE(rdb$system_flag, 0) = 0
      AND rdb$relation_type = 1
),
user_gtts AS (
    SELECT TRIM(rdb$relation_name) AS relation_name,
           CASE rdb$relation_type
               WHEN 4 THEN 'PRESERVE ROWS'
               WHEN 5 THEN 'DELETE ROWS'
           END AS preservation
    FROM rdb$relations
    WHERE COALESCE(rdb$system_flag, 0) = 0
      AND rdb$relation_type IN (4, 5)
),

-- =====================================================================
-- COLUMNS
-- =====================================================================
table_columns AS (
    SELECT
        TRIM(rf.rdb$relation_name) AS relation_name,
        rf.rdb$field_position + 1  AS pos,
        TRIM(rf.rdb$field_name)    AS col_name,
        tl.type_name               AS type_name,
        TRIM(CASE WHEN rf.rdb$null_flag = 1 THEN 'NO' ELSE 'YES' END) AS nullable,
        TRIM(CASE WHEN rf.rdb$identity_type IS NOT NULL THEN 'YES' ELSE 'NO' END) AS is_identity,
        TRIM(CASE WHEN f.rdb$computed_source IS NOT NULL THEN 'YES' ELSE 'NO' END) AS is_generated,
        TRIM(CASE WHEN rf.rdb$default_source IS NOT NULL OR f.rdb$default_source IS NOT NULL
                  THEN 'YES' ELSE 'NO' END) AS has_default
    FROM rdb$relation_fields rf
    JOIN rdb$fields f
      ON TRIM(f.rdb$field_name) = TRIM(rf.rdb$field_source)
    JOIN type_lookup tl
      ON tl.field_source = TRIM(rf.rdb$field_source)
    WHERE COALESCE(rf.rdb$system_flag, 0) = 0
),

-- Per-table markdown column table (header + body)
table_column_md_rows AS (
    SELECT relation_name, pos,
           '| ' || pos
           || ' | ' || col_name
           || ' | ' || COALESCE(type_name, '(unknown)')
           || ' | ' || nullable
           || ' | ' || is_identity
           || ' | ' || is_generated
           || ' | ' || has_default
           || ' |' AS row_md
    FROM table_columns
),

-- =====================================================================
-- PRIMARY KEYS
-- =====================================================================
pk_constraints AS (
    SELECT TRIM(rc.rdb$relation_name) AS relation_name,
           TRIM(rc.rdb$index_name)    AS index_name
    FROM rdb$relation_constraints rc
    WHERE rc.rdb$constraint_type = 'PRIMARY KEY'
),
pk_columns AS (
    SELECT pkc.relation_name,
           iseg.rdb$field_position AS pos,
           TRIM(iseg.rdb$field_name) AS col_name
    FROM pk_constraints pkc
    JOIN rdb$index_segments iseg
      ON TRIM(iseg.rdb$index_name) = pkc.index_name
),

-- =====================================================================
-- FOREIGN KEYS
-- =====================================================================
fk_constraints AS (
    SELECT
        TRIM(rc.rdb$constraint_name) AS constraint_name,
        TRIM(rc.rdb$relation_name)   AS relation_name,
        TRIM(rc.rdb$index_name)      AS fk_index_name,
        TRIM(refc.rdb$const_name_uq) AS referenced_unique_name,
        TRIM(refc.rdb$update_rule)   AS on_update,
        TRIM(refc.rdb$delete_rule)   AS on_delete
    FROM rdb$relation_constraints rc
    JOIN rdb$ref_constraints refc
      ON TRIM(refc.rdb$constraint_name) = TRIM(rc.rdb$constraint_name)
    WHERE rc.rdb$constraint_type = 'FOREIGN KEY'
),
fk_target AS (
    SELECT
        fk.constraint_name,
        fk.relation_name,
        fk.fk_index_name,
        TRIM(rc2.rdb$relation_name) AS referenced_table,
        TRIM(rc2.rdb$index_name)    AS referenced_index_name,
        fk.on_update,
        fk.on_delete
    FROM fk_constraints fk
    JOIN rdb$relation_constraints rc2
      ON TRIM(rc2.rdb$constraint_name) = fk.referenced_unique_name
),
fk_from_cols AS (
    SELECT fkt.constraint_name, fkt.relation_name,
           iseg.rdb$field_position AS pos,
           TRIM(iseg.rdb$field_name) AS col_name
    FROM fk_target fkt
    JOIN rdb$index_segments iseg
      ON TRIM(iseg.rdb$index_name) = fkt.fk_index_name
),
fk_to_cols AS (
    SELECT fkt.constraint_name,
           iseg.rdb$field_position AS pos,
           TRIM(iseg.rdb$field_name) AS col_name
    FROM fk_target fkt
    JOIN rdb$index_segments iseg
      ON TRIM(iseg.rdb$index_name) = fkt.referenced_index_name
),

-- =====================================================================
-- UNIQUE CONSTRAINTS
-- =====================================================================
uq_constraints AS (
    SELECT TRIM(rc.rdb$constraint_name) AS constraint_name,
           TRIM(rc.rdb$relation_name)   AS relation_name,
           TRIM(rc.rdb$index_name)      AS index_name
    FROM rdb$relation_constraints rc
    WHERE rc.rdb$constraint_type = 'UNIQUE'
),
uq_columns AS (
    SELECT uqc.constraint_name, uqc.relation_name,
           iseg.rdb$field_position AS pos,
           TRIM(iseg.rdb$field_name) AS col_name
    FROM uq_constraints uqc
    JOIN rdb$index_segments iseg
      ON TRIM(iseg.rdb$index_name) = uqc.index_name
),

-- =====================================================================
-- CHECK CONSTRAINT COUNTS
-- =====================================================================
check_counts AS (
    SELECT TRIM(rc.rdb$relation_name) AS relation_name,
           COUNT(*) AS check_count
    FROM rdb$relation_constraints rc
    WHERE rc.rdb$constraint_type = 'CHECK'
    GROUP BY TRIM(rc.rdb$relation_name)
),

-- =====================================================================
-- INDEXES (excludes PK-backing and unique-backing indexes)
--
-- Firebird auto-creates indexes to enforce PK/FK/UNIQUE; we list
-- those constraints in their own sections, so we exclude their
-- indexes here. Indexes belonging to FK constraints have
-- RDB$FOREIGN_KEY non-null.
-- =====================================================================
non_constraint_indexes AS (
    SELECT TRIM(i.rdb$index_name)    AS index_name,
           TRIM(i.rdb$relation_name) AS relation_name,
           i.rdb$unique_flag         AS is_unique,
           TRIM(CASE i.rdb$index_type WHEN 1 THEN 'DESC' ELSE 'ASC' END) AS direction
    FROM rdb$indices i
    WHERE COALESCE(i.rdb$system_flag, 0) = 0
      AND i.rdb$foreign_key IS NULL
      AND NOT EXISTS (
          SELECT 1 FROM rdb$relation_constraints rc
          WHERE TRIM(rc.rdb$index_name) = TRIM(i.rdb$index_name)
            AND rc.rdb$constraint_type IN ('PRIMARY KEY', 'UNIQUE')
      )
),
index_columns_data AS (
    SELECT nci.relation_name, nci.index_name, nci.is_unique, nci.direction,
           iseg.rdb$field_position AS pos,
           TRIM(iseg.rdb$field_name) AS col_name
    FROM non_constraint_indexes nci
    JOIN rdb$index_segments iseg
      ON TRIM(iseg.rdb$index_name) = nci.index_name
),

-- =====================================================================
-- TRIGGER COUNTS
-- =====================================================================
trigger_counts AS (
    SELECT TRIM(t.rdb$relation_name) AS relation_name,
           COUNT(*) AS trigger_count
    FROM rdb$triggers t
    WHERE COALESCE(t.rdb$system_flag, 0) = 0
      AND t.rdb$relation_name IS NOT NULL
    GROUP BY TRIM(t.rdb$relation_name)
),

-- =====================================================================
-- BUILD MARKDOWN PIECES PER OBJECT
-- =====================================================================

-- Columns markdown table per relation (header + body rows)
relation_columns_md AS (
    SELECT
        ut.relation_name,
        '| # | Name | Type | Null | Identity | Generated | Default |' || ASCII_CHAR(10) ||
        '|---|------|------|------|----------|-----------|---------|' || ASCII_CHAR(10) ||
        COALESCE(
            (SELECT LIST(row_md, ASCII_CHAR(10))
             FROM (SELECT row_md FROM table_column_md_rows tcm
                   WHERE tcm.relation_name = ut.relation_name
                   ORDER BY pos)),
            ''
        ) AS columns_md
    FROM (
        SELECT relation_name FROM user_tables
        UNION ALL
        SELECT relation_name FROM user_views
        UNION ALL
        SELECT relation_name FROM user_gtts
    ) ut
),

-- Primary key one-line summary per relation
relation_pk_md AS (
    SELECT pkc.relation_name,
           '- Primary key: (' ||
           COALESCE(
               (SELECT LIST(col_name, ', ')
                FROM (SELECT col_name FROM pk_columns pc
                      WHERE pc.relation_name = pkc.relation_name
                      ORDER BY pos)),
               ''
           ) || ')' AS pk_md
    FROM pk_constraints pkc
),

-- Foreign key bullet list per relation (multiline blob, no leading newline)
relation_fk_md AS (
    SELECT
        relation_name,
        '- Foreign keys: ' || CAST(COUNT(*) AS VARCHAR(20)) || ASCII_CHAR(10) ||
        LIST(fk_bullet, ASCII_CHAR(10)) AS fk_md
    FROM (
        SELECT
            fkt.relation_name,
            '  - ' || fkt.constraint_name
            || ': (' || COALESCE(
                (SELECT LIST(col_name, ', ')
                 FROM (SELECT col_name FROM fk_from_cols ffc
                       WHERE ffc.constraint_name = fkt.constraint_name
                       ORDER BY pos)),
                ''
            ) || ') -> ' || fkt.referenced_table
            || '(' || COALESCE(
                (SELECT LIST(col_name, ', ')
                 FROM (SELECT col_name FROM fk_to_cols ftc
                       WHERE ftc.constraint_name = fkt.constraint_name
                       ORDER BY pos)),
                ''
            ) || ')'
            || ' on update ' || COALESCE(fkt.on_update, 'NO ACTION')
            || ', on delete ' || COALESCE(fkt.on_delete, 'NO ACTION') AS fk_bullet
        FROM fk_target fkt
    ) fk_bullets
    GROUP BY relation_name
),

-- Unique constraint bullet list per relation
relation_uq_md AS (
    SELECT
        relation_name,
        '- Unique constraints: ' || CAST(COUNT(*) AS VARCHAR(20)) || ASCII_CHAR(10) ||
        LIST(uq_bullet, ASCII_CHAR(10)) AS uq_md
    FROM (
        SELECT uqc.relation_name,
               '  - ' || uqc.constraint_name || ': (' ||
               COALESCE(
                   (SELECT LIST(col_name, ', ')
                    FROM (SELECT col_name FROM uq_columns uc
                          WHERE uc.constraint_name = uqc.constraint_name
                          ORDER BY pos)),
                   ''
               ) || ')' AS uq_bullet
        FROM uq_constraints uqc
    ) uq_bullets
    GROUP BY relation_name
),

-- Index bullet list per relation
relation_idx_md AS (
    SELECT
        nci.relation_name,
        '- Indexes: ' || CAST(COUNT(*) AS VARCHAR(20)) || ASCII_CHAR(10) ||
        LIST(idx_bullet, ASCII_CHAR(10)) AS idx_md
    FROM (
        SELECT nci.relation_name,
               '  - ' || nci.index_name
               || ': (' || COALESCE(
                   (SELECT LIST(col_name, ', ')
                    FROM (SELECT col_name FROM index_columns_data icd
                          WHERE icd.index_name = nci.index_name
                          ORDER BY pos)),
                   ''
               ) || ') '
               || TRIM(CASE WHEN nci.is_unique = 1 THEN 'unique' ELSE 'non-unique' END)
               || ', ' || nci.direction AS idx_bullet
        FROM non_constraint_indexes nci
    ) nci
    GROUP BY relation_name
),

-- =====================================================================
-- ASSEMBLE TABLE/VIEW/GTT MARKDOWN BLOCKS
-- =====================================================================

table_block_md AS (
    SELECT
        ut.relation_name,
        '### ' || ut.relation_name || ASCII_CHAR(10) ||
        ASCII_CHAR(10) ||
        COALESCE(pk.pk_md || ASCII_CHAR(10), '- Primary key: (none)' || ASCII_CHAR(10)) ||
        COALESCE(fk.fk_md || ASCII_CHAR(10), '- Foreign keys: 0' || ASCII_CHAR(10)) ||
        COALESCE(uq.uq_md || ASCII_CHAR(10), '- Unique constraints: 0' || ASCII_CHAR(10)) ||
        '- Check constraints: ' || COALESCE(CAST(cc.check_count AS VARCHAR(20)), '0') || ASCII_CHAR(10) ||
        COALESCE(idx.idx_md || ASCII_CHAR(10), '- Indexes: 0' || ASCII_CHAR(10)) ||
        '- Triggers: ' || COALESCE(CAST(tc.trigger_count AS VARCHAR(20)), '0') || ASCII_CHAR(10) ||
        ASCII_CHAR(10) ||
        'Columns:' || ASCII_CHAR(10) ||
        COALESCE(rcm.columns_md, '(no columns)') AS block_md
    FROM user_tables ut
    LEFT JOIN relation_pk_md  pk  ON pk.relation_name  = ut.relation_name
    LEFT JOIN relation_fk_md  fk  ON fk.relation_name  = ut.relation_name
    LEFT JOIN relation_uq_md  uq  ON uq.relation_name  = ut.relation_name
    LEFT JOIN check_counts    cc  ON cc.relation_name  = ut.relation_name
    LEFT JOIN relation_idx_md idx ON idx.relation_name = ut.relation_name
    LEFT JOIN trigger_counts  tc  ON tc.relation_name  = ut.relation_name
    LEFT JOIN relation_columns_md rcm ON rcm.relation_name = ut.relation_name
),

view_block_md AS (
    SELECT
        uv.relation_name,
        '### ' || uv.relation_name || ASCII_CHAR(10) ||
        ASCII_CHAR(10) ||
        'Columns:' || ASCII_CHAR(10) ||
        COALESCE(rcm.columns_md, '(no columns)') AS block_md
    FROM user_views uv
    LEFT JOIN relation_columns_md rcm ON rcm.relation_name = uv.relation_name
),

gtt_block_md AS (
    SELECT
        ug.relation_name,
        '### ' || ug.relation_name || ' (' || ug.preservation || ')' || ASCII_CHAR(10) ||
        ASCII_CHAR(10) ||
        'Columns:' || ASCII_CHAR(10) ||
        COALESCE(rcm.columns_md, '(no columns)') AS block_md
    FROM user_gtts ug
    LEFT JOIN relation_columns_md rcm ON rcm.relation_name = ug.relation_name
),

-- =====================================================================
-- PROCEDURES, FUNCTIONS, SEQUENCES, PACKAGES
-- =====================================================================

proc_args AS (
    SELECT TRIM(pp.rdb$procedure_name) AS proc_name,
           TRIM(pp.rdb$package_name)   AS package_name,
           pp.rdb$parameter_number     AS pos,
           pp.rdb$parameter_type       AS direction,
           TRIM(pp.rdb$parameter_name) AS arg_name,
           tl.type_name                AS arg_type
    FROM rdb$procedure_parameters pp
    LEFT JOIN type_lookup tl
      ON tl.field_source = TRIM(pp.rdb$field_source)
    WHERE COALESCE(pp.rdb$system_flag, 0) = 0
),
proc_arg_strings AS (
    SELECT proc_name, package_name, direction,
           CASE direction WHEN 0 THEN 'IN ' WHEN 1 THEN 'OUT ' ELSE '' END
           || arg_name || ' ' || COALESCE(arg_type, '(unknown)') AS arg_str,
           pos
    FROM proc_args
),

proc_block_md AS (
    SELECT
        TRIM(p.rdb$procedure_name)             AS proc_name,
        TRIM(p.rdb$package_name)               AS package_name,
        '### ' || TRIM(p.rdb$procedure_name)
        || CASE WHEN p.rdb$package_name IS NOT NULL
                THEN ' (in package ' || TRIM(p.rdb$package_name) || ')'
                ELSE ''
           END
        || ' (' || CASE p.rdb$procedure_type
                       WHEN 1 THEN 'executable'
                       WHEN 2 THEN 'selectable'
                       ELSE 'unknown'
                   END || ')' || ASCII_CHAR(10) ||
        ASCII_CHAR(10) ||
        '- Inputs: ' || COALESCE(
            (SELECT LIST(arg_str, ', ')
             FROM (SELECT arg_str FROM proc_arg_strings pas
                   WHERE pas.proc_name = TRIM(p.rdb$procedure_name)
                     AND (pas.package_name IS NOT DISTINCT FROM TRIM(p.rdb$package_name))
                     AND pas.direction = 0
                   ORDER BY pos)),
            '(none)') || ASCII_CHAR(10) ||
        '- Outputs: ' || COALESCE(
            (SELECT LIST(arg_str, ', ')
             FROM (SELECT arg_str FROM proc_arg_strings pas
                   WHERE pas.proc_name = TRIM(p.rdb$procedure_name)
                     AND (pas.package_name IS NOT DISTINCT FROM TRIM(p.rdb$package_name))
                     AND pas.direction = 1
                   ORDER BY pos)),
            '(none)') AS block_md
    FROM rdb$procedures p
    WHERE COALESCE(p.rdb$system_flag, 0) = 0
),

func_args AS (
    SELECT TRIM(fa.rdb$function_name) AS func_name,
           TRIM(fa.rdb$package_name)  AS package_name,
           fa.rdb$argument_position   AS pos,
           TRIM(fa.rdb$argument_name) AS arg_name,
           tl.type_name               AS arg_type,
           fa.rdb$argument_position   AS arg_pos_for_return
    FROM rdb$function_arguments fa
    LEFT JOIN type_lookup tl
      ON tl.field_source = TRIM(fa.rdb$field_source)
    WHERE COALESCE(fa.rdb$system_flag, 0) = 0
),

func_block_md AS (
    SELECT
        TRIM(f.rdb$function_name)              AS func_name,
        TRIM(f.rdb$package_name)               AS package_name,
        '### ' || TRIM(f.rdb$function_name)
        || CASE WHEN f.rdb$package_name IS NOT NULL
                THEN ' (in package ' || TRIM(f.rdb$package_name) || ')'
                ELSE ''
           END || ASCII_CHAR(10) ||
        ASCII_CHAR(10) ||
        '- Returns: ' || COALESCE(
            (SELECT FIRST 1 COALESCE(arg_type, '(unknown)')
             FROM func_args fa
             WHERE fa.func_name = TRIM(f.rdb$function_name)
               AND (fa.package_name IS NOT DISTINCT FROM TRIM(f.rdb$package_name))
               AND fa.pos = f.rdb$return_argument),
            '(unknown)') || ASCII_CHAR(10) ||
        '- Arguments: ' || COALESCE(
            (SELECT LIST(COALESCE(arg_name, '(unnamed)') || ' ' || COALESCE(arg_type, '(unknown)'), ', ')
             FROM (SELECT arg_name, arg_type FROM func_args fa
                   WHERE fa.func_name = TRIM(f.rdb$function_name)
                     AND (fa.package_name IS NOT DISTINCT FROM TRIM(f.rdb$package_name))
                     AND fa.pos <> f.rdb$return_argument
                   ORDER BY pos)),
            '(none)') AS block_md
    FROM rdb$functions f
    WHERE COALESCE(f.rdb$system_flag, 0) = 0
),

seq_md AS (
    SELECT '- ' || TRIM(rdb$generator_name) AS bullet,
           TRIM(rdb$generator_name) AS seq_name
    FROM rdb$generators
    WHERE COALESCE(rdb$system_flag, 0) = 0
),

pkg_md AS (
    SELECT '- ' || TRIM(rdb$package_name) AS bullet,
           TRIM(rdb$package_name) AS pkg_name
    FROM rdb$packages
    WHERE COALESCE(rdb$system_flag, 0) = 0
),

-- =====================================================================
-- HEADER (metadata) and SECTION ASSEMBLY
-- =====================================================================
header_md AS (
    SELECT
        '# sql-x-ray for Firebird' || ASCII_CHAR(10) ||
        ASCII_CHAR(10) ||
        '- Engine: firebird' || ASCII_CHAR(10) ||
        '- Engine version: ' || COALESCE(rdb$get_context('SYSTEM', 'ENGINE_VERSION'), '(unknown)') || ASCII_CHAR(10) ||
        '- Database: ' || COALESCE(rdb$get_context('SYSTEM', 'DB_NAME'), '(unknown)') || ASCII_CHAR(10) ||
        '- Generated at: ' || CAST(CURRENT_TIMESTAMP AS VARCHAR(64)) || ASCII_CHAR(10) ||
        ASCII_CHAR(10) ||
        '- Privacy note: This document contains only structural ' ||
        'metadata. It deliberately excludes default value literals, ' ||
        'check constraint expressions, view and routine bodies, ' ||
        'computed column expressions, sequence numeric attributes, ' ||
        'descriptions, and all row data. Existence is recorded via ' ||
        'counts (e.g. check constraints, triggers); contents are not.' AS md
    FROM rdb$database
)

-- =====================================================================
-- FINAL ASSEMBLY
--
-- Concatenate header + each section. Each section is built by
-- ordering the per-object blocks and LISTing them with double
-- newlines between blocks.
-- =====================================================================
SELECT
    (SELECT md FROM header_md) || ASCII_CHAR(10) || ASCII_CHAR(10) ||

    '## Tables (' || (SELECT COUNT(*) FROM user_tables) || ')' || ASCII_CHAR(10) || ASCII_CHAR(10) ||
    COALESCE(
        (SELECT LIST(block_md, ASCII_CHAR(10) || ASCII_CHAR(10))
         FROM (SELECT block_md FROM table_block_md ORDER BY relation_name)),
        '(no user tables)'
    ) || ASCII_CHAR(10) || ASCII_CHAR(10) ||

    '## Views (' || (SELECT COUNT(*) FROM user_views) || ')' || ASCII_CHAR(10) || ASCII_CHAR(10) ||
    COALESCE(
        (SELECT LIST(block_md, ASCII_CHAR(10) || ASCII_CHAR(10))
         FROM (SELECT block_md FROM view_block_md ORDER BY relation_name)),
        '(no user views)'
    ) || ASCII_CHAR(10) || ASCII_CHAR(10) ||

    '## Procedures (' || (SELECT COUNT(*) FROM rdb$procedures WHERE COALESCE(rdb$system_flag, 0) = 0) || ')' || ASCII_CHAR(10) || ASCII_CHAR(10) ||
    COALESCE(
        (SELECT LIST(block_md, ASCII_CHAR(10) || ASCII_CHAR(10))
         FROM (SELECT block_md FROM proc_block_md
               ORDER BY COALESCE(package_name, ''), proc_name)),
        '(no user procedures)'
    ) || ASCII_CHAR(10) || ASCII_CHAR(10) ||

    '## Functions (' || (SELECT COUNT(*) FROM rdb$functions WHERE COALESCE(rdb$system_flag, 0) = 0) || ')' || ASCII_CHAR(10) || ASCII_CHAR(10) ||
    COALESCE(
        (SELECT LIST(block_md, ASCII_CHAR(10) || ASCII_CHAR(10))
         FROM (SELECT block_md FROM func_block_md
               ORDER BY COALESCE(package_name, ''), func_name)),
        '(no user functions)'
    ) || ASCII_CHAR(10) || ASCII_CHAR(10) ||

    '## Sequences (' || (SELECT COUNT(*) FROM seq_md) || ')' || ASCII_CHAR(10) || ASCII_CHAR(10) ||
    COALESCE(
        (SELECT LIST(bullet, ASCII_CHAR(10))
         FROM (SELECT bullet FROM seq_md ORDER BY seq_name)),
        '(no user sequences)'
    ) || ASCII_CHAR(10) || ASCII_CHAR(10) ||

    '## Packages (' || (SELECT COUNT(*) FROM pkg_md) || ')' || ASCII_CHAR(10) || ASCII_CHAR(10) ||
    COALESCE(
        (SELECT LIST(bullet, ASCII_CHAR(10))
         FROM (SELECT bullet FROM pkg_md ORDER BY pkg_name)),
        '(no user packages)'
    ) || ASCII_CHAR(10) || ASCII_CHAR(10) ||

    '## Global Temp Tables (' || (SELECT COUNT(*) FROM user_gtts) || ')' || ASCII_CHAR(10) || ASCII_CHAR(10) ||
    COALESCE(
        (SELECT LIST(block_md, ASCII_CHAR(10) || ASCII_CHAR(10))
         FROM (SELECT block_md FROM gtt_block_md ORDER BY relation_name)),
        '(no user global temp tables)'
    )
AS schema_dump
FROM rdb$database;
