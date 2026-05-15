-- =====================================================================
-- mysql-xray.sql
-- =====================================================================
-- sql-x-ray: See the structure, not the data.
-- https://github.com/hihipy/sql-x-ray
--
-- Privacy-safe MySQL schema introspection for LLM context.
--
-- WHAT THIS DOES
--   Outputs a single JSON document describing the SHAPE of a MySQL
--   database: tables, columns, types, relationships, indexes, and
--   constraint existence. Designed to be fed to any LLM as priming
--   context so it can write accurate queries against your schema.
--
-- WHAT THIS DELIBERATELY DOES NOT INCLUDE
--   This script never extracts values that could carry sensitive data:
--     - No ENUM / SET value labels (column type reduced to "enum" or
--       "set" without the value list)
--     - No CHECK constraint expressions (counts only)
--     - No default-value literals (existence only)
--     - No view definitions or routine bodies (signatures only)
--     - No table or column comments (free text, could be anything)
--     - No row data of any kind
--   It DOES include the existence and count of each of the above.
--
-- COMPATIBILITY
--   MySQL 8.0.16 or newer. No extensions or plugins required.
--   Tested on MySQL 8.0 and 9.x with the Sakila sample database.
--   MariaDB is NOT supported. Its catalog views diverge meaningfully
--   from MySQL's; see mariadb-xray.sql.
--
-- A NOTE ON "SCHEMA" IN MYSQL
--   MySQL treats "database" and "schema" as synonyms. This script uses
--   "schema" in the output JSON to stay consistent with the Postgres
--   version. Each entry in metadata.schemas is one MySQL database.
--
-- TWO MYSQL QUIRKS THIS WORKS AROUND
--
--   1. Inconsistent information_schema collations. On many MySQL
--      installations the I_S views have a mix of utf8mb3_general_ci
--      and utf8mb3_unicode_ci across different tables. Direct equality
--      between schema names from different I_S tables throws "Illegal
--      mix of collations". This script wraps every cross-table name
--      comparison in CONVERT(... USING utf8mb4) on both sides.
--
--      A small number of hosted MySQL sandboxes (notably sqlize.online)
--      appear to drop the CONVERT during CTE materialization, which
--      leaves the routines array and trigger_count fields empty even
--      though every comparison has been wrapped. Standard MySQL 8+ and
--      9+ installations use utf8mb4 throughout information_schema and
--      are not affected. If you see empty routines or zero trigger
--      counts on a database where you know both exist, the underlying
--      cause is the catalog collation mix, not the script.
--
--   2. JSON_ARRAYAGG has no ORDER BY clause in MySQL 8.0 or 9.0, and
--      the optimizer is free to drop ORDER BY from a derived table
--      feeding an aggregate. Column orderings get scrambled. This
--      script builds ordered JSON arrays using GROUP_CONCAT, which
--      does support ORDER BY natively. Output is cast back to JSON.
--      The session variable group_concat_max_len is raised to its
--      maximum so wide tables don't get truncated.
--
-- USAGE
--   Edit the three SET statements below, then run.
--   Result is a single cell containing a pretty-printed JSON document.
--   Save the cell contents as schema.json and feed to your LLM.
--
-- LICENSE
--   CC BY-NC-SA 4.0 - https://creativecommons.org/licenses/by-nc-sa/4.0/
-- =====================================================================

-- ---------------------------------------------------------------------
-- Configuration. Edit these three lines, then run.
--   @schema_filter   '%' for every non-system database, an exact name
--                    like 'sakila', or a LIKE pattern like 'app_%'
--   @include_stats   TRUE to include row count estimates and on-disk
--                    sizes, FALSE to skip
--   @pretty_print    TRUE to format JSON with line breaks
-- ---------------------------------------------------------------------
SET @schema_filter = '%';
SET @include_stats = TRUE;
SET @pretty_print  = TRUE;

-- Raise GROUP_CONCAT length cap to its maximum so column arrays on
-- wide tables and large schemas are never truncated. On exceptionally
-- large schemas, max_allowed_packet can also cap the final result
-- size before it reaches your client; bump it at the server or
-- session level if you hit a truncated JSON document.
SET SESSION group_concat_max_len = 4294967295;

WITH

-- =====================================================================
-- COLUMNS (table columns; view columns handled separately below)
-- =====================================================================
cols AS (
    SELECT
        CONVERT(c.TABLE_SCHEMA USING utf8mb4) AS schema_name,
        CONVERT(c.TABLE_NAME   USING utf8mb4) AS table_name,
        CAST(CONCAT('[', GROUP_CONCAT(
            JSON_OBJECT(
                'name',         c.COLUMN_NAME,
                'position',     c.ORDINAL_POSITION,
                'data_type',    CASE
                                    WHEN c.DATA_TYPE IN ('enum', 'set')
                                      THEN c.DATA_TYPE
                                    ELSE c.COLUMN_TYPE
                                END,
                'nullable',     c.IS_NULLABLE = 'YES',
                'is_identity',  c.EXTRA LIKE '%auto_increment%',
                'is_generated', c.EXTRA LIKE '%GENERATED%',
                'has_default',  c.COLUMN_DEFAULT IS NOT NULL
                                   OR c.EXTRA LIKE '%DEFAULT_GENERATED%'
            )
            ORDER BY c.ORDINAL_POSITION SEPARATOR ','
        ), ']') AS JSON) AS columns
    FROM information_schema.COLUMNS c
    WHERE c.TABLE_SCHEMA LIKE @schema_filter
      AND c.TABLE_SCHEMA NOT IN ('mysql', 'information_schema',
                                  'performance_schema', 'sys')
    GROUP BY c.TABLE_SCHEMA, c.TABLE_NAME
),

-- =====================================================================
-- PRIMARY KEYS
-- =====================================================================
pks AS (
    SELECT
        CONVERT(k.TABLE_SCHEMA USING utf8mb4) AS schema_name,
        CONVERT(k.TABLE_NAME   USING utf8mb4) AS table_name,
        JSON_OBJECT('columns', CAST(CONCAT('[', GROUP_CONCAT(
            JSON_QUOTE(k.COLUMN_NAME)
            ORDER BY k.ORDINAL_POSITION SEPARATOR ','
        ), ']') AS JSON)) AS primary_key
    FROM information_schema.KEY_COLUMN_USAGE k
    WHERE k.CONSTRAINT_NAME = 'PRIMARY'
      AND k.TABLE_SCHEMA LIKE @schema_filter
      AND k.TABLE_SCHEMA NOT IN ('mysql', 'information_schema',
                                  'performance_schema', 'sys')
    GROUP BY k.TABLE_SCHEMA, k.TABLE_NAME
),

-- =====================================================================
-- FOREIGN KEYS
-- Two stages: group columns into from/to arrays per constraint, then
-- aggregate constraints per table.
-- =====================================================================
fk_constraints AS (
    SELECT
        CONVERT(k.TABLE_SCHEMA             USING utf8mb4) AS schema_name,
        CONVERT(k.TABLE_NAME               USING utf8mb4) AS table_name,
        CONVERT(k.CONSTRAINT_NAME          USING utf8mb4) AS constraint_name,
        CONVERT(k.REFERENCED_TABLE_SCHEMA  USING utf8mb4) AS referenced_schema,
        CONVERT(k.REFERENCED_TABLE_NAME    USING utf8mb4) AS referenced_table,
        CAST(CONCAT('[', GROUP_CONCAT(
            JSON_QUOTE(k.COLUMN_NAME)
            ORDER BY k.ORDINAL_POSITION SEPARATOR ','
        ), ']') AS JSON) AS from_columns,
        CAST(CONCAT('[', GROUP_CONCAT(
            JSON_QUOTE(k.REFERENCED_COLUMN_NAME)
            ORDER BY k.ORDINAL_POSITION SEPARATOR ','
        ), ']') AS JSON) AS to_columns
    FROM information_schema.KEY_COLUMN_USAGE k
    WHERE k.REFERENCED_TABLE_NAME IS NOT NULL
      AND k.TABLE_SCHEMA LIKE @schema_filter
      AND k.TABLE_SCHEMA NOT IN ('mysql', 'information_schema',
                                  'performance_schema', 'sys')
    GROUP BY k.TABLE_SCHEMA, k.TABLE_NAME, k.CONSTRAINT_NAME,
             k.REFERENCED_TABLE_SCHEMA, k.REFERENCED_TABLE_NAME
),
fks AS (
    SELECT
        fc.schema_name,
        fc.table_name,
        CAST(CONCAT('[', GROUP_CONCAT(
            JSON_OBJECT(
                'from_columns', fc.from_columns,
                'to_schema',    fc.referenced_schema,
                'to_table',     fc.referenced_table,
                'to_columns',   fc.to_columns,
                'on_update',    rc.UPDATE_RULE,
                'on_delete',    rc.DELETE_RULE
            )
            ORDER BY fc.constraint_name SEPARATOR ','
        ), ']') AS JSON) AS foreign_keys
    FROM fk_constraints fc
    JOIN information_schema.REFERENTIAL_CONSTRAINTS rc
      ON CONVERT(rc.CONSTRAINT_SCHEMA USING utf8mb4) = fc.schema_name
     AND CONVERT(rc.CONSTRAINT_NAME   USING utf8mb4) = fc.constraint_name
    GROUP BY fc.schema_name, fc.table_name
),

-- =====================================================================
-- UNIQUE CONSTRAINTS
-- =====================================================================
uq_grouped AS (
    SELECT
        CONVERT(kcu.TABLE_SCHEMA     USING utf8mb4) AS schema_name,
        CONVERT(kcu.TABLE_NAME       USING utf8mb4) AS table_name,
        CONVERT(kcu.CONSTRAINT_NAME  USING utf8mb4) AS constraint_name,
        CAST(CONCAT('[', GROUP_CONCAT(
            JSON_QUOTE(kcu.COLUMN_NAME)
            ORDER BY kcu.ORDINAL_POSITION SEPARATOR ','
        ), ']') AS JSON) AS columns
    FROM information_schema.KEY_COLUMN_USAGE kcu
    JOIN information_schema.TABLE_CONSTRAINTS tc
      ON CONVERT(tc.CONSTRAINT_SCHEMA USING utf8mb4) = CONVERT(kcu.CONSTRAINT_SCHEMA USING utf8mb4)
     AND CONVERT(tc.CONSTRAINT_NAME   USING utf8mb4) = CONVERT(kcu.CONSTRAINT_NAME   USING utf8mb4)
     AND CONVERT(tc.TABLE_SCHEMA      USING utf8mb4) = CONVERT(kcu.TABLE_SCHEMA      USING utf8mb4)
     AND CONVERT(tc.TABLE_NAME        USING utf8mb4) = CONVERT(kcu.TABLE_NAME        USING utf8mb4)
    WHERE tc.CONSTRAINT_TYPE = 'UNIQUE'
      AND kcu.TABLE_SCHEMA LIKE @schema_filter
      AND kcu.TABLE_SCHEMA NOT IN ('mysql', 'information_schema',
                                    'performance_schema', 'sys')
    GROUP BY kcu.TABLE_SCHEMA, kcu.TABLE_NAME, kcu.CONSTRAINT_NAME
),
uqs AS (
    SELECT
        schema_name,
        table_name,
        CAST(CONCAT('[', GROUP_CONCAT(
            JSON_OBJECT('columns', columns)
            ORDER BY constraint_name SEPARATOR ','
        ), ']') AS JSON) AS unique_constraints
    FROM uq_grouped
    GROUP BY schema_name, table_name
),

-- =====================================================================
-- CHECK CONSTRAINT COUNTS
-- =====================================================================
checks AS (
    SELECT
        CONVERT(tc.TABLE_SCHEMA USING utf8mb4) AS schema_name,
        CONVERT(tc.TABLE_NAME   USING utf8mb4) AS table_name,
        COUNT(*) AS check_constraint_count
    FROM information_schema.TABLE_CONSTRAINTS tc
    WHERE tc.CONSTRAINT_TYPE = 'CHECK'
      AND tc.TABLE_SCHEMA LIKE @schema_filter
      AND tc.TABLE_SCHEMA NOT IN ('mysql', 'information_schema',
                                   'performance_schema', 'sys')
    GROUP BY tc.TABLE_SCHEMA, tc.TABLE_NAME
),

-- =====================================================================
-- INDEXES (excludes PK-backing and unique-backing indexes)
-- Functional indexes have NULL COLUMN_NAME; rendered as <expression>.
-- =====================================================================
index_columns AS (
    SELECT
        CONVERT(s.TABLE_SCHEMA USING utf8mb4) AS schema_name,
        CONVERT(s.TABLE_NAME   USING utf8mb4) AS table_name,
        CONVERT(s.INDEX_NAME   USING utf8mb4) AS index_name,
        MAX(s.NON_UNIQUE) AS non_unique,
        MAX(s.INDEX_TYPE) AS index_type,
        CAST(CONCAT('[', GROUP_CONCAT(
            JSON_QUOTE(CASE
                WHEN s.COLUMN_NAME IS NULL AND s.EXPRESSION IS NOT NULL
                  THEN '<expression>'
                ELSE s.COLUMN_NAME
            END)
            ORDER BY s.SEQ_IN_INDEX SEPARATOR ','
        ), ']') AS JSON) AS columns
    FROM information_schema.STATISTICS s
    WHERE s.INDEX_NAME <> 'PRIMARY'
      AND s.TABLE_SCHEMA LIKE @schema_filter
      AND s.TABLE_SCHEMA NOT IN ('mysql', 'information_schema',
                                  'performance_schema', 'sys')
      AND NOT EXISTS (
          SELECT 1
          FROM information_schema.TABLE_CONSTRAINTS tc
          WHERE CONVERT(tc.TABLE_SCHEMA    USING utf8mb4) = CONVERT(s.TABLE_SCHEMA USING utf8mb4)
            AND CONVERT(tc.TABLE_NAME      USING utf8mb4) = CONVERT(s.TABLE_NAME   USING utf8mb4)
            AND CONVERT(tc.CONSTRAINT_NAME USING utf8mb4) = CONVERT(s.INDEX_NAME   USING utf8mb4)
            AND tc.CONSTRAINT_TYPE = 'UNIQUE'
      )
    GROUP BY s.TABLE_SCHEMA, s.TABLE_NAME, s.INDEX_NAME
),
idx AS (
    SELECT
        schema_name,
        table_name,
        CAST(CONCAT('[', GROUP_CONCAT(
            JSON_OBJECT(
                'name',    index_name,
                'method',  index_type,
                'unique',  non_unique = 0,
                'columns', columns
            )
            ORDER BY index_name SEPARATOR ','
        ), ']') AS JSON) AS indexes
    FROM index_columns
    GROUP BY schema_name, table_name
),

-- =====================================================================
-- TRIGGER COUNTS
-- =====================================================================
trgs AS (
    SELECT
        CONVERT(t.EVENT_OBJECT_SCHEMA USING utf8mb4) AS schema_name,
        CONVERT(t.EVENT_OBJECT_TABLE  USING utf8mb4) AS table_name,
        COUNT(*) AS trigger_count
    FROM information_schema.TRIGGERS t
    WHERE t.EVENT_OBJECT_SCHEMA LIKE @schema_filter
      AND t.EVENT_OBJECT_SCHEMA NOT IN ('mysql', 'information_schema',
                                         'performance_schema', 'sys')
    GROUP BY t.EVENT_OBJECT_SCHEMA, t.EVENT_OBJECT_TABLE
),

-- =====================================================================
-- PARTITIONING FLAG
-- =====================================================================
partitioned AS (
    SELECT DISTINCT
        CONVERT(p.TABLE_SCHEMA USING utf8mb4) AS schema_name,
        CONVERT(p.TABLE_NAME   USING utf8mb4) AS table_name
    FROM information_schema.PARTITIONS p
    WHERE p.PARTITION_NAME IS NOT NULL
      AND p.TABLE_SCHEMA LIKE @schema_filter
      AND p.TABLE_SCHEMA NOT IN ('mysql', 'information_schema',
                                  'performance_schema', 'sys')
),

-- =====================================================================
-- TABLE METADATA (kind, engine, partition flag, stats)
-- Stats are included only when @include_stats is TRUE.
-- =====================================================================
tbl_meta AS (
    SELECT
        CONVERT(t.TABLE_SCHEMA USING utf8mb4) AS schema_name,
        CONVERT(t.TABLE_NAME   USING utf8mb4) AS table_name,
        'table' AS kind,
        t.ENGINE AS engine,
        CASE WHEN pt.table_name IS NOT NULL THEN TRUE END AS is_partitioned,
        CASE WHEN @include_stats THEN t.TABLE_ROWS END AS row_count_estimate,
        CASE WHEN @include_stats
             THEN COALESCE(t.DATA_LENGTH, 0) + COALESCE(t.INDEX_LENGTH, 0)
        END AS total_size_bytes
    FROM information_schema.TABLES t
    LEFT JOIN partitioned pt
      ON pt.schema_name = CONVERT(t.TABLE_SCHEMA USING utf8mb4)
     AND pt.table_name  = CONVERT(t.TABLE_NAME   USING utf8mb4)
    WHERE t.TABLE_TYPE = 'BASE TABLE'
      AND t.TABLE_SCHEMA LIKE @schema_filter
      AND t.TABLE_SCHEMA NOT IN ('mysql', 'information_schema',
                                  'performance_schema', 'sys')
),

-- =====================================================================
-- ASSEMBLE TABLES
-- All CTE schema_name and table_name values are utf8mb4, so direct
-- equality joins work without further conversion.
-- =====================================================================
tables_json AS (
    SELECT CAST(CONCAT('[', GROUP_CONCAT(
        JSON_OBJECT(
            'schema',                 tm.schema_name,
            'name',                   tm.table_name,
            'kind',                   tm.kind,
            'engine',                 tm.engine,
            'is_partitioned',         tm.is_partitioned,
            'row_count_estimate',     tm.row_count_estimate,
            'total_size_bytes',       tm.total_size_bytes,
            'primary_key',            pks.primary_key,
            'foreign_keys',           fks.foreign_keys,
            'unique_constraints',     uqs.unique_constraints,
            'check_constraint_count', COALESCE(checks.check_constraint_count, 0),
            'indexes',                idx.indexes,
            'trigger_count',          COALESCE(trgs.trigger_count, 0),
            'columns',                cols.columns
        )
        ORDER BY tm.schema_name, tm.table_name SEPARATOR ','
    ), ']') AS JSON) AS payload
    FROM tbl_meta tm
    LEFT JOIN cols   ON cols.schema_name   = tm.schema_name AND cols.table_name   = tm.table_name
    LEFT JOIN pks    ON pks.schema_name    = tm.schema_name AND pks.table_name    = tm.table_name
    LEFT JOIN fks    ON fks.schema_name    = tm.schema_name AND fks.table_name    = tm.table_name
    LEFT JOIN uqs    ON uqs.schema_name    = tm.schema_name AND uqs.table_name    = tm.table_name
    LEFT JOIN checks ON checks.schema_name = tm.schema_name AND checks.table_name = tm.table_name
    LEFT JOIN idx    ON idx.schema_name    = tm.schema_name AND idx.table_name    = tm.table_name
    LEFT JOIN trgs   ON trgs.schema_name   = tm.schema_name AND trgs.table_name   = tm.table_name
),

-- =====================================================================
-- VIEWS
-- =====================================================================
view_cols AS (
    SELECT
        CONVERT(c.TABLE_SCHEMA USING utf8mb4) AS schema_name,
        CONVERT(c.TABLE_NAME   USING utf8mb4) AS view_name,
        CAST(CONCAT('[', GROUP_CONCAT(
            JSON_OBJECT(
                'name',      c.COLUMN_NAME,
                'position',  c.ORDINAL_POSITION,
                'data_type', CASE
                                 WHEN c.DATA_TYPE IN ('enum', 'set')
                                   THEN c.DATA_TYPE
                                 ELSE c.COLUMN_TYPE
                             END,
                'nullable',  c.IS_NULLABLE = 'YES'
            )
            ORDER BY c.ORDINAL_POSITION SEPARATOR ','
        ), ']') AS JSON) AS columns
    FROM information_schema.COLUMNS c
    JOIN information_schema.VIEWS v
      ON CONVERT(v.TABLE_SCHEMA USING utf8mb4) = CONVERT(c.TABLE_SCHEMA USING utf8mb4)
     AND CONVERT(v.TABLE_NAME   USING utf8mb4) = CONVERT(c.TABLE_NAME   USING utf8mb4)
    WHERE c.TABLE_SCHEMA LIKE @schema_filter
      AND c.TABLE_SCHEMA NOT IN ('mysql', 'information_schema',
                                  'performance_schema', 'sys')
    GROUP BY c.TABLE_SCHEMA, c.TABLE_NAME
),
views_json AS (
    SELECT CAST(CONCAT('[', GROUP_CONCAT(
        JSON_OBJECT(
            'schema',  CONVERT(v.TABLE_SCHEMA USING utf8mb4),
            'name',    CONVERT(v.TABLE_NAME   USING utf8mb4),
            'kind',    'view',
            'columns', vc.columns
        )
        ORDER BY v.TABLE_SCHEMA, v.TABLE_NAME SEPARATOR ','
    ), ']') AS JSON) AS payload
    FROM information_schema.VIEWS v
    LEFT JOIN view_cols vc
      ON vc.schema_name = CONVERT(v.TABLE_SCHEMA USING utf8mb4)
     AND vc.view_name   = CONVERT(v.TABLE_NAME   USING utf8mb4)
    WHERE v.TABLE_SCHEMA LIKE @schema_filter
      AND v.TABLE_SCHEMA NOT IN ('mysql', 'information_schema',
                                  'performance_schema', 'sys')
),

-- =====================================================================
-- ROUTINES (signatures only)
-- =====================================================================
routine_args AS (
    SELECT
        CONVERT(p.SPECIFIC_SCHEMA USING utf8mb4) AS schema_name,
        CONVERT(p.SPECIFIC_NAME   USING utf8mb4) AS routine_name,
        GROUP_CONCAT(
            CONCAT_WS(' ',
                NULLIF(p.PARAMETER_MODE, ''),
                p.PARAMETER_NAME,
                p.DTD_IDENTIFIER
            )
            ORDER BY p.ORDINAL_POSITION SEPARATOR ', '
        ) AS args
    FROM information_schema.PARAMETERS p
    WHERE p.ORDINAL_POSITION > 0
      AND p.SPECIFIC_SCHEMA LIKE @schema_filter
      AND p.SPECIFIC_SCHEMA NOT IN ('mysql', 'information_schema',
                                     'performance_schema', 'sys')
    GROUP BY p.SPECIFIC_SCHEMA, p.SPECIFIC_NAME
),
routines_json AS (
    SELECT CAST(CONCAT('[', GROUP_CONCAT(
        JSON_OBJECT(
            'schema',     CONVERT(r.ROUTINE_SCHEMA USING utf8mb4),
            'name',       CONVERT(r.ROUTINE_NAME   USING utf8mb4),
            'kind',       LOWER(r.ROUTINE_TYPE),
            'language',   LOWER(COALESCE(r.ROUTINE_BODY, 'sql')),
            'returns',    CASE
                              WHEN r.ROUTINE_TYPE = 'FUNCTION'
                                THEN r.DTD_IDENTIFIER
                          END,
            'arguments',  COALESCE(ra.args, ''),
            'is_trigger', FALSE
        )
        ORDER BY r.ROUTINE_SCHEMA, r.ROUTINE_NAME SEPARATOR ','
    ), ']') AS JSON) AS payload
    FROM information_schema.ROUTINES r
    LEFT JOIN routine_args ra
      ON ra.schema_name  = CONVERT(r.ROUTINE_SCHEMA USING utf8mb4)
     AND ra.routine_name = CONVERT(r.ROUTINE_NAME   USING utf8mb4)
    WHERE r.ROUTINE_SCHEMA LIKE @schema_filter
      AND r.ROUTINE_SCHEMA NOT IN ('mysql', 'information_schema',
                                    'performance_schema', 'sys')
),

-- =====================================================================
-- METADATA
-- =====================================================================
meta AS (
    SELECT JSON_OBJECT(
        'tool_name',      'sql-x-ray',
        'engine',         'mysql',
        'engine_version', VERSION(),
        'database',       DATABASE(),
        'generated_at',   DATE_FORMAT(UTC_TIMESTAMP(),
                                      '%Y-%m-%dT%H:%i:%sZ'),
        'schema_filter',  @schema_filter,
        'schemas',        (
            SELECT CAST(CONCAT('[', GROUP_CONCAT(
                JSON_QUOTE(CONVERT(s.SCHEMA_NAME USING utf8mb4))
                ORDER BY s.SCHEMA_NAME SEPARATOR ','
            ), ']') AS JSON)
            FROM information_schema.SCHEMATA s
            WHERE s.SCHEMA_NAME LIKE @schema_filter
              AND s.SCHEMA_NAME NOT IN ('mysql', 'information_schema',
                                         'performance_schema', 'sys')
        ),
        'privacy_note',
            CONCAT(
                'This document contains only structural metadata. ',
                'It deliberately excludes: default value literals, ',
                'check constraint expressions, view and routine bodies, ',
                'ENUM/SET value labels, comments, and all row data. ',
                'Existence is recorded via counts (e.g. check_constraint_count); ',
                'contents are not. Expression indexes are marked as ',
                '"<expression>" in column lists.'
            )
    ) AS payload
)

-- =====================================================================
-- FINAL ASSEMBLY
-- =====================================================================
SELECT
    CASE WHEN @pretty_print
         THEN JSON_PRETTY(result)
         ELSE CAST(result AS CHAR)
    END AS schema_dump
FROM (
    SELECT JSON_OBJECT(
        'metadata',  (SELECT payload FROM meta),
        'tables',    COALESCE((SELECT payload FROM tables_json),   JSON_ARRAY()),
        'views',     COALESCE((SELECT payload FROM views_json),    JSON_ARRAY()),
        'routines',  COALESCE((SELECT payload FROM routines_json), JSON_ARRAY()),
        'sequences', JSON_ARRAY(),
        'types',     JSON_ARRAY()
    ) AS result
) final;
