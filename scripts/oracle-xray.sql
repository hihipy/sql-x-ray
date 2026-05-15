-- =====================================================================
-- sql-x-ray for Oracle Database 18c+
-- =====================================================================
-- Generates a privacy-safe structural JSON dump of a database schema,
-- suitable as priming context for an LLM.
--
-- Target: Oracle Database 18c+
--   This script relies on:
--     - JSON_OBJECT with VALUE keyword (Oracle 12.2+)
--     - JSON_ARRAYAGG with ORDER BY (Oracle 18c+)
--     - FORMAT JSON clause for embedding JSON inside JSON (12.2+)
--     - RETURNING CLOB on JSON functions to avoid the default
--       VARCHAR2(4000) cap, which overflows easily (ORA-40478)
--   Oracle 19c is the primary test target.
--
-- Catalog source: USER_* views.
--   The script reports objects owned by the currently connected user
--   (i.e. the current schema). If you need to dump a different
--   schema, switch user or use ALTER SESSION SET CURRENT_SCHEMA.
--
-- Usage:
--   1. Connect to Oracle as the schema owner (e.g. HR for the
--      classic sample schema).
--   2. Run this script. The result is a single column SCHEMA_DUMP
--      containing one row of JSON (returned as CLOB).
--
-- What's captured:
--   tables     base tables with kind, partition flag, row count and
--              size estimate (if stats exist), primary key, foreign
--              keys, unique constraints, check_constraint_count,
--              indexes, trigger_count, and columns
--   views      schema-qualified name and column list with types
--   routines   standalone user-defined functions and procedures
--              (name, kind, arguments, return type). Routines inside
--              packages are not unrolled; they appear under the
--              parent package in the packages section.
--   sequences  user-defined sequences (name only)
--   packages   user-defined PL/SQL packages (name only)
--
-- What's deliberately excluded for privacy:
--   - column default value literals (presence flag only)
--   - check constraint expressions (count only)
--   - view bodies, routine bodies, trigger bodies, package bodies
--   - data row contents
--   - sequence numeric attributes
--   - column comments and table comments
--   - dropped objects in the recycle bin (BIN$... names)
--
-- Existence is recorded via counts (e.g. check_constraint_count,
-- trigger_count); contents are not.
-- =====================================================================

WITH

-- =====================================================================
-- COLUMNS per table
--
-- Type rendering notes:
--   VARCHAR2/NVARCHAR2/CHAR/NCHAR: CHAR_LENGTH gives the declared
--     length in characters; CHAR_USED ('C' = CHAR semantics, 'B' =
--     BYTE semantics) only matters for VARCHAR2/CHAR. We append
--     ' BYTE' only when explicitly byte-based, to make CHAR semantics
--     the unmarked default.
--   NUMBER: if DATA_PRECISION is NULL, render as just NUMBER. If
--     precision is set with scale 0, render as NUMBER(p). Otherwise
--     NUMBER(p,s).
--   RAW: takes its length from DATA_LENGTH.
--   TIMESTAMP, INTERVAL, etc.: Oracle stores the precision in
--     DATA_TYPE itself (e.g. 'TIMESTAMP(6)'), so we fall through to
--     use DATA_TYPE as-is for those.
--
-- Source view: USER_TAB_COLS (not USER_TAB_COLUMNS) because we need
-- VIRTUAL_COLUMN, which exists only on the former. We filter
-- HIDDEN_COLUMN = 'NO' to exclude Oracle-generated hidden columns.
-- =====================================================================
cols AS (
    SELECT
        c.table_name,
        JSON_ARRAYAGG(
            JSON_OBJECT(
                'name'         VALUE c.column_name,
                'position'     VALUE c.column_id,
                'data_type'    VALUE
                    CASE c.data_type
                        WHEN 'VARCHAR2' THEN
                            'VARCHAR2(' || c.char_length
                            || CASE WHEN c.char_used = 'B' THEN ' BYTE' ELSE '' END
                            || ')'
                        WHEN 'NVARCHAR2' THEN
                            'NVARCHAR2(' || c.char_length || ')'
                        WHEN 'CHAR' THEN
                            'CHAR(' || c.char_length
                            || CASE WHEN c.char_used = 'B' THEN ' BYTE' ELSE '' END
                            || ')'
                        WHEN 'NCHAR' THEN
                            'NCHAR(' || c.char_length || ')'
                        WHEN 'NUMBER' THEN
                            CASE
                                WHEN c.data_precision IS NULL THEN 'NUMBER'
                                WHEN NVL(c.data_scale, 0) = 0 THEN
                                    'NUMBER(' || c.data_precision || ')'
                                ELSE
                                    'NUMBER(' || c.data_precision || ',' || c.data_scale || ')'
                            END
                        WHEN 'RAW' THEN
                            'RAW(' || c.data_length || ')'
                        WHEN 'FLOAT' THEN
                            CASE
                                WHEN c.data_precision IS NULL THEN 'FLOAT'
                                ELSE 'FLOAT(' || c.data_precision || ')'
                            END
                        ELSE c.data_type
                    END,
                'nullable'     VALUE
                    CASE c.nullable WHEN 'Y' THEN 'true' ELSE 'false' END FORMAT JSON,
                'is_identity'  VALUE
                    CASE WHEN c.identity_column = 'YES' THEN 'true' ELSE 'false' END FORMAT JSON,
                'is_generated' VALUE
                    CASE WHEN c.virtual_column = 'YES' THEN 'true' ELSE 'false' END FORMAT JSON,
                'has_default'  VALUE
                    CASE WHEN c.data_default IS NOT NULL THEN 'true' ELSE 'false' END FORMAT JSON
                RETURNING CLOB
            )
            ORDER BY c.column_id
            RETURNING CLOB
        ) AS columns
    FROM user_tab_cols c
    JOIN user_tables t ON t.table_name = c.table_name
    WHERE c.table_name NOT LIKE 'BIN$%'
      AND c.hidden_column = 'NO'
    GROUP BY c.table_name
),

-- =====================================================================
-- PRIMARY KEYS
-- =====================================================================
pk_cols AS (
    SELECT
        cc.table_name,
        cc.constraint_name,
        JSON_ARRAYAGG(cc.column_name ORDER BY cc.position RETURNING CLOB) AS columns
    FROM user_constraints c
    JOIN user_cons_columns cc
      ON cc.constraint_name = c.constraint_name
    WHERE c.constraint_type = 'P'
      AND cc.table_name NOT LIKE 'BIN$%'
    GROUP BY cc.table_name, cc.constraint_name
),
pks AS (
    SELECT
        table_name,
        JSON_OBJECT('columns' VALUE columns FORMAT JSON RETURNING CLOB) AS primary_key
    FROM pk_cols
),

-- =====================================================================
-- FOREIGN KEYS
-- =====================================================================
fk_constraints AS (
    SELECT
        c.constraint_name,
        c.table_name,
        c.r_constraint_name,
        c.delete_rule
    FROM user_constraints c
    WHERE c.constraint_type = 'R'
      AND c.table_name NOT LIKE 'BIN$%'
),
fk_from_cols AS (
    SELECT
        fkc.constraint_name,
        JSON_ARRAYAGG(fkc.column_name ORDER BY fkc.position RETURNING CLOB) AS from_columns
    FROM fk_constraints fk
    JOIN user_cons_columns fkc
      ON fkc.constraint_name = fk.constraint_name
    GROUP BY fkc.constraint_name
),
fk_target AS (
    SELECT
        fk.constraint_name,
        fk.table_name,
        fk.delete_rule,
        rc.table_name AS referenced_table,
        rc.constraint_name AS referenced_constraint_name
    FROM fk_constraints fk
    JOIN user_constraints rc
      ON rc.constraint_name = fk.r_constraint_name
),
fk_to_cols AS (
    SELECT
        fkt.constraint_name,
        JSON_ARRAYAGG(rcc.column_name ORDER BY rcc.position RETURNING CLOB) AS to_columns
    FROM fk_target fkt
    JOIN user_cons_columns rcc
      ON rcc.constraint_name = fkt.referenced_constraint_name
    GROUP BY fkt.constraint_name
),
fks AS (
    SELECT
        fkt.table_name,
        JSON_ARRAYAGG(
            JSON_OBJECT(
                'from_columns' VALUE ffc.from_columns FORMAT JSON,
                'to_table'     VALUE fkt.referenced_table,
                'to_columns'   VALUE ftc.to_columns FORMAT JSON,
                'on_delete'    VALUE fkt.delete_rule
                RETURNING CLOB
            )
            ORDER BY fkt.constraint_name
            RETURNING CLOB
        ) AS foreign_keys
    FROM fk_target fkt
    LEFT JOIN fk_from_cols ffc ON ffc.constraint_name = fkt.constraint_name
    LEFT JOIN fk_to_cols   ftc ON ftc.constraint_name = fkt.constraint_name
    GROUP BY fkt.table_name
),

-- =====================================================================
-- UNIQUE CONSTRAINTS
-- =====================================================================
uq_cols AS (
    SELECT
        cc.table_name,
        cc.constraint_name,
        JSON_ARRAYAGG(cc.column_name ORDER BY cc.position RETURNING CLOB) AS columns
    FROM user_constraints c
    JOIN user_cons_columns cc
      ON cc.constraint_name = c.constraint_name
    WHERE c.constraint_type = 'U'
      AND cc.table_name NOT LIKE 'BIN$%'
    GROUP BY cc.table_name, cc.constraint_name
),
uqs AS (
    SELECT
        table_name,
        JSON_ARRAYAGG(
            JSON_OBJECT('columns' VALUE columns FORMAT JSON RETURNING CLOB)
            ORDER BY constraint_name
            RETURNING CLOB
        ) AS unique_constraints
    FROM uq_cols
    GROUP BY table_name
),

-- =====================================================================
-- CHECK CONSTRAINTS (count only)
--
-- Oracle exposes NOT NULL constraints as CHECK constraints with
-- SEARCH_CONDITION like '"COL" IS NOT NULL'. We filter those out
-- so the count reflects only user-written CHECKs.
-- =====================================================================
check_counts AS (
    SELECT
        c.table_name,
        COUNT(*) AS check_count
    FROM user_constraints c
    WHERE c.constraint_type = 'C'
      AND c.table_name NOT LIKE 'BIN$%'
      AND c.search_condition_vc NOT LIKE '%IS NOT NULL'
    GROUP BY c.table_name
),

-- =====================================================================
-- INDEXES (excluding PK and unique constraint indexes)
-- =====================================================================
non_constraint_indexes AS (
    SELECT
        i.index_name,
        i.table_name,
        i.uniqueness,
        i.index_type
    FROM user_indexes i
    WHERE i.table_name NOT LIKE 'BIN$%'
      AND i.index_name NOT LIKE 'BIN$%'
      AND NOT EXISTS (
          SELECT 1 FROM user_constraints c
          WHERE c.index_name = i.index_name
            AND c.constraint_type IN ('P', 'U')
      )
),
index_columns_data AS (
    SELECT
        nci.table_name,
        nci.index_name,
        nci.uniqueness,
        nci.index_type,
        JSON_ARRAYAGG(ic.column_name ORDER BY ic.column_position RETURNING CLOB) AS columns
    FROM non_constraint_indexes nci
    JOIN user_ind_columns ic
      ON ic.index_name = nci.index_name
    GROUP BY nci.table_name, nci.index_name, nci.uniqueness, nci.index_type
),
idx AS (
    SELECT
        table_name,
        JSON_ARRAYAGG(
            JSON_OBJECT(
                'name'    VALUE index_name,
                'method'  VALUE index_type,
                'unique'  VALUE CASE WHEN uniqueness = 'UNIQUE' THEN 'true' ELSE 'false' END FORMAT JSON,
                'columns' VALUE columns FORMAT JSON
                RETURNING CLOB
            )
            ORDER BY index_name
            RETURNING CLOB
        ) AS indexes
    FROM index_columns_data
    GROUP BY table_name
),

-- =====================================================================
-- TRIGGER counts per table
-- =====================================================================
trigger_counts AS (
    SELECT
        t.table_name,
        COUNT(*) AS trigger_count
    FROM user_triggers t
    WHERE t.base_object_type = 'TABLE'
      AND t.table_name NOT LIKE 'BIN$%'
    GROUP BY t.table_name
),

-- =====================================================================
-- TABLE METADATA
-- =====================================================================
tbl_meta AS (
    SELECT
        t.table_name,
        CASE WHEN t.partitioned = 'YES' THEN 'true' ELSE 'false' END AS is_partitioned,
        t.num_rows AS row_count_estimate,
        t.blocks * 8192 AS total_size_bytes
    FROM user_tables t
    WHERE t.table_name NOT LIKE 'BIN$%'
),

-- =====================================================================
-- TABLES JSON
-- =====================================================================
tables_json AS (
    SELECT JSON_ARRAYAGG(
        JSON_OBJECT(
            'schema'                 VALUE SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA'),
            'name'                   VALUE tm.table_name,
            'kind'                   VALUE 'table',
            'is_partitioned'         VALUE tm.is_partitioned FORMAT JSON,
            'row_count_estimate'     VALUE tm.row_count_estimate,
            'total_size_bytes'       VALUE tm.total_size_bytes,
            'primary_key'            VALUE pks.primary_key FORMAT JSON,
            'foreign_keys'           VALUE fks.foreign_keys FORMAT JSON,
            'unique_constraints'     VALUE uqs.unique_constraints FORMAT JSON,
            'check_constraint_count' VALUE NVL(cc.check_count, 0),
            'indexes'                VALUE idx.indexes FORMAT JSON,
            'trigger_count'          VALUE NVL(tc.trigger_count, 0),
            'columns'                VALUE c.columns FORMAT JSON
            RETURNING CLOB
        )
        ORDER BY tm.table_name
        RETURNING CLOB
    ) AS payload
    FROM tbl_meta tm
    LEFT JOIN cols           c   ON c.table_name   = tm.table_name
    LEFT JOIN pks            pks ON pks.table_name = tm.table_name
    LEFT JOIN fks            fks ON fks.table_name = tm.table_name
    LEFT JOIN uqs            uqs ON uqs.table_name = tm.table_name
    LEFT JOIN check_counts   cc  ON cc.table_name  = tm.table_name
    LEFT JOIN idx            idx ON idx.table_name = tm.table_name
    LEFT JOIN trigger_counts tc  ON tc.table_name  = tm.table_name
),

-- =====================================================================
-- VIEWS
-- =====================================================================
view_cols AS (
    SELECT
        c.table_name AS view_name,
        JSON_ARRAYAGG(
            JSON_OBJECT(
                'name'      VALUE c.column_name,
                'position'  VALUE c.column_id,
                'data_type' VALUE
                    CASE c.data_type
                        WHEN 'VARCHAR2' THEN
                            'VARCHAR2(' || c.char_length
                            || CASE WHEN c.char_used = 'B' THEN ' BYTE' ELSE '' END
                            || ')'
                        WHEN 'NVARCHAR2' THEN
                            'NVARCHAR2(' || c.char_length || ')'
                        WHEN 'CHAR' THEN
                            'CHAR(' || c.char_length
                            || CASE WHEN c.char_used = 'B' THEN ' BYTE' ELSE '' END
                            || ')'
                        WHEN 'NCHAR' THEN
                            'NCHAR(' || c.char_length || ')'
                        WHEN 'NUMBER' THEN
                            CASE
                                WHEN c.data_precision IS NULL THEN 'NUMBER'
                                WHEN NVL(c.data_scale, 0) = 0 THEN
                                    'NUMBER(' || c.data_precision || ')'
                                ELSE
                                    'NUMBER(' || c.data_precision || ',' || c.data_scale || ')'
                            END
                        WHEN 'RAW' THEN
                            'RAW(' || c.data_length || ')'
                        ELSE c.data_type
                    END,
                'nullable'  VALUE
                    CASE c.nullable WHEN 'Y' THEN 'true' ELSE 'false' END FORMAT JSON
                RETURNING CLOB
            )
            ORDER BY c.column_id
            RETURNING CLOB
        ) AS columns
    FROM user_tab_columns c
    JOIN user_views v ON v.view_name = c.table_name
    GROUP BY c.table_name
),
views_json AS (
    SELECT JSON_ARRAYAGG(
        JSON_OBJECT(
            'schema'  VALUE SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA'),
            'name'    VALUE v.view_name,
            'kind'    VALUE 'view',
            'columns' VALUE vc.columns FORMAT JSON
            RETURNING CLOB
        )
        ORDER BY v.view_name
        RETURNING CLOB
    ) AS payload
    FROM user_views v
    LEFT JOIN view_cols vc ON vc.view_name = v.view_name
),

-- =====================================================================
-- ROUTINES (standalone procedures and functions, not in packages)
-- =====================================================================
routine_args AS (
    SELECT
        a.object_name AS routine_name,
        LISTAGG(
            CASE a.in_out
                WHEN 'IN' THEN 'IN '
                WHEN 'OUT' THEN 'OUT '
                ELSE 'INOUT '
            END
            || a.argument_name || ' ' || a.data_type,
            ', '
        ) WITHIN GROUP (ORDER BY a.position) AS args
    FROM user_arguments a
    WHERE a.package_name IS NULL
      AND a.argument_name IS NOT NULL
    GROUP BY a.object_name
),
return_types AS (
    SELECT
        a.object_name AS routine_name,
        a.data_type   AS return_type
    FROM user_arguments a
    WHERE a.package_name IS NULL
      AND a.argument_name IS NULL
      AND a.position = 0
),
routines_json AS (
    SELECT JSON_ARRAYAGG(
        JSON_OBJECT(
            'schema'     VALUE SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA'),
            'name'       VALUE p.object_name,
            'kind'       VALUE LOWER(p.object_type),
            'language'   VALUE 'plsql',
            'returns'    VALUE rt.return_type,
            'arguments'  VALUE NVL(ra.args, ''),
            'is_trigger' VALUE 'false' FORMAT JSON
            RETURNING CLOB
        )
        ORDER BY p.object_name
        RETURNING CLOB
    ) AS payload
    FROM user_procedures p
    LEFT JOIN routine_args ra ON ra.routine_name = p.object_name
    LEFT JOIN return_types rt ON rt.routine_name = p.object_name
    WHERE p.object_type IN ('PROCEDURE', 'FUNCTION')
      AND p.object_name NOT LIKE 'BIN$%'
),

-- =====================================================================
-- SEQUENCES
-- =====================================================================
sequences_json AS (
    SELECT JSON_ARRAYAGG(
        JSON_OBJECT(
            'schema' VALUE SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA'),
            'name'   VALUE s.sequence_name,
            'kind'   VALUE 'sequence'
            RETURNING CLOB
        )
        ORDER BY s.sequence_name
        RETURNING CLOB
    ) AS payload
    FROM user_sequences s
),

-- =====================================================================
-- PACKAGES (name only; package members not unrolled in v1)
-- =====================================================================
packages_json AS (
    SELECT JSON_ARRAYAGG(
        JSON_OBJECT(
            'schema' VALUE SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA'),
            'name'   VALUE o.object_name,
            'kind'   VALUE 'package'
            RETURNING CLOB
        )
        ORDER BY o.object_name
        RETURNING CLOB
    ) AS payload
    FROM user_objects o
    WHERE o.object_type = 'PACKAGE'
      AND o.object_name NOT LIKE 'BIN$%'
),

-- =====================================================================
-- METADATA
-- =====================================================================
meta AS (
    SELECT JSON_OBJECT(
        'tool_name'      VALUE 'sql-x-ray',
        'engine'         VALUE 'oracle',
        'engine_version' VALUE (SELECT version_full FROM product_component_version WHERE ROWNUM = 1),
        'database'       VALUE SYS_CONTEXT('USERENV', 'DB_NAME'),
        'generated_at'   VALUE TO_CHAR(SYS_EXTRACT_UTC(SYSTIMESTAMP), 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
        'schema_filter'  VALUE SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA'),
        'schemas'        VALUE JSON_ARRAY(SYS_CONTEXT('USERENV', 'CURRENT_SCHEMA') RETURNING CLOB) FORMAT JSON,
        'privacy_note'   VALUE
            'This document contains only structural metadata. '
         || 'It deliberately excludes default value literals, '
         || 'check constraint expressions, view and routine bodies, '
         || 'computed column expressions, sequence numeric attributes, '
         || 'column and table comments, and all row data. Existence '
         || 'is recorded via counts (e.g. check_constraint_count); '
         || 'contents are not.'
        RETURNING CLOB
    ) AS payload
    FROM dual
)

-- =====================================================================
-- FINAL ASSEMBLY
-- =====================================================================
SELECT JSON_OBJECT(
    'metadata'  VALUE (SELECT payload FROM meta) FORMAT JSON,
    'tables'    VALUE NVL((SELECT payload FROM tables_json),    TO_CLOB('[]')) FORMAT JSON,
    'views'     VALUE NVL((SELECT payload FROM views_json),     TO_CLOB('[]')) FORMAT JSON,
    'routines'  VALUE NVL((SELECT payload FROM routines_json),  TO_CLOB('[]')) FORMAT JSON,
    'sequences' VALUE NVL((SELECT payload FROM sequences_json), TO_CLOB('[]')) FORMAT JSON,
    'packages'  VALUE NVL((SELECT payload FROM packages_json),  TO_CLOB('[]')) FORMAT JSON,
    'types'     VALUE TO_CLOB('[]') FORMAT JSON
    RETURNING CLOB
) AS schema_dump
FROM dual;
