-- =====================================================================
-- sql-x-ray for MariaDB 10.5+
-- =====================================================================
-- Generates a privacy-safe structural JSON dump of a database schema,
-- suitable as priming context for an LLM.
--
-- Repository: https://github.com/hihipy/sql-x-ray
-- License:    CC BY-NC-SA 4.0
--
-- Target: MariaDB 10.5+
--   Tested on MariaDB 10.x and 11.8 with the OpenFlights sample
--   database. MySQL is NOT supported; while MariaDB started as a
--   MySQL fork, the catalog views diverge meaningfully (sequences,
--   PACKAGE routines, system-versioned tables). See mysql-xray.sql
--   for the MySQL equivalent.
--
-- Catalog source: information_schema.* views.
--   MariaDB's information_schema is the standard catalog. We use
--   CONVERT(... USING utf8mb4) on cross-table name comparisons to
--   avoid "Illegal mix of collations" errors that can occur when
--   I_S views have inconsistent collations.
--
-- Usage:
--   1. Connect to MariaDB. The script targets the current database
--      via DATABASE().
--   2. Run this script. The result is a single column schema_dump
--      containing one row of JSON.
--
-- What's captured:
--   tables     base tables with kind, partition flag, row count and
--              size estimate, primary key, foreign keys, unique
--              constraints, check_constraint_count, indexes,
--              trigger_count, and columns
--   views      schema-qualified name and column list with types
--   routines   user-defined functions and procedures (name, kind,
--              language, arguments, return type), no bodies
--   sequences  user-defined sequences (name only, no start,
--              increment, or maxvalue)
--   packages   empty array (PACKAGE routines exist in MariaDB
--              Enterprise but are not surfaced in this script)
--
-- What's deliberately excluded for privacy:
--   - column default value literals (presence flag only)
--   - check constraint expressions (count only)
--   - view bodies, routine bodies, trigger bodies
--   - ENUM and SET value labels (type marked as "enum"/"set" only)
--   - table and column comments (free text, could be anything)
--   - sequence numeric attributes
--   - data row contents
--
-- MariaDB-specific notes:
--   - Sequences (10.3+) appear in information_schema.TABLES with
--     TABLE_TYPE = 'SEQUENCE'.
--   - We use JSON_DETAILED rather than JSON_PRETTY; the latter
--     was added later and has narrower version coverage.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Configuration. Edit these three lines, then run.
--   @schema_filter   '%' for every non-system database, an exact name,
--                    or a LIKE pattern like 'app_%'
--   @include_stats   TRUE to include row count estimates and on-disk
--                    sizes, FALSE to skip
--   @pretty_print    TRUE to format JSON with line breaks via
--                    JSON_DETAILED (MariaDB native)
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
-- COLUMNS
-- =====================================================================
cols AS (
    SELECT
        CONVERT(c.TABLE_SCHEMA USING utf8mb4) AS schema_name,
        CONVERT(c.TABLE_NAME   USING utf8mb4) AS table_name,
        JSON_EXTRACT(CONCAT('[', GROUP_CONCAT(
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
                'is_generated', c.EXTRA LIKE '%GENERATED%'
                                   OR c.EXTRA LIKE '%PERSISTENT%'
                                   OR c.EXTRA LIKE '%VIRTUAL%',
                'has_default',  c.COLUMN_DEFAULT IS NOT NULL
                                   OR c.EXTRA LIKE '%DEFAULT_GENERATED%'
            )
            ORDER BY c.ORDINAL_POSITION SEPARATOR ','
        ), ']'), '$') AS columns
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
        JSON_OBJECT('columns', JSON_EXTRACT(CONCAT('[', GROUP_CONCAT(
            JSON_QUOTE(k.COLUMN_NAME)
            ORDER BY k.ORDINAL_POSITION SEPARATOR ','
        ), ']'), '$')) AS primary_key
    FROM information_schema.KEY_COLUMN_USAGE k
    WHERE k.CONSTRAINT_NAME = 'PRIMARY'
      AND k.TABLE_SCHEMA LIKE @schema_filter
      AND k.TABLE_SCHEMA NOT IN ('mysql', 'information_schema',
                                  'performance_schema', 'sys')
    GROUP BY k.TABLE_SCHEMA, k.TABLE_NAME
),

-- =====================================================================
-- FOREIGN KEYS
-- =====================================================================
fk_constraints AS (
    SELECT
        CONVERT(k.TABLE_SCHEMA             USING utf8mb4) AS schema_name,
        CONVERT(k.TABLE_NAME               USING utf8mb4) AS table_name,
        CONVERT(k.CONSTRAINT_NAME          USING utf8mb4) AS constraint_name,
        CONVERT(k.REFERENCED_TABLE_SCHEMA  USING utf8mb4) AS referenced_schema,
        CONVERT(k.REFERENCED_TABLE_NAME    USING utf8mb4) AS referenced_table,
        JSON_EXTRACT(CONCAT('[', GROUP_CONCAT(
            JSON_QUOTE(k.COLUMN_NAME)
            ORDER BY k.ORDINAL_POSITION SEPARATOR ','
        ), ']'), '$') AS from_columns,
        JSON_EXTRACT(CONCAT('[', GROUP_CONCAT(
            JSON_QUOTE(k.REFERENCED_COLUMN_NAME)
            ORDER BY k.ORDINAL_POSITION SEPARATOR ','
        ), ']'), '$') AS to_columns
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
        JSON_EXTRACT(CONCAT('[', GROUP_CONCAT(
            JSON_OBJECT(
                'from_columns', fc.from_columns,
                'to_schema',    fc.referenced_schema,
                'to_table',     fc.referenced_table,
                'to_columns',   fc.to_columns,
                'on_update',    rc.UPDATE_RULE,
                'on_delete',    rc.DELETE_RULE
            )
            ORDER BY fc.constraint_name SEPARATOR ','
        ), ']'), '$') AS foreign_keys
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
        JSON_EXTRACT(CONCAT('[', GROUP_CONCAT(
            JSON_QUOTE(kcu.COLUMN_NAME)
            ORDER BY kcu.ORDINAL_POSITION SEPARATOR ','
        ), ']'), '$') AS columns
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
        JSON_EXTRACT(CONCAT('[', GROUP_CONCAT(
            JSON_OBJECT('columns', columns)
            ORDER BY constraint_name SEPARATOR ','
        ), ']'), '$') AS unique_constraints
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
-- =====================================================================
index_columns AS (
    SELECT
        CONVERT(s.TABLE_SCHEMA USING utf8mb4) AS schema_name,
        CONVERT(s.TABLE_NAME   USING utf8mb4) AS table_name,
        CONVERT(s.INDEX_NAME   USING utf8mb4) AS index_name,
        MAX(s.NON_UNIQUE) AS non_unique,
        MAX(s.INDEX_TYPE) AS index_type,
        JSON_EXTRACT(CONCAT('[', GROUP_CONCAT(
            JSON_QUOTE(COALESCE(s.COLUMN_NAME, '<expression>'))
            ORDER BY s.SEQ_IN_INDEX SEPARATOR ','
        ), ']'), '$') AS columns
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
        JSON_EXTRACT(CONCAT('[', GROUP_CONCAT(
            JSON_OBJECT(
                'name',    index_name,
                'method',  index_type,
                'unique',  non_unique = 0,
                'columns', columns
            )
            ORDER BY index_name SEPARATOR ','
        ), ']'), '$') AS indexes
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
-- PARTITIONED TABLES
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
-- TABLE METADATA
--
-- Stats note: TABLE_ROWS and DATA_LENGTH + INDEX_LENGTH from
-- information_schema.TABLES are approximate, and how approximate
-- depends on the engine. InnoDB caches counts and refreshes them
-- via ANALYZE TABLE; counts can be off by 20-50% on busy tables.
-- Aria and MyISAM keep exact row counts. MyRocks, ColumnStore, and
-- some other engines may report 0 or stale values until ANALYZE
-- TABLE is run. We label these fields *_estimate to set expectations.
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
-- TABLES
-- =====================================================================
tables_json AS (
    SELECT JSON_EXTRACT(CONCAT('[', GROUP_CONCAT(
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
    ), ']'), '$') AS payload
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
        JSON_EXTRACT(CONCAT('[', GROUP_CONCAT(
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
        ), ']'), '$') AS columns
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
    SELECT JSON_EXTRACT(CONCAT('[', GROUP_CONCAT(
        JSON_OBJECT(
            'schema',  CONVERT(v.TABLE_SCHEMA USING utf8mb4),
            'name',    CONVERT(v.TABLE_NAME   USING utf8mb4),
            'kind',    'view',
            'columns', vc.columns
        )
        ORDER BY v.TABLE_SCHEMA, v.TABLE_NAME SEPARATOR ','
    ), ']'), '$') AS payload
    FROM information_schema.VIEWS v
    LEFT JOIN view_cols vc
      ON vc.schema_name = CONVERT(v.TABLE_SCHEMA USING utf8mb4)
     AND vc.view_name   = CONVERT(v.TABLE_NAME   USING utf8mb4)
    WHERE v.TABLE_SCHEMA LIKE @schema_filter
      AND v.TABLE_SCHEMA NOT IN ('mysql', 'information_schema',
                                  'performance_schema', 'sys')
),

-- =====================================================================
-- ROUTINES (includes PACKAGEs on MariaDB 10.3+)
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
    SELECT JSON_EXTRACT(CONCAT('[', GROUP_CONCAT(
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
    ), ']'), '$') AS payload
    FROM information_schema.ROUTINES r
    LEFT JOIN routine_args ra
      ON ra.schema_name  = CONVERT(r.ROUTINE_SCHEMA USING utf8mb4)
     AND ra.routine_name = CONVERT(r.ROUTINE_NAME   USING utf8mb4)
    WHERE r.ROUTINE_SCHEMA LIKE @schema_filter
      AND r.ROUTINE_SCHEMA NOT IN ('mysql', 'information_schema',
                                    'performance_schema', 'sys')
),

-- =====================================================================
-- SEQUENCES (MariaDB 10.3+)
-- Existence only. Start, increment, min, max, current value all
-- excluded by privacy policy.
-- =====================================================================
sequences_json AS (
    SELECT JSON_EXTRACT(CONCAT('[', GROUP_CONCAT(
        JSON_OBJECT(
            'schema', CONVERT(t.TABLE_SCHEMA USING utf8mb4),
            'name',   CONVERT(t.TABLE_NAME   USING utf8mb4),
            'kind',   'sequence'
        )
        ORDER BY t.TABLE_SCHEMA, t.TABLE_NAME SEPARATOR ','
    ), ']'), '$') AS payload
    FROM information_schema.TABLES t
    WHERE t.TABLE_TYPE = 'SEQUENCE'
      AND t.TABLE_SCHEMA LIKE @schema_filter
      AND t.TABLE_SCHEMA NOT IN ('mysql', 'information_schema',
                                  'performance_schema', 'sys')
),

-- =====================================================================
-- METADATA
-- engine_version strips the "-MariaDB-..." build suffix so VERSION()
-- like "10.11.6-MariaDB-1:10.11.6+maria~ubu2204" becomes "10.11.6".
-- =====================================================================
meta AS (
    SELECT JSON_OBJECT(
        'tool_name',      'sql-x-ray',
        'engine',         'mariadb',
        'engine_version', SUBSTRING_INDEX(VERSION(), '-', 1),
        'database',       DATABASE(),
        'generated_at',   DATE_FORMAT(UTC_TIMESTAMP(),
                                      '%Y-%m-%dT%H:%i:%sZ'),
        'schema_filter',  @schema_filter,
        'schemas',        (
            SELECT JSON_EXTRACT(CONCAT('[', GROUP_CONCAT(
                JSON_QUOTE(CONVERT(s.SCHEMA_NAME USING utf8mb4))
                ORDER BY s.SCHEMA_NAME SEPARATOR ','
            ), ']'), '$')
            FROM information_schema.SCHEMATA s
            WHERE s.SCHEMA_NAME LIKE @schema_filter
              AND s.SCHEMA_NAME NOT IN ('mysql', 'information_schema',
                                         'performance_schema', 'sys')
        ),
        'object_counts',  JSON_OBJECT(
            'tables',    COALESCE(JSON_LENGTH((SELECT payload FROM tables_json)),    0),
            'views',     COALESCE(JSON_LENGTH((SELECT payload FROM views_json)),     0),
            'routines',  COALESCE(JSON_LENGTH((SELECT payload FROM routines_json)),  0)
        ),
        'privacy_note',
            CONCAT(
                'This document contains only structural metadata. ',
                'It deliberately excludes: default value literals, ',
                'check constraint expressions, view and routine bodies, ',
                'ENUM/SET value labels, comments, sequence start and ',
                'increment values, and all row data. Existence is ',
                'recorded via counts (e.g. check_constraint_count); ',
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
         THEN JSON_DETAILED(result)
         ELSE CAST(result AS CHAR)
    END AS schema_dump
FROM (
    SELECT JSON_OBJECT(
        'metadata',  (SELECT payload FROM meta),
        'tables',    COALESCE((SELECT payload FROM tables_json),    JSON_ARRAY()),
        'views',     COALESCE((SELECT payload FROM views_json),     JSON_ARRAY()),
        'routines',  COALESCE((SELECT payload FROM routines_json),  JSON_ARRAY()),
        'sequences', COALESCE((SELECT payload FROM sequences_json), JSON_ARRAY()),
        'types',     JSON_ARRAY()
    ) AS result
) final;
