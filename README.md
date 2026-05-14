# sql-x-ray

**See the structure, not the data.**

`sql-x-ray` produces a privacy-safe structural dump of a SQL database, designed as priming context for an LLM. Structure only, never values: no defaults, no constraint expressions, no view bodies, no enum labels, no sample data. Safe to share with any LLM regardless of what your database contains.

---

## Why this exists

Copying a full schema into an LLM chat fails on size for any non-trivial database, and even when it fits, view bodies and CHECK expressions can leak business logic or literal values. Sample queries are slow and error-prone. `sql-x-ray` gives the LLM exactly what it needs to write accurate queries against your schema (tables, columns, types, relationships, indexes) and nothing it shouldn't have.

---

## Try it in your browser

The fastest way to see the output is to run it against a preloaded sample database at [sqlize.online](https://sqlize.online). No install, no signup, no setup.

1. Open [sqlize.online](https://sqlize.online)
2. Pick a ReadOnly sample database from the engine dropdown
3. Paste the matching script from this repo (e.g. `scripts/postgres-xray.sql`)
4. Click **Run SQL code**
5. The single result cell contains the full JSON dump. Copy it, paste into your LLM of choice, done.

Sample databases available on sqlize.online:

| Engine | Sample schema |
|---|---|
| PostgreSQL 18 Bookings (ReadOnly) | Airline reservations: flights, bookings, tickets, boarding passes, seats |
| PostgreSQL 17 + PostGIS WorkShop (ReadOnly) | Spatial and geographic data |
| MySQL 9.7 Sakila (ReadOnly) | DVD rental store (the canonical sample) |
| MariaDB 11.8 OpenFlights (ReadOnly) | Airport, airline, and route data |
| MS SQL Server 2022 AdventureWorks (ReadOnly) | Microsoft's bicycle company (68 tables, 5 schemas) |
| Oracle Database 19c HR | Classic Oracle HR sample (employees, departments, jobs) |
| Firebird 4.0 Employee | Firebird's bundled sample |

This is also the right way to validate a script after editing it. Test against a known schema before pointing it at your real database.

Other SQL playgrounds worth knowing:

- [DB Fiddle](https://www.db-fiddle.com): PostgreSQL, MySQL, SQLite, SQL Server. Clean two-pane interface.
- [Aiven Postgres Playground](https://aiven.io/tools/pg-playground): PostgreSQL via WebAssembly, entirely in your browser.
- [playcode.io SQL Playground](https://playcode.io/sql-playground): PostgreSQL via PGlite with preloaded Chinook (music store) and Northwind (e-commerce).

---

## What the output looks like

A trimmed example dump of a tiny e-commerce schema:

```json
{
  "metadata": {
    "tool_name": "sql-x-ray",
    "tool_version": "1.0.0",
    "engine": "postgresql",
    "engine_version": "16.4",
    "database": "shop",
    "generated_at": "2026-05-14T14:30:00Z",
    "schema_filter": "%",
    "schemas": ["public"],
    "privacy_note": "This document contains only structural metadata..."
  },
  "tables": [
    {
      "schema": "public",
      "name": "orders",
      "kind": "table",
      "row_count_estimate": 142893,
      "total_size_bytes": 24576000,
      "primary_key": { "columns": ["order_id"] },
      "foreign_keys": [
        {
          "from_columns": ["customer_id"],
          "to_schema": "public",
          "to_table": "customers",
          "to_columns": ["customer_id"],
          "on_update": "NO ACTION",
          "on_delete": "RESTRICT"
        }
      ],
      "check_constraint_count": 2,
      "indexes": [
        {
          "name": "orders_customer_id_idx",
          "method": "btree",
          "unique": false,
          "partial": false,
          "columns": ["customer_id"]
        },
        {
          "name": "orders_status_created_idx",
          "method": "btree",
          "unique": false,
          "partial": true,
          "columns": ["status", "created_at"]
        }
      ],
      "trigger_count": 1,
      "columns": [
        { "name": "order_id",    "position": 1, "data_type": "bigint",                   "nullable": false, "is_identity": true,  "is_generated": false, "has_default": false },
        { "name": "customer_id", "position": 2, "data_type": "bigint",                   "nullable": false, "is_identity": false, "is_generated": false, "has_default": false },
        { "name": "status",      "position": 3, "data_type": "text",                     "nullable": false, "is_identity": false, "is_generated": false, "has_default": true  },
        { "name": "total_cents", "position": 4, "data_type": "integer",                  "nullable": false, "is_identity": false, "is_generated": false, "has_default": false },
        { "name": "created_at",  "position": 5, "data_type": "timestamp with time zone", "nullable": false, "is_identity": false, "is_generated": false, "has_default": true  }
      ]
    }
  ],
  "views": [],
  "routines": [],
  "sequences": [{ "schema": "public", "name": "orders_order_id_seq", "data_type": "bigint" }],
  "types": []
}
```

An LLM can use this to write a correct join between `orders` and `customers` (right FK direction, right types, right nullability) without ever seeing a single customer record.

---

## Run it on your own database

1. Open the script for your engine in the `scripts/` folder
2. Adjust the `params` block at the top of the file (schema filter, whether to include row counts, whether to pretty-print)
3. Run the script in any SQL client (DBeaver, DataGrip, psql, pgAdmin, Metabase, Insight, SSMS, Snowsight)
4. The result is a single cell containing a JSON document. Copy and save it as `schema.json`.

To feed the dump to an LLM, paste it into a chat with a short intro:

> Here is the structural metadata for a SQL database I work with. It contains only structure, no values, no row data, no view bodies. I'll be asking you to help me write queries against this schema.
>
> ```json
> { ...paste the dump... }
> ```

---

## What's in the dump

For every table:

- Schema, name, kind (table, partitioned table, foreign table)
- Estimated row count and on-disk size
- All columns with name, position, data type, nullability, identity and generated-column flags, and whether a default exists
- Primary key columns
- Foreign keys with from-columns, target schema/table/columns, and ON UPDATE / ON DELETE actions
- Unique constraints with their column lists
- Check constraint count (existence only)
- All secondary indexes (excludes indexes backing PK and unique constraints to avoid duplication) with name, method, uniqueness, partial-index flag, columns (including expression placeholders), and INCLUDE columns
- Trigger count (existence only)
- Inheritance and partition parents

For views and materialized views: schema, name, and column list with types and nullability.

For routines: schema, name, kind (function, procedure, aggregate, window), language, return type, argument signature, and an `is_trigger` flag. Bodies are never extracted. Extension-owned functions are filtered out so output stays clean.

For sequences and user-defined types: existence and basic metadata only. Enum value labels are excluded by design.

---

## What's never in the dump

| Excluded | Why |
|---|---|
| Default value literals | Could contain personal data or business strings |
| Check constraint expressions | Could contain literal values or domain logic |
| View and materialized view definitions | SQL bodies could reveal filtering over sensitive columns |
| Function and procedure bodies | Could contain hardcoded identifiers or business logic |
| Enum value labels | Could be clinical, financial, legal, or otherwise sensitive |
| Comments and descriptions | Free-text fields, could contain anything |
| Row data and column samples | Never queried at all |

Existence is still recorded where useful. `check_constraint_count: 3` tells the LLM there are check constraints on this table without revealing what they enforce. Expression indexes show `<expression>` in their column list as a placeholder.

---

## Engine support

| Engine | Script | Status | Minimum version |
|---|---|---|---|
| PostgreSQL | `scripts/postgres-xray.sql` | Stable | PostgreSQL 12 |
| SQLite | `scripts/sqlite-xray.sql` | Planned | |
| MySQL / MariaDB | `scripts/mysql-xray.sql` | Planned | |
| SQL Server | `scripts/sqlserver-xray.sql` | Planned | |
| Snowflake | `scripts/snowflake-xray.sql` | Planned | |
| BigQuery | `scripts/bigquery-xray.sql` | Planned | |

---

## Requirements

- A SQL client that can run a multi-CTE query and return a single JSON cell
- Read permission on the database's system catalogs and `information_schema`
- No installs, no extensions, no Python required

---

## Security and privacy

- **Read-only.** Every script queries system catalogs and `information_schema` only. It never modifies the database, never queries row data, and never samples values from user columns.
- **Structure only, never values.** No field in the output can carry sensitive data by design. The guarantee comes from what the script doesn't read, not from filtering applied afterward.
- **No network calls.** Everything runs in your SQL client against your database. Nothing leaves your environment until you choose to share the output.

### Edge cases worth knowing

The privacy stance is strong but not infinite. The following can appear in a dump and may matter in some contexts:

- **Names of schemas, tables, columns, indexes, and constraints.** Almost always describe types of data rather than data itself, but proprietary product names or classified project codenames could be considered sensitive. Review before sharing externally if this applies to you.
- **Estimated row counts.** Aggregate counts are universally safe under HIPAA, GDPR, and similar regimes, but in very small populations a count could narrow identification. Set `include_stats = FALSE` if needed.
- **Foreign key target names.** Reveal which tables relate to which.

---

## Using the dump with an LLM

The output is designed to be safe for external LLMs. That guarantee covers what the tool produces. It does not cover the service you send it to.

Strong recommendation: use only an LLM your employer has explicitly vetted, or one with a contractual relationship (enterprise API agreement, signed BAA, private deployment, or documented institutional policy that permits the use). Even structural metadata describes systems that may contain protected data, and many organizations have policies on disclosing system descriptions to external services.

Before pasting a dump into any LLM:

- Check your organization's data governance, IT, or security policy
- Confirm the LLM provider's data handling terms (training opt-out, retention, geographic location, subprocessor list)
- Prefer enterprise or API tiers with zero-retention guarantees over free consumer chat tiers
- When in doubt, ask your DPO, CISO, IT, or compliance contact

The author and contributors of `sql-x-ray` accept no liability for misuse, data exposure, regulatory consequences, or contractual breaches that result from sharing dump output with third-party services. The tool's privacy properties are a starting point, not a substitute for institutional review.

---

## License

This project is licensed under [CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/).

You are free to:

- Use, share, and adapt this work
- Use it at your job

Under these terms:

- **Attribution.** Credit the original author.
- **NonCommercial.** No selling or commercial products.
- **ShareAlike.** Derivatives must use the same license.