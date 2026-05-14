# sql-x-ray

**See the structure, not the data.**

`sql-x-ray` produces a privacy-safe structural metadata dump from any major
SQL database, designed for use as LLM context. Structure only, never values:
no defaults, no constraint expressions, no view bodies, no enum labels, no
sample data. Safe to share with any LLM regardless of what your database
contains.

---

## What it does

Each script connects to your database through any standard SQL client, reads
its system catalogs, and outputs one JSON document describing the shape of
the schema. The output covers tables, columns, types, primary and foreign
keys, indexes, and the existence of constraints, triggers, views, and
routines — everything an LLM needs to write accurate queries without ever
seeing the data inside.

---

## Try it on a real database first

The fastest way to see what `sql-x-ray` does is to run it in your browser
against a preloaded sample database — no install, no signup, no setup.

[**sqlize.online**](https://sqlize.online) hosts ReadOnly sample databases
for every engine on our roadmap:

| Engine selection on sqlize.online | Sample schema |
|---|---|
| **PostgreSQL 18 Bookings (ReadOnly)** | Airline reservation system — flights, bookings, tickets, boarding passes, seats |
| **PostgreSQL 17 + PostGIS WorkShop (ReadOnly)** | Spatial / geographic data |
| **MySQL 9.7 Sakila (ReadOnly)** | DVD rental store (the canonical sample) |
| **MariaDB 11.8 OpenFlights (ReadOnly)** | Airport, airline, and route data |
| **MS SQL Server 2022 AdventureWorks (ReadOnly)** | Microsoft's bicycle company (68 tables, 5 schemas) |
| **Oracle Database 19c HR** | Classic Oracle HR sample (employees, departments, jobs) |
| **Firebird 4.0 Employee** | Firebird's bundled sample |

How to use it:

1. Open [sqlize.online](https://sqlize.online)
2. Pick a ReadOnly sample database from the engine dropdown
3. Paste the matching script from this repo (e.g. `postgresql/postgres-xray.sql`)
4. Click **Run SQL code**
5. The single result cell contains the full JSON dump — copy it, paste into
   your LLM of choice, and you're done

This is also the recommended way to validate a script after editing it —
test against a known schema before pointing it at your real database.

Other quality SQL playgrounds worth knowing:

- [**DB Fiddle**](https://www.db-fiddle.com) — PostgreSQL, MySQL, SQLite,
  SQL Server; clean two-pane interface
- [**Aiven Postgres Playground**](https://aiven.io/tools/pg-playground) —
  PostgreSQL via WebAssembly, entirely in your browser
- [**playcode.io SQL Playground**](https://playcode.io/sql-playground) —
  PostgreSQL via PGlite with preloaded Chinook (music store) and Northwind
  (e-commerce)

---

## What's included

For every table:

- Schema, name, kind (table / partitioned table / foreign table)
- Estimated row count and on-disk size
- All columns with name, position, data type, nullability, identity and
  generated-column flags, and whether a default exists
- Primary key columns
- Foreign keys with from-columns, target schema/table/columns, and
  ON UPDATE / ON DELETE actions
- Unique constraints with their column lists
- Check constraint count (existence only)
- All non-PK indexes with name, method, uniqueness, partial-index flag,
  columns (including expression placeholders), and INCLUDE columns
- Trigger count (existence only)
- Inheritance / partition parents

For views, routines, sequences, and user-defined types, the dump records
existence and signatures only — never bodies, never values. Routines
include an `is_trigger` flag and the script automatically filters out
extension-owned functions so output stays clean.

---

## What's deliberately excluded

The following are **never** in the output:

| Excluded | Why |
|---|---|
| Default value literals | Could contain personal data or business strings |
| Check constraint expressions | Could contain literal values or domain logic |
| View and materialized view definitions | SQL bodies could reveal filtering over sensitive columns |
| Function and procedure bodies | Could contain hardcoded identifiers or business logic |
| Enum value labels | Could be clinical, financial, legal, or otherwise sensitive |
| Comments and descriptions | Free-text fields; could contain anything |
| Row data and column samples | Never queried at all |

Existence is still recorded where useful — e.g. `check_constraint_count: 3`
tells the LLM "there are check constraints on this table" without revealing
what they enforce. Expression indexes show `<expression>` in their column
list as a placeholder.

---

## Supported engines

| Engine | Script | Status |
|---|---|---|
| PostgreSQL | `postgresql/postgres-xray.sql` | ✅ Stable |
| SQLite | `sqlite/sqlite-xray.sql` | 🚧 Planned |
| MySQL / MariaDB | `mysql/mysql-xray.sql` | 🚧 Planned |
| SQL Server | `sqlserver/sqlserver-xray.sql` | 🚧 Planned |
| Snowflake | `snowflake/snowflake-xray.sql` | 🚧 Planned |
| BigQuery | `bigquery/bigquery-xray.sql` | 🚧 Planned |

---

## Repository structure

```
sql-x-ray/
├── README.md
├── postgresql/
│   └── postgres-xray.sql
├── mysql/
│   └── mysql-xray.sql
├── sqlserver/
│   └── sqlserver-xray.sql
├── sqlite/
│   └── sqlite-xray.sql
├── snowflake/
│   └── snowflake-xray.sql
└── bigquery/
    └── bigquery-xray.sql
```

Each engine lives in its own folder so it's obvious at a glance which file
applies to which database.

---

## Running against your own database

1. Pick the folder for your engine and open the `<engine>-xray.sql` file
2. Adjust the `params` block at the top of the file — schema filter,
   whether to include row counts, whether to pretty-print
3. Run the script in any SQL client (DBeaver, DataGrip, psql, pgAdmin,
   Metabase, Insight, SSMS, Snowsight, etc.)
4. The result is a single cell containing a JSON document; copy and save
   it as `schema.json`

To feed the dump to an LLM, paste it into a chat with a short intro:

> Here is the structural metadata for a SQL database I work with. It contains
> only structure — no values, no row data, no view bodies. I'll be asking
> you to help me write queries against this schema.
>
> ```json
> { ...paste the dump... }
> ```

---

## Requirements

- A SQL client that can run a multi-CTE query and return a single JSON cell
- Read permission on the database's system catalogs / `information_schema`
- No installs, no extensions, no Python required

---

## Security and privacy

- **Read-only.** Every script only queries system catalogs and
  `information_schema`. It never modifies the database, never queries row
  data, and never samples values from user columns.
- **Structure only, never values.** No field in the output can carry
  sensitive data by design. The privacy guarantee comes from what the script
  doesn't read, not from filtering applied after the fact.
- **No network calls.** Everything runs in your SQL client against your
  database. Nothing leaves your environment until you choose to share the
  output.

### Edge cases worth knowing

The privacy stance is strong but not infinite. The following can appear in a
dump and may matter in some contexts:

- **Names of schemas, tables, columns, indexes, and constraints.** Almost
  always describe types of data rather than data itself, but proprietary
  product names or classified project codenames could be considered
  sensitive. Review before sharing externally if this applies to you.
- **Estimated row counts.** Aggregate counts are universally safe under
  HIPAA, GDPR, and similar regimes, but in very small populations a count
  could narrow identification. Set `include_stats = FALSE` if needed.
- **Foreign key target names.** Reveal which tables relate to which.

---

## Employer-vetted LLM disclaimer

`sql-x-ray` is designed so its output is safe to share with external large
language models. That guarantee covers what the tool produces — it does not
cover the LLM service you send it to.

**Strong recommendation:** use only an LLM that your employer has explicitly
vetted or has a contractual relationship with (enterprise API agreement,
signed BAA, private deployment, or documented institutional policy that
permits the use). Even structural metadata describes systems that may
contain protected data, and many organizations have policies on disclosing
system descriptions to external services.

Before pasting a dump into any LLM:

- Check your organization's data-governance, IT, or security policy
- Confirm the LLM provider's data-handling terms (training opt-out,
  retention, geographic location, subprocessor list)
- Prefer enterprise or API tiers with zero-retention guarantees over free
  consumer chat tiers
- When in doubt, ask your DPO, CISO, IT, or compliance contact

The author and contributors of `sql-x-ray` accept no liability for misuse,
data exposure, regulatory consequences, or contractual breaches that result
from sharing dump output with third-party services. The tool's privacy
properties are a starting point, not a substitute for institutional review.

---

## License

This project is licensed under [CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/).

You are free to:
- Use, share, and adapt this work
- Use it at your job

Under these terms:
- **Attribution** — Credit the original author
- **NonCommercial** — No selling or commercial products
- **ShareAlike** — Derivatives must use the same license
