-- =====================================================================
-- sql-x-ray for BigQuery
-- =====================================================================
-- Generates a privacy-safe structural JSON dump of a database schema,
-- suitable as priming context for an LLM.
--
-- Repository: https://github.com/hihipy/sql-x-ray
-- License:    CC BY-NC-SA 4.0
--
-- Target: BigQuery (GoogleSQL)
--   Relies on JSON_OBJECT, TO_JSON_STRING, ARRAY_AGG with ORDER BY,
--   and INFORMATION_SCHEMA views. All are generally available in
--   BigQuery; no preview features required.
--
-- Catalog source: INFORMATION_SCHEMA.* views, dataset-scoped.
--   BigQuery's INFORMATION_SCHEMA must be qualified with a dataset
--   (and optionally a project): `project.dataset.INFORMATION_SCHEMA.*`.
--   This script targets one dataset at a time. The default points at
--   the public thelook_ecommerce dataset for quick validation.
--
-- Usage:
--   1. Replace every occurrence of:
--        `bigquery-public-data.thelook_ecommerce`
--      with your own project.dataset (keep the backticks).
--      Find & Replace in your editor handles this in one step.
--   2. Run the script in the BigQuery Console, bq CLI, or any
--      BigQuery client.
--   3. The result is a single column schema_dump containing one row
--      of JSON.
--
-- What's captured:
--   tables     base tables with kind (BASE TABLE / VIEW /
--              MATERIALIZED VIEW / EXTERNAL / SNAPSHOT), partition
--              column, clustering columns, primary key, foreign
--              keys, and columns
--   views      schema-qualified name and column list with types
--   routines   user-defined functions and stored procedures (name,
--              kind, language, arguments, return type), no bodies
--   sequences  empty array (BigQuery has no sequence objects)
--   packages   empty array (BigQuery has no package concept)
--
-- What's deliberately excluded for privacy:
--   - column default value literals (presence flag only)
--   - view bodies, routine bodies
--   - table descriptions and column descriptions (free text)
--   - data row contents
--
-- BigQuery-specific notes:
--   - Primary keys and foreign keys are NOT enforced. They exist as
--     metadata that the query optimizer uses for join elimination
--     and reordering. The dump records them faithfully but readers
--     should not assume referential integrity is guaranteed.
--   - There are no traditional indexes; performance comes from
--     partitioning and clustering, which we surface as separate
--     fields (partition_column, clustering_columns).
--   - There are no CHECK constraints at the database level. The
--     check_constraint_count field is always 0.
--   - There are no triggers at the database level. The trigger_count
--     field is always 0.
--   - Routines include both stored procedures (PROCEDURE) and user-
--     defined functions (FUNCTION, including SQL and JavaScript
--     UDFs and remote functions).
-- =====================================================================

WITH

-- =====================================================================
-- COLUMNS
--
-- INFORMATION_SCHEMA.COLUMNS.data_type already contains the full
-- BigQuery type string (e.g. 'STRING', 'INT64', 'TIMESTAMP',
-- 'ARRAY<STRUCT<id INT64, name STRING>>'). We emit it as-is.
-- is_partitioning_column ('YES'/'NO') identifies the partition key.
-- clustering_ordinal_position is 1-4 for cluster columns, NULL
-- otherwise.
-- =====================================================================
cols AS (
    SELECT
        c.table_name,
        ARRAY_AGG(
            STRUCT(
                c.column_name AS name,
                c.ordinal_position AS position,
                c.data_type AS data_type,
                CASE c.is_nullable WHEN 'YES' THEN TRUE ELSE FALSE END AS nullable,
                CASE WHEN c.column_default IS NOT NULL
                       AND UPPER(c.column_default) != 'NULL'
                     THEN TRUE ELSE FALSE END AS has_default,
                CASE WHEN c.is_partitioning_column = 'YES' THEN TRUE ELSE FALSE END AS is_partition_column,
                c.clustering_ordinal_position AS clustering_position
            )
            ORDER BY c.ordinal_position
        ) AS columns
    FROM `bigquery-public-data.thelook_ecommerce.INFORMATION_SCHEMA.COLUMNS` AS c
    GROUP BY c.table_name
),

-- =====================================================================
-- PRIMARY KEYS
--
-- INFORMATION_SCHEMA.TABLE_CONSTRAINTS gives constraint metadata;
-- KEY_COLUMN_USAGE lists the columns per constraint with ordinal
-- positions. Primary key constraint names in BigQuery look like
-- '<table_name>.pk$'.
-- =====================================================================
pk_cols AS (
    SELECT
        tc.table_name,
        ARRAY_AGG(kcu.column_name ORDER BY kcu.ordinal_position) AS columns
    FROM `bigquery-public-data.thelook_ecommerce.INFORMATION_SCHEMA.TABLE_CONSTRAINTS` AS tc
    JOIN `bigquery-public-data.thelook_ecommerce.INFORMATION_SCHEMA.KEY_COLUMN_USAGE` AS kcu
      ON kcu.constraint_name = tc.constraint_name
    WHERE tc.constraint_type = 'PRIMARY KEY'
    GROUP BY tc.table_name
),

-- =====================================================================
-- FOREIGN KEYS
--
-- For each foreign key constraint, we group its source columns from
-- KEY_COLUMN_USAGE and its referenced columns from
-- CONSTRAINT_COLUMN_USAGE. BigQuery foreign keys can only point to
-- tables within the same dataset.
-- =====================================================================
fk_constraints AS (
    SELECT
        tc.constraint_name,
        tc.table_name,
        ARRAY_AGG(kcu.column_name ORDER BY kcu.ordinal_position) AS from_columns
    FROM `bigquery-public-data.thelook_ecommerce.INFORMATION_SCHEMA.TABLE_CONSTRAINTS` AS tc
    JOIN `bigquery-public-data.thelook_ecommerce.INFORMATION_SCHEMA.KEY_COLUMN_USAGE` AS kcu
      ON kcu.constraint_name = tc.constraint_name
    WHERE tc.constraint_type = 'FOREIGN KEY'
    GROUP BY tc.constraint_name, tc.table_name
),
fk_targets AS (
    SELECT
        ccu.constraint_name,
        ANY_VALUE(ccu.table_name) AS to_table,
        ARRAY_AGG(ccu.column_name) AS to_columns
    FROM `bigquery-public-data.thelook_ecommerce.INFORMATION_SCHEMA.CONSTRAINT_COLUMN_USAGE` AS ccu
    JOIN `bigquery-public-data.thelook_ecommerce.INFORMATION_SCHEMA.TABLE_CONSTRAINTS` AS tc
      ON tc.constraint_name = ccu.constraint_name
    WHERE tc.constraint_type = 'FOREIGN KEY'
    GROUP BY ccu.constraint_name
),
fks AS (
    SELECT
        fc.table_name,
        ARRAY_AGG(
            STRUCT(
                fc.from_columns AS from_columns,
                ft.to_table AS to_table,
                ft.to_columns AS to_columns
            )
            ORDER BY fc.constraint_name
        ) AS foreign_keys
    FROM fk_constraints fc
    LEFT JOIN fk_targets ft ON ft.constraint_name = fc.constraint_name
    GROUP BY fc.table_name
),

-- =====================================================================
-- TABLE METADATA
--
-- table_type values: 'BASE TABLE', 'VIEW', 'MATERIALIZED VIEW',
-- 'EXTERNAL', 'SNAPSHOT'. We map these into a lowercase 'kind' for
-- cross-engine parity.
--
-- Partitioning and clustering info comes from COLUMNS, aggregated
-- per table.
-- =====================================================================
tbl_partition AS (
    SELECT
        c.table_name,
        ANY_VALUE(
            CASE WHEN c.is_partitioning_column = 'YES'
                 THEN c.column_name END
        ) AS partition_column
    FROM `bigquery-public-data.thelook_ecommerce.INFORMATION_SCHEMA.COLUMNS` AS c
    GROUP BY c.table_name
),
tbl_clustering AS (
    SELECT
        c.table_name,
        ARRAY_AGG(c.column_name ORDER BY c.clustering_ordinal_position) AS clustering_columns
    FROM `bigquery-public-data.thelook_ecommerce.INFORMATION_SCHEMA.COLUMNS` AS c
    WHERE c.clustering_ordinal_position IS NOT NULL
    GROUP BY c.table_name
),

-- =====================================================================
-- TABLES
-- =====================================================================
tables_json AS (
    SELECT ARRAY_AGG(
        STRUCT(
            t.table_schema AS schema_name,
            t.table_name AS name,
            LOWER(REPLACE(t.table_type, ' ', '_')) AS kind,
            CASE WHEN tp.partition_column IS NOT NULL THEN TRUE ELSE FALSE END AS is_partitioned,
            tp.partition_column AS partition_column,
            tc.clustering_columns AS clustering_columns,
            STRUCT(pk.columns AS columns) AS primary_key,
            fks.foreign_keys AS foreign_keys,
            CAST([] AS ARRAY<STRUCT<columns ARRAY<STRING>>>) AS unique_constraints,
            0 AS check_constraint_count,
            CAST([] AS ARRAY<STRUCT<name STRING, method STRING, is_unique BOOL, columns ARRAY<STRING>>>) AS indexes,
            0 AS trigger_count,
            cols.columns AS columns
        )
        ORDER BY t.table_name
    ) AS payload
    FROM `bigquery-public-data.thelook_ecommerce.INFORMATION_SCHEMA.TABLES` AS t
    LEFT JOIN cols          ON cols.table_name         = t.table_name
    LEFT JOIN pk_cols pk    ON pk.table_name           = t.table_name
    LEFT JOIN fks           ON fks.table_name          = t.table_name
    LEFT JOIN tbl_partition tp ON tp.table_name        = t.table_name
    LEFT JOIN tbl_clustering tc ON tc.table_name       = t.table_name
    WHERE t.table_type = 'BASE TABLE'
),

-- =====================================================================
-- VIEWS
-- =====================================================================
view_cols AS (
    SELECT
        c.table_name AS view_name,
        ARRAY_AGG(
            STRUCT(
                c.column_name AS name,
                c.ordinal_position AS position,
                c.data_type AS data_type,
                CASE c.is_nullable WHEN 'YES' THEN TRUE ELSE FALSE END AS nullable
            )
            ORDER BY c.ordinal_position
        ) AS columns
    FROM `bigquery-public-data.thelook_ecommerce.INFORMATION_SCHEMA.COLUMNS` AS c
    JOIN `bigquery-public-data.thelook_ecommerce.INFORMATION_SCHEMA.TABLES` AS t
      ON t.table_name = c.table_name
    WHERE t.table_type IN ('VIEW', 'MATERIALIZED VIEW')
    GROUP BY c.table_name
),
views_json AS (
    SELECT ARRAY_AGG(
        STRUCT(
            t.table_schema AS schema_name,
            t.table_name AS name,
            LOWER(REPLACE(t.table_type, ' ', '_')) AS kind,
            vc.columns AS columns
        )
        ORDER BY t.table_name
    ) AS payload
    FROM `bigquery-public-data.thelook_ecommerce.INFORMATION_SCHEMA.TABLES` AS t
    LEFT JOIN view_cols vc ON vc.view_name = t.table_name
    WHERE t.table_type IN ('VIEW', 'MATERIALIZED VIEW')
),

-- =====================================================================
-- ROUTINES
--
-- INFORMATION_SCHEMA.ROUTINES lists procedures and functions.
-- ROUTINE_TYPE is 'PROCEDURE' or 'FUNCTION'. data_type is the return
-- type for functions; null for procedures.
--
-- PARAMETERS gives the arguments per routine.
-- =====================================================================
routine_args AS (
    SELECT
        p.specific_name AS routine_name,
        STRING_AGG(
            CONCAT(
                COALESCE(p.parameter_mode, 'IN'), ' ',
                COALESCE(p.parameter_name, '?'), ' ',
                COALESCE(p.data_type, '')
            ),
            ', '
            ORDER BY p.ordinal_position
        ) AS args
    FROM `bigquery-public-data.thelook_ecommerce.INFORMATION_SCHEMA.PARAMETERS` AS p
    WHERE p.ordinal_position IS NOT NULL
    GROUP BY p.specific_name
),
routines_json AS (
    SELECT ARRAY_AGG(
        STRUCT(
            r.specific_schema AS schema_name,
            r.routine_name AS name,
            LOWER(r.routine_type) AS kind,
            LOWER(COALESCE(r.external_language, r.routine_body, 'sql')) AS language,
            r.data_type AS returns,
            COALESCE(ra.args, '') AS arguments,
            FALSE AS is_trigger
        )
        ORDER BY r.routine_name
    ) AS payload
    FROM `bigquery-public-data.thelook_ecommerce.INFORMATION_SCHEMA.ROUTINES` AS r
    LEFT JOIN routine_args ra ON ra.routine_name = r.specific_name
),

-- =====================================================================
-- METADATA
-- =====================================================================
meta AS (
    SELECT STRUCT(
        'sql-x-ray' AS tool_name,
        'bigquery' AS engine,
        'GoogleSQL' AS engine_version,
        'bigquery-public-data.thelook_ecommerce' AS database,
        FORMAT_TIMESTAMP('%Y-%m-%dT%H:%M:%SZ', CURRENT_TIMESTAMP()) AS generated_at,
        'thelook_ecommerce' AS schema_filter,
        ['thelook_ecommerce'] AS schemas,
        STRUCT(
            (SELECT COUNT(*) FROM `bigquery-public-data.thelook_ecommerce.INFORMATION_SCHEMA.TABLES`
             WHERE table_type = 'BASE TABLE') AS tables,
            (SELECT COUNT(*) FROM `bigquery-public-data.thelook_ecommerce.INFORMATION_SCHEMA.TABLES`
             WHERE table_type IN ('VIEW', 'MATERIALIZED VIEW')) AS views,
            (SELECT COUNT(*) FROM `bigquery-public-data.thelook_ecommerce.INFORMATION_SCHEMA.ROUTINES`) AS routines
        ) AS object_counts,
        CONCAT(
            'This document contains only structural metadata. ',
            'It deliberately excludes default value literals, ',
            'view and routine bodies, column and table descriptions, ',
            'and all row data. Existence is recorded via counts; ',
            'contents are not. BigQuery has no CHECK constraints, ',
            'no traditional indexes, no triggers, no sequences, and ',
            'no packages, so the corresponding fields are 0 or empty.'
        ) AS privacy_note
    ) AS payload
)

-- =====================================================================
-- FINAL ASSEMBLY
-- =====================================================================
SELECT TO_JSON_STRING(STRUCT(
    (SELECT payload FROM meta) AS metadata,
    COALESCE((SELECT payload FROM tables_json),    []) AS tables,
    COALESCE((SELECT payload FROM views_json),     []) AS views,
    COALESCE((SELECT payload FROM routines_json),  []) AS routines,
    CAST([] AS ARRAY<STRING>) AS sequences,
    CAST([] AS ARRAY<STRING>) AS packages,
    CAST([] AS ARRAY<STRING>) AS types
)) AS schema_dump;
