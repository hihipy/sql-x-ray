-- =====================================================================
-- sql-x-ray for SQL Server 2022+
-- =====================================================================
-- Generates a privacy-safe structural JSON dump of a database schema,
-- suitable as priming context for an LLM.
--
-- Repository: https://github.com/hihipy/sql-x-ray
-- License:    CC BY-NC-SA 4.0
--
-- Target: SQL Server 2022+
--   Relies on three features:
--     - JSON_OBJECT (scalar): added in SQL Server 2022
--     - STRING_AGG with WITHIN GROUP (ORDER BY): added in 2017
--     - JSON_QUERY: added in 2016
--   Note: JSON_ARRAYAGG and JSON_OBJECTAGG are NOT in standalone
--   SQL Server 2022 (only Azure SQL Database, Fabric, and the
--   upcoming SQL Server 2025). This script therefore builds JSON
--   arrays via STRING_AGG over JSON_OBJECT, then wraps the result
--   in JSON_QUERY so it nests correctly inside JSON_OBJECT rather
--   than being escaped as a string.
--
-- Catalog source: sys.* views (not INFORMATION_SCHEMA).
--   sys.* exposes is_identity, is_computed, default_object_id,
--   index types, and other SQL-Server-specific metadata that
--   INFORMATION_SCHEMA omits or returns inconsistently. This
--   parallels how postgres-xray uses pg_catalog rather than
--   information_schema.
--
-- Usage:
--   1. Switch to the target database first:  USE my_database;
--   2. Run this script. The result is a single column schema_dump
--      containing one row of JSON.
--
-- What's captured:
--   tables     base tables with kind, partition flag, row count and
--              size estimate, primary key, foreign keys, unique
--              constraints, check_constraint_count, indexes,
--              trigger_count, and columns
--   views      schema-qualified name and column list with types
--   routines   user-defined functions and stored procedures (name,
--              kind, language, arguments, return type), no bodies
--   sequences  user-defined sequences (schema and name), no start,
--              increment, or current value
--   packages   empty array (SQL Server has no package concept)
--
-- What's deliberately excluded for privacy:
--   - column default value literals (presence flag only)
--   - check constraint expressions (count only)
--   - view bodies, routine bodies, trigger bodies
--   - table and column descriptions (free text, could be anything)
--   - sequence numeric attributes
--   - data row contents
--
-- SQL Server-specific notes:
--   - We avoid DECLARE/SET variables so the script runs cleanly in
--     batch-splitting environments (like sqlize.online).
--   - Row count and size come from sys.dm_db_partition_stats.
-- =====================================================================

WITH

-- =====================================================================
-- COLUMNS
--
-- data_type is rendered to match the way columns are typically
-- declared in DDL (e.g. 'nvarchar(50)', 'decimal(10,2)',
-- 'datetime2(7)'). nvarchar and nchar max_length is stored in bytes,
-- so we divide by 2 to get character count. varchar(max) is
-- represented as 'varchar(max)'.
-- =====================================================================
cols AS (
    SELECT
        SCHEMA_NAME(t.schema_id) AS schema_name,
        t.name                   AS table_name,
        N'[' + STRING_AGG(
            CAST(
                JSON_OBJECT(
                    'name':         c.name,
                    'position':     c.column_id,
                    'data_type':    CASE
                        WHEN TYPE_NAME(c.user_type_id) IN (N'decimal', N'numeric')
                            THEN TYPE_NAME(c.user_type_id) + N'('
                                 + CAST(c.precision AS NVARCHAR(10)) + N','
                                 + CAST(c.scale     AS NVARCHAR(10)) + N')'
                        WHEN TYPE_NAME(c.user_type_id) IN (N'varchar', N'char', N'varbinary', N'binary')
                            THEN TYPE_NAME(c.user_type_id) + N'('
                                 + CASE WHEN c.max_length = -1
                                        THEN N'max'
                                        ELSE CAST(c.max_length AS NVARCHAR(10))
                                   END + N')'
                        WHEN TYPE_NAME(c.user_type_id) IN (N'nvarchar', N'nchar')
                            THEN TYPE_NAME(c.user_type_id) + N'('
                                 + CASE WHEN c.max_length = -1
                                        THEN N'max'
                                        ELSE CAST(c.max_length / 2 AS NVARCHAR(10))
                                   END + N')'
                        WHEN TYPE_NAME(c.user_type_id) IN (N'datetime2', N'time', N'datetimeoffset')
                            THEN TYPE_NAME(c.user_type_id) + N'('
                                 + CAST(c.scale AS NVARCHAR(10)) + N')'
                        WHEN TYPE_NAME(c.user_type_id) = N'float'
                            THEN TYPE_NAME(c.user_type_id) + N'('
                                 + CAST(c.precision AS NVARCHAR(10)) + N')'
                        ELSE TYPE_NAME(c.user_type_id)
                    END,
                    'nullable':     CAST(c.is_nullable AS BIT),
                    'is_identity':  CAST(c.is_identity AS BIT),
                    'is_generated': CAST(c.is_computed AS BIT),
                    'has_default':  CAST(CASE WHEN c.default_object_id <> 0
                                              THEN 1 ELSE 0 END AS BIT)
                    NULL ON NULL
                ) AS NVARCHAR(MAX)
            ),
            N','
        ) WITHIN GROUP (ORDER BY c.column_id) + N']' AS columns
    FROM sys.tables  t
    JOIN sys.columns c ON c.object_id = t.object_id
    WHERE t.is_ms_shipped = 0
      AND SCHEMA_NAME(t.schema_id) LIKE N'%'
      AND SCHEMA_NAME(t.schema_id) NOT IN (
          N'sys', N'INFORMATION_SCHEMA', N'guest',
          N'db_owner', N'db_accessadmin', N'db_securityadmin',
          N'db_ddladmin', N'db_backupoperator', N'db_datareader',
          N'db_datawriter', N'db_denydatareader', N'db_denydatawriter'
      )
    GROUP BY t.schema_id, t.name
),

-- =====================================================================
-- PRIMARY KEYS
--
-- Column names are emitted as a JSON array of strings; we quote and
-- escape via STRING_ESCAPE so identifiers containing quotes, slashes,
-- or control characters round-trip correctly.
-- =====================================================================
pks AS (
    SELECT
        SCHEMA_NAME(t.schema_id) AS schema_name,
        t.name                   AS table_name,
        N'{"columns":[' + STRING_AGG(
            CONCAT(N'"', STRING_ESCAPE(c.name, 'json'), N'"'),
            N','
        ) WITHIN GROUP (ORDER BY ic.key_ordinal) + N']}' AS primary_key
    FROM sys.tables        t
    JOIN sys.indexes       i  ON i.object_id  = t.object_id
                              AND i.is_primary_key = 1
    JOIN sys.index_columns ic ON ic.object_id = i.object_id
                              AND ic.index_id = i.index_id
    JOIN sys.columns       c  ON c.object_id  = ic.object_id
                              AND c.column_id = ic.column_id
    WHERE t.is_ms_shipped = 0
      AND SCHEMA_NAME(t.schema_id) LIKE N'%'
      AND SCHEMA_NAME(t.schema_id) NOT IN (
          N'sys', N'INFORMATION_SCHEMA', N'guest',
          N'db_owner', N'db_accessadmin', N'db_securityadmin',
          N'db_ddladmin', N'db_backupoperator', N'db_datareader',
          N'db_datawriter', N'db_denydatareader', N'db_denydatawriter'
      )
    GROUP BY t.schema_id, t.name
),

-- =====================================================================
-- FOREIGN KEYS
--
-- Built in two stages: first a per-constraint row with column arrays
-- assembled from scalar subqueries, then aggregated into one JSON
-- array per table.
-- =====================================================================
fk_constraints AS (
    SELECT
        SCHEMA_NAME(t.schema_id)  AS schema_name,
        t.name                    AS table_name,
        fk.name                   AS constraint_name,
        SCHEMA_NAME(rt.schema_id) AS referenced_schema,
        rt.name                   AS referenced_table,
        fk.update_referential_action_desc AS on_update,
        fk.delete_referential_action_desc AS on_delete,
        (
            SELECT N'[' + STRING_AGG(
                CONCAT(N'"', STRING_ESCAPE(pc.name, 'json'), N'"'),
                N','
            ) WITHIN GROUP (ORDER BY fkc.constraint_column_id) + N']'
            FROM sys.foreign_key_columns fkc
            JOIN sys.columns pc
              ON pc.object_id = fkc.parent_object_id
             AND pc.column_id = fkc.parent_column_id
            WHERE fkc.constraint_object_id = fk.object_id
        ) AS from_columns,
        (
            SELECT N'[' + STRING_AGG(
                CONCAT(N'"', STRING_ESCAPE(rc.name, 'json'), N'"'),
                N','
            ) WITHIN GROUP (ORDER BY fkc.constraint_column_id) + N']'
            FROM sys.foreign_key_columns fkc
            JOIN sys.columns rc
              ON rc.object_id = fkc.referenced_object_id
             AND rc.column_id = fkc.referenced_column_id
            WHERE fkc.constraint_object_id = fk.object_id
        ) AS to_columns
    FROM sys.foreign_keys fk
    JOIN sys.tables       t  ON t.object_id  = fk.parent_object_id
    JOIN sys.tables       rt ON rt.object_id = fk.referenced_object_id
    WHERE t.is_ms_shipped = 0
      AND SCHEMA_NAME(t.schema_id) LIKE N'%'
      AND SCHEMA_NAME(t.schema_id) NOT IN (
          N'sys', N'INFORMATION_SCHEMA', N'guest',
          N'db_owner', N'db_accessadmin', N'db_securityadmin',
          N'db_ddladmin', N'db_backupoperator', N'db_datareader',
          N'db_datawriter', N'db_denydatareader', N'db_denydatawriter'
      )
),
fks AS (
    SELECT
        fc.schema_name,
        fc.table_name,
        N'[' + STRING_AGG(
            CAST(
                JSON_OBJECT(
                    'from_columns': JSON_QUERY(fc.from_columns),
                    'to_schema':    fc.referenced_schema,
                    'to_table':     fc.referenced_table,
                    'to_columns':   JSON_QUERY(fc.to_columns),
                    'on_update':    fc.on_update,
                    'on_delete':    fc.on_delete
                    NULL ON NULL
                ) AS NVARCHAR(MAX)
            ),
            N','
        ) WITHIN GROUP (ORDER BY fc.constraint_name) + N']' AS foreign_keys
    FROM fk_constraints fc
    GROUP BY fc.schema_name, fc.table_name
),

-- =====================================================================
-- UNIQUE CONSTRAINTS
--
-- These are unique indexes promoted to constraint status
-- (is_unique_constraint = 1 in sys.indexes).
-- =====================================================================
uq_grouped AS (
    SELECT
        SCHEMA_NAME(t.schema_id) AS schema_name,
        t.name                   AS table_name,
        i.name                   AS constraint_name,
        N'[' + STRING_AGG(
            CONCAT(N'"', STRING_ESCAPE(c.name, 'json'), N'"'),
            N','
        ) WITHIN GROUP (ORDER BY ic.key_ordinal) + N']' AS columns
    FROM sys.tables        t
    JOIN sys.indexes       i  ON i.object_id  = t.object_id
                              AND i.is_unique_constraint = 1
    JOIN sys.index_columns ic ON ic.object_id = i.object_id
                              AND ic.index_id = i.index_id
    JOIN sys.columns       c  ON c.object_id  = ic.object_id
                              AND c.column_id = ic.column_id
    WHERE t.is_ms_shipped = 0
      AND SCHEMA_NAME(t.schema_id) LIKE N'%'
      AND SCHEMA_NAME(t.schema_id) NOT IN (
          N'sys', N'INFORMATION_SCHEMA', N'guest',
          N'db_owner', N'db_accessadmin', N'db_securityadmin',
          N'db_ddladmin', N'db_backupoperator', N'db_datareader',
          N'db_datawriter', N'db_denydatareader', N'db_denydatawriter'
      )
    GROUP BY t.schema_id, t.name, i.name
),
uqs AS (
    SELECT
        schema_name,
        table_name,
        N'[' + STRING_AGG(
            CAST(
                JSON_OBJECT('columns': JSON_QUERY(columns) NULL ON NULL)
                AS NVARCHAR(MAX)
            ),
            N','
        ) WITHIN GROUP (ORDER BY constraint_name) + N']' AS unique_constraints
    FROM uq_grouped
    GROUP BY schema_name, table_name
),

-- =====================================================================
-- CHECK CONSTRAINT COUNTS
--
-- Just a count; the predicate is excluded for privacy.
-- =====================================================================
checks AS (
    SELECT
        SCHEMA_NAME(t.schema_id) AS schema_name,
        t.name                   AS table_name,
        COUNT(*)                 AS check_constraint_count
    FROM sys.check_constraints cc
    JOIN sys.tables            t ON t.object_id = cc.parent_object_id
    WHERE t.is_ms_shipped = 0
      AND SCHEMA_NAME(t.schema_id) LIKE N'%'
      AND SCHEMA_NAME(t.schema_id) NOT IN (
          N'sys', N'INFORMATION_SCHEMA', N'guest',
          N'db_owner', N'db_accessadmin', N'db_securityadmin',
          N'db_ddladmin', N'db_backupoperator', N'db_datareader',
          N'db_datawriter', N'db_denydatareader', N'db_denydatawriter'
      )
    GROUP BY t.schema_id, t.name
),

-- =====================================================================
-- INDEXES (excludes PK-backing and unique-backing indexes)
--
-- type_desc values seen here: NONCLUSTERED, CLUSTERED,
-- NONCLUSTERED COLUMNSTORE, CLUSTERED COLUMNSTORE, XML, SPATIAL.
-- HEAP entries (i.type = 0) are excluded because they represent
-- "no index" rather than a real index object.
-- Included columns (ic.is_included_column = 1) are excluded from
-- the key column list since they aren't part of the index sort key.
-- =====================================================================
index_columns AS (
    SELECT
        SCHEMA_NAME(t.schema_id) AS schema_name,
        t.name                   AS table_name,
        i.name                   AS index_name,
        i.is_unique              AS is_unique,
        i.type_desc              AS index_type,
        N'[' + STRING_AGG(
            CONCAT(N'"', STRING_ESCAPE(c.name, 'json'), N'"'),
            N','
        ) WITHIN GROUP (ORDER BY ic.key_ordinal) + N']' AS columns
    FROM sys.tables        t
    JOIN sys.indexes       i  ON i.object_id  = t.object_id
    JOIN sys.index_columns ic ON ic.object_id = i.object_id
                              AND ic.index_id = i.index_id
    JOIN sys.columns       c  ON c.object_id  = ic.object_id
                              AND c.column_id = ic.column_id
    WHERE t.is_ms_shipped = 0
      AND SCHEMA_NAME(t.schema_id) LIKE N'%'
      AND SCHEMA_NAME(t.schema_id) NOT IN (
          N'sys', N'INFORMATION_SCHEMA', N'guest',
          N'db_owner', N'db_accessadmin', N'db_securityadmin',
          N'db_ddladmin', N'db_backupoperator', N'db_datareader',
          N'db_datawriter', N'db_denydatareader', N'db_denydatawriter'
      )
      AND i.is_primary_key       = 0
      AND i.is_unique_constraint = 0
      AND i.type > 0
      AND ic.is_included_column  = 0
    GROUP BY t.schema_id, t.name, i.name, i.is_unique, i.type_desc
),
idx AS (
    SELECT
        schema_name,
        table_name,
        N'[' + STRING_AGG(
            CAST(
                JSON_OBJECT(
                    'name':    index_name,
                    'method':  index_type,
                    'unique':  CAST(is_unique AS BIT),
                    'columns': JSON_QUERY(columns)
                    NULL ON NULL
                ) AS NVARCHAR(MAX)
            ),
            N','
        ) WITHIN GROUP (ORDER BY index_name) + N']' AS indexes
    FROM index_columns
    GROUP BY schema_name, table_name
),

-- =====================================================================
-- TRIGGER COUNTS
-- =====================================================================
trgs AS (
    SELECT
        SCHEMA_NAME(t.schema_id) AS schema_name,
        t.name                   AS table_name,
        COUNT(*)                 AS trigger_count
    FROM sys.triggers tr
    JOIN sys.tables   t ON t.object_id = tr.parent_id
    WHERE tr.is_ms_shipped = 0
      AND t.is_ms_shipped  = 0
      AND SCHEMA_NAME(t.schema_id) LIKE N'%'
      AND SCHEMA_NAME(t.schema_id) NOT IN (
          N'sys', N'INFORMATION_SCHEMA', N'guest',
          N'db_owner', N'db_accessadmin', N'db_securityadmin',
          N'db_ddladmin', N'db_backupoperator', N'db_datareader',
          N'db_datawriter', N'db_denydatareader', N'db_denydatawriter'
      )
    GROUP BY t.schema_id, t.name
),

-- =====================================================================
-- PARTITIONED TABLES
--
-- A table is partitioned if its heap or clustered index has more
-- than one partition. Non-partitioned tables don't appear here.
-- =====================================================================
partitioned AS (
    SELECT DISTINCT
        SCHEMA_NAME(t.schema_id) AS schema_name,
        t.name                   AS table_name
    FROM sys.tables     t
    JOIN sys.partitions p ON p.object_id = t.object_id
    WHERE p.index_id IN (0, 1)
      AND p.partition_number > 1
),

-- =====================================================================
-- TABLE METADATA
--
-- Stats note: row counts and used page bytes come from
-- sys.dm_db_partition_stats, which reflects the most recent
-- statistics maintained by the engine. They can lag actual row
-- counts on busy tables until ANALYZE TABLE or auto-stats refresh.
-- We label the fields *_estimate to set expectations.
--
-- Pages are 8 KiB. We sum used_page_count across all indexes for
-- size, and rows across only heap/clustered (index_id IN (0, 1))
-- for row count to avoid double counting.
-- =====================================================================
table_stats AS (
    SELECT
        object_id,
        SUM(CASE WHEN index_id IN (0, 1) THEN row_count ELSE 0 END) AS row_count,
        SUM(used_page_count) * 8192                            AS total_size_bytes
    FROM sys.dm_db_partition_stats
    GROUP BY object_id
),
tbl_meta AS (
    SELECT
        SCHEMA_NAME(t.schema_id) AS schema_name,
        t.name                   AS table_name,
        N'table'                 AS kind,
        CASE WHEN pt.table_name IS NOT NULL THEN CAST(1 AS BIT) END AS is_partitioned,
        ts.row_count                                   AS row_count_estimate,
        ts.total_size_bytes                             AS total_size_bytes
    FROM sys.tables      t
    LEFT JOIN partitioned pt
           ON pt.schema_name = SCHEMA_NAME(t.schema_id)
          AND pt.table_name  = t.name
    LEFT JOIN table_stats ts
           ON ts.object_id   = t.object_id
    WHERE t.is_ms_shipped = 0
      AND SCHEMA_NAME(t.schema_id) LIKE N'%'
      AND SCHEMA_NAME(t.schema_id) NOT IN (
          N'sys', N'INFORMATION_SCHEMA', N'guest',
          N'db_owner', N'db_accessadmin', N'db_securityadmin',
          N'db_ddladmin', N'db_backupoperator', N'db_datareader',
          N'db_datawriter', N'db_denydatareader', N'db_denydatawriter'
      )
),

-- =====================================================================
-- TABLES
-- =====================================================================
tables_json AS (
    SELECT N'[' + STRING_AGG(
        CAST(
            JSON_OBJECT(
                'schema':                 tm.schema_name,
                'name':                   tm.table_name,
                'kind':                   tm.kind,
                'is_partitioned':         tm.is_partitioned,
                'row_count_estimate':     tm.row_count_estimate,
                'total_size_bytes':       tm.total_size_bytes,
                'primary_key':            JSON_QUERY(pks.primary_key),
                'foreign_keys':           JSON_QUERY(fks.foreign_keys),
                'unique_constraints':     JSON_QUERY(uqs.unique_constraints),
                'check_constraint_count': COALESCE(checks.check_constraint_count, 0),
                'indexes':                JSON_QUERY(idx.indexes),
                'trigger_count':          COALESCE(trgs.trigger_count, 0),
                'columns':                JSON_QUERY(cols.columns)
                NULL ON NULL
            ) AS NVARCHAR(MAX)
        ),
        N','
    ) WITHIN GROUP (ORDER BY tm.schema_name, tm.table_name) + N']' AS payload
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
        SCHEMA_NAME(v.schema_id) AS schema_name,
        v.name                   AS view_name,
        N'[' + STRING_AGG(
            CAST(
                JSON_OBJECT(
                    'name':      c.name,
                    'position':  c.column_id,
                    'data_type': CASE
                        WHEN TYPE_NAME(c.user_type_id) IN (N'decimal', N'numeric')
                            THEN TYPE_NAME(c.user_type_id) + N'('
                                 + CAST(c.precision AS NVARCHAR(10)) + N','
                                 + CAST(c.scale     AS NVARCHAR(10)) + N')'
                        WHEN TYPE_NAME(c.user_type_id) IN (N'varchar', N'char', N'varbinary', N'binary')
                            THEN TYPE_NAME(c.user_type_id) + N'('
                                 + CASE WHEN c.max_length = -1
                                        THEN N'max'
                                        ELSE CAST(c.max_length AS NVARCHAR(10))
                                   END + N')'
                        WHEN TYPE_NAME(c.user_type_id) IN (N'nvarchar', N'nchar')
                            THEN TYPE_NAME(c.user_type_id) + N'('
                                 + CASE WHEN c.max_length = -1
                                        THEN N'max'
                                        ELSE CAST(c.max_length / 2 AS NVARCHAR(10))
                                   END + N')'
                        WHEN TYPE_NAME(c.user_type_id) IN (N'datetime2', N'time', N'datetimeoffset')
                            THEN TYPE_NAME(c.user_type_id) + N'('
                                 + CAST(c.scale AS NVARCHAR(10)) + N')'
                        WHEN TYPE_NAME(c.user_type_id) = N'float'
                            THEN TYPE_NAME(c.user_type_id) + N'('
                                 + CAST(c.precision AS NVARCHAR(10)) + N')'
                        ELSE TYPE_NAME(c.user_type_id)
                    END,
                    'nullable':  CAST(c.is_nullable AS BIT)
                    NULL ON NULL
                ) AS NVARCHAR(MAX)
            ),
            N','
        ) WITHIN GROUP (ORDER BY c.column_id) + N']' AS columns
    FROM sys.views   v
    JOIN sys.columns c ON c.object_id = v.object_id
    WHERE v.is_ms_shipped = 0
      AND SCHEMA_NAME(v.schema_id) LIKE N'%'
      AND SCHEMA_NAME(v.schema_id) NOT IN (
          N'sys', N'INFORMATION_SCHEMA', N'guest',
          N'db_owner', N'db_accessadmin', N'db_securityadmin',
          N'db_ddladmin', N'db_backupoperator', N'db_datareader',
          N'db_datawriter', N'db_denydatareader', N'db_denydatawriter'
      )
    GROUP BY v.schema_id, v.name
),
views_json AS (
    SELECT N'[' + STRING_AGG(
        CAST(
            JSON_OBJECT(
                'schema':  SCHEMA_NAME(v.schema_id),
                'name':    v.name,
                'kind':    N'view',
                'columns': JSON_QUERY(vc.columns)
                NULL ON NULL
            ) AS NVARCHAR(MAX)
        ),
        N','
    ) WITHIN GROUP (ORDER BY SCHEMA_NAME(v.schema_id), v.name) + N']' AS payload
    FROM sys.views v
    LEFT JOIN view_cols vc
           ON vc.schema_name = SCHEMA_NAME(v.schema_id)
          AND vc.view_name   = v.name
    WHERE v.is_ms_shipped = 0
      AND SCHEMA_NAME(v.schema_id) LIKE N'%'
      AND SCHEMA_NAME(v.schema_id) NOT IN (
          N'sys', N'INFORMATION_SCHEMA', N'guest',
          N'db_owner', N'db_accessadmin', N'db_securityadmin',
          N'db_ddladmin', N'db_backupoperator', N'db_datareader',
          N'db_datawriter', N'db_denydatareader', N'db_denydatawriter'
      )
),

-- =====================================================================
-- ROUTINES
--
-- SQL Server object type codes covered:
--   P  = stored procedure (SQL)
--   PC = stored procedure (CLR)
--   FN = scalar function (SQL)
--   FS = scalar function (CLR)
--   IF = inline table-valued function
--   TF = table-valued function (SQL)
--   FT = table-valued function (CLR)
--
-- For procedures, returns is null. For scalar functions, returns is
-- the return type. For table-valued functions, returns is 'table'.
-- =====================================================================
routine_args AS (
    SELECT
        SCHEMA_NAME(o.schema_id) AS schema_name,
        o.name                   AS routine_name,
        STRING_AGG(
            CONCAT(
                CASE WHEN p.is_output = 1 THEN N'OUT ' ELSE N'IN ' END,
                p.name, N' ',
                TYPE_NAME(p.user_type_id)
            ),
            N', '
        ) WITHIN GROUP (ORDER BY p.parameter_id) AS args
    FROM sys.objects    o
    JOIN sys.parameters p ON p.object_id = o.object_id
    WHERE o.is_ms_shipped = 0
      AND o.type IN (N'P', N'PC', N'FN', N'FS', N'IF', N'TF', N'FT')
      AND p.parameter_id > 0
      AND SCHEMA_NAME(o.schema_id) LIKE N'%'
      AND SCHEMA_NAME(o.schema_id) NOT IN (
          N'sys', N'INFORMATION_SCHEMA', N'guest',
          N'db_owner', N'db_accessadmin', N'db_securityadmin',
          N'db_ddladmin', N'db_backupoperator', N'db_datareader',
          N'db_datawriter', N'db_denydatareader', N'db_denydatawriter'
      )
    GROUP BY o.schema_id, o.name
),
routines_json AS (
    SELECT N'[' + STRING_AGG(
        CAST(
            JSON_OBJECT(
                'schema':     SCHEMA_NAME(o.schema_id),
                'name':       o.name,
                'kind':       CASE WHEN o.type IN (N'P', N'PC') THEN N'procedure'
                                   ELSE N'function'
                              END,
                'language':   CASE WHEN o.type IN (N'PC', N'FS', N'FT') THEN N'clr'
                                   ELSE N'sql'
                              END,
                'returns':    CASE
                                  WHEN o.type IN (N'FN', N'FS')
                                      THEN TYPE_NAME(rp.user_type_id)
                                  WHEN o.type IN (N'IF', N'TF', N'FT')
                                      THEN N'table'
                              END,
                'arguments':  COALESCE(ra.args, N''),
                'is_trigger': CAST(0 AS BIT)
                NULL ON NULL
            ) AS NVARCHAR(MAX)
        ),
        N','
    ) WITHIN GROUP (ORDER BY SCHEMA_NAME(o.schema_id), o.name) + N']' AS payload
    FROM sys.objects o
    LEFT JOIN sys.parameters rp
           ON rp.object_id    = o.object_id
          AND rp.parameter_id = 0
    LEFT JOIN routine_args ra
           ON ra.schema_name  = SCHEMA_NAME(o.schema_id)
          AND ra.routine_name = o.name
    WHERE o.is_ms_shipped = 0
      AND o.type IN (N'P', N'PC', N'FN', N'FS', N'IF', N'TF', N'FT')
      AND SCHEMA_NAME(o.schema_id) LIKE N'%'
      AND SCHEMA_NAME(o.schema_id) NOT IN (
          N'sys', N'INFORMATION_SCHEMA', N'guest',
          N'db_owner', N'db_accessadmin', N'db_securityadmin',
          N'db_ddladmin', N'db_backupoperator', N'db_datareader',
          N'db_datawriter', N'db_denydatareader', N'db_denydatawriter'
      )
),

-- =====================================================================
-- SEQUENCES
--
-- Existence and name only. start_value, increment, current_value,
-- min/max bounds, and cycle flag are deliberately excluded.
-- =====================================================================
sequences_json AS (
    SELECT N'[' + STRING_AGG(
        CAST(
            JSON_OBJECT(
                'schema': SCHEMA_NAME(s.schema_id),
                'name':   s.name,
                'kind':   N'sequence'
                NULL ON NULL
            ) AS NVARCHAR(MAX)
        ),
        N','
    ) WITHIN GROUP (ORDER BY SCHEMA_NAME(s.schema_id), s.name) + N']' AS payload
    FROM sys.sequences s
    WHERE s.is_ms_shipped = 0
      AND SCHEMA_NAME(s.schema_id) LIKE N'%'
      AND SCHEMA_NAME(s.schema_id) NOT IN (
          N'sys', N'INFORMATION_SCHEMA', N'guest',
          N'db_owner', N'db_accessadmin', N'db_securityadmin',
          N'db_ddladmin', N'db_backupoperator', N'db_datareader',
          N'db_datawriter', N'db_denydatareader', N'db_denydatawriter'
      )
),

-- =====================================================================
-- METADATA
-- =====================================================================
schemas_list AS (
    SELECT N'[' + STRING_AGG(
        CONCAT(N'"', STRING_ESCAPE(s.name, 'json'), N'"'),
        N','
    ) WITHIN GROUP (ORDER BY s.name) + N']' AS payload
    FROM sys.schemas s
    WHERE s.name LIKE N'%'
      AND s.name NOT IN (
          N'sys', N'INFORMATION_SCHEMA', N'guest',
          N'db_owner', N'db_accessadmin', N'db_securityadmin',
          N'db_ddladmin', N'db_backupoperator', N'db_datareader',
          N'db_datawriter', N'db_denydatareader', N'db_denydatawriter'
      )
),
meta AS (
    SELECT CAST(JSON_OBJECT(
        'tool_name':      N'sql-x-ray',
        'engine':         N'sqlserver',
        'engine_version': CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(128)),
        'database':       DB_NAME(),
        'generated_at':   FORMAT(SYSUTCDATETIME(), N'yyyy-MM-ddTHH:mm:ssZ'),
        'schema_filter':  N'%',
        'schemas':        JSON_QUERY((SELECT payload FROM schemas_list)),
        'privacy_note':
            N'This document contains only structural metadata. '
          + N'It deliberately excludes: default value literals, '
          + N'check constraint expressions, view and routine bodies, '
          + N'computed column expressions, index filter predicates, '
          + N'sequence start and increment values, extended properties, '
          + N'and all row data. Existence is recorded via counts '
          + N'(e.g. check_constraint_count); contents are not.'
        NULL ON NULL
    ) AS NVARCHAR(MAX)) AS payload
)

-- =====================================================================
-- FINAL ASSEMBLY
-- =====================================================================
SELECT JSON_OBJECT(
    'metadata':  JSON_QUERY((SELECT payload FROM meta)),
    'tables':    JSON_QUERY(COALESCE((SELECT payload FROM tables_json),    N'[]')),
    'views':     JSON_QUERY(COALESCE((SELECT payload FROM views_json),     N'[]')),
    'routines':  JSON_QUERY(COALESCE((SELECT payload FROM routines_json),  N'[]')),
    'sequences': JSON_QUERY(COALESCE((SELECT payload FROM sequences_json), N'[]')),
    'types':     JSON_QUERY(N'[]')
    NULL ON NULL
) AS schema_dump;
