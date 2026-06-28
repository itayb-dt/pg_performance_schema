# pg_perf_schema

> Self-monitoring for PostgreSQL — inspired by MySQL Performance Schema, built with plain SQL and cron.

---

## What is this?

`pg_perf_schema` turns PostgreSQL into its own performance observer. It periodically snapshots PostgreSQL's built-in system catalog views (`pg_stat_activity`, `pg_stat_statements`, `pg_locks`, `pg_stat_bgwriter`, and friends) and accumulates them into history tables — giving you a queryable record of what your database was doing over time.

No agents. No external collectors. No proprietary formats. Just SQL and a scheduler.

---

## Motivation

MySQL ships with a [Performance Schema](https://dev.mysql.com/doc/refman/8.0/en/performance-schema.html) — a built-in subsystem that continuously records query execution, waits, locks, and resource usage as historical data you can query at any time. PostgreSQL exposes rich real-time telemetry through its system views, but that data is ephemeral: the moment a query finishes or a connection closes, the signal is gone.

`pg_perf_schema` bridges that gap. By snapshotting system views at regular intervals and retaining the history inside the database itself, it enables the same class of after-the-fact investigation that MySQL users take for granted — without requiring external infrastructure.

---

## How it works

The design is deliberately minimal:

1. **Current scope is instance-level** — We currently collect metrics at the PostgreSQL instance level, not at per-database table/index granularity.
2. **Centralized storage database** — We copy snapshot data into one dedicated centralized database named `performance_schema_db`.
3. **Source views captured now** — Snapshot jobs read key system views such as `pg_stat_activity`, `pg_stat_statements`, `pg_locks`, and `pg_stat_database`.
4. **History tables** — Each snapshot is appended to a corresponding `_history` table with a `sampled_at` timestamp, building a time-series record inside the centralized database.
5. **Retention policy** — A periodic cleanup job trims rows older than a configurable retention window, keeping storage bounded.
6. **Query views** — A library of pre-built views and helper queries let you slice the history by time range, session, query fingerprint, lock type, or wait event — no post-processing needed.

```
pg_stat_activity        ──┐
pg_stat_statements      ──┤  cron job (every N seconds)
pg_stat_database        ──┤
pg_locks                ──┤──▶  snapshot functions  ──▶  *_history tables  ──▶  analysis views
pg_stat_bgwriter        ──┤
pg_stat_replication     ──┘
```

Current direction and next scope:

- Today: instance-level snapshots into centralized database `performance_schema_db`.
- Next: add per-database metrics for tables and indexes (for example from `pg_stat_user_tables` and `pg_stat_user_indexes`).

---

## Goals

| Goal | Detail |
|---|---|
| **Self-contained** | Everything lives inside the target database — no sidecars, no external processes required |
| **Plain SQL** | All logic is expressed in standard PostgreSQL SQL and PL/pgSQL; readable and auditable by any DBA |
| **Easy to deploy** | A single `install.sql` script sets up the schema; cron wiring is documented for `pg_cron`, system cron, and Kubernetes CronJobs |
| **Low overhead** | Snapshots are lightweight `INSERT … SELECT` statements; sampling interval is tunable to balance resolution vs. load |
| **Queryable history** | History is ordinary relational data — join it, aggregate it, export it, or feed it into Grafana like any other table |

---

## Non-goals

- This is **not** a replacement for `pg_stat_statements` — it builds on top of it.
- This is **not** an alerting system — pair it with your existing monitoring stack for that.
- This is **not** a streaming pipeline — if you need sub-second telemetry at scale, consider `pg_activity` or an OTel-based collector.

---

## Quick start

```sql
-- 1. Enable dependencies
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS pg_cron;  -- optional, see docs/scheduling.md

-- 2. Install pg_perf_schema
\i install.sql

-- 3. Schedule snapshots (example using pg_cron)
SELECT cron.schedule_in_database('pg_perf_activity',  '* * * * *', 'SELECT performance_schema.snapshot_activity()', 'performance_schema_db');
SELECT cron.schedule_in_database('pg_perf_statements','* * * * *', 'SELECT performance_schema.snapshot_statements()', 'performance_schema_db');
SELECT cron.schedule_in_database('pg_perf_locks',     '* * * * *', 'SELECT performance_schema.snapshot_locks()', 'performance_schema_db');
SELECT cron.schedule_in_database('pg_perf_cleanup',   '0 * * * *', 'SELECT performance_schema.cleanup(retention => interval ''7 days'')', 'performance_schema_db');
```

Then query your history:

```sql
-- What queries were running during the incident window?
SELECT sampled_at, query, state, wait_event_type, wait_event
FROM performance_schema.pg_stat_activity_history
WHERE sampled_at BETWEEN '2025-06-10 14:00' AND '2025-06-10 14:15'
ORDER BY sampled_at;
```

## Terminal scripts (starting with v0.0.3)

The workflow is split into two scripts:

- `install.sh` + `install.sql`: installation and scheduling.
- `verify.sh` + `verify.sql`: read-only verification and status.

Both scripts support `--help` and `--version`.

`install.sh` behavior:

- Always installs into hardcoded database `performance_schema_db` (creates it if missing).
- Creates/updates default `pg_cron` jobs.
- Uses `--pg-cron-db <name>` for the DB where `pg_cron` extension/jobs are managed.

`verify.sh` behavior:

- Read-only status checks.
- Uses `--pg-cron-db <name>` for cron jobs and run-history lookup.

```bash
./install.sh --help
./install.sh --version
./install.sh --dry-run
./install.sh --db "postgresql://postgres:postgres@localhost:5432/defaultdb" --pg-cron-db defaultdb

./verify.sh --help
./verify.sh --version
./verify.sh --dry-run --db "postgresql://postgres:postgres@localhost:5432/defaultdb" --pg-cron-db defaultdb

# Aiven-style examples
./install.sh --db "postgresql://USER:PASSWORD@HOST:PORT/defaultdb?sslmode=require" --pg-cron-db defaultdb
./verify.sh --db "postgresql://USER:PASSWORD@HOST:PORT/defaultdb?sslmode=require" --pg-cron-db defaultdb
```

Use `--dry-run` to preview actions without applying changes.

---

## Compatibility

| PostgreSQL | Status |
|---|---|
| 15, 16, 17 | ✅ Supported |
| 13, 14 | ✅ Supported |
| ≤ 12 | ⚠️ Untested |

`pg_cron` is optional — see [docs/scheduling.md](docs/scheduling.md) for system cron and Kubernetes alternatives.

---

---

## Related extensions and tools

`pg_perf_schema` is built on top of, and complements, a family of PostgreSQL extensions that provide raw telemetry. Understanding what each one does — and where it falls short — explains why a history layer is necessary.

### Built-in contrib extensions (ship with PostgreSQL)

**`pg_stat_statements`** is the foundation of query-level monitoring in PostgreSQL. It normalizes and aggregates execution statistics for every SQL statement the server runs — total calls, cumulative and average execution time, rows returned, block I/O, and more. The critical limitation is that it is *cumulative and reset-only*: it tells you that a query has been slow on average, but not *when* it was slow or what else was happening at the time. `pg_perf_schema` snapshots it periodically so that the temporal dimension is preserved.

**`pg_buffercache`** exposes the contents of shared buffers at the page level — which relations are cached, how many pages, and their usage counts. Useful for diagnosing cache eviction and working-set problems, but again, point-in-time only with no built-in history.

**`pgstattuple`** reports live vs. dead tuple counts and free space within a table or index. Helpful for diagnosing bloat, but it must be called explicitly per relation and produces no continuous record.

### Community extensions (require separate installation)

**`pg_wait_sampling`** samples wait events from `pg_stat_activity` at high frequency and aggregates them into histograms, providing a much richer picture of *what PostgreSQL is waiting for* than the instantaneous view in `pg_stat_activity`. It is a `shared_preload_libraries` extension — it requires a server restart and superuser access to install.

**`pg_stat_monitor`** (Percona) extends `pg_stat_statements` with bucketed time-window statistics, query plan capture, client application tracking, and wait event correlation. More powerful than `pg_stat_statements`, but similarly requires preloading and superuser rights, and produces current-window data rather than an unbounded history.

**`pg_stat_kcache`** correlates query execution with OS-level resource consumption (CPU time, physical reads/writes) by calling `getrusage(2)`. Requires both `pg_stat_statements` and `shared_preload_libraries`.

**`pg_qualstats`** samples predicate usage — which columns appear in `WHERE` clauses, join conditions, and `GROUP BY` — to surface missing index candidates. Also a preload extension with superuser requirements.

**`pg_cron`** is a cron-based job scheduler that runs entirely inside PostgreSQL as a background worker. It is the preferred scheduling backend for `pg_perf_schema`, though it is entirely optional (see [docs/scheduling.md](docs/scheduling.md)).

### ⚠️ Cloud provider limitations

This is the critical practical constraint: **most of the extensions above are unavailable or heavily restricted on managed PostgreSQL services**.

AWS RDS and Aurora, Google Cloud SQL, and Azure Database for PostgreSQL all operate PostgreSQL inside a hardened, restricted environment. They do not expose OS-level process access, do not allow arbitrary `shared_preload_libraries` entries, and do not grant true superuser access to users. As a consequence:

- `pg_wait_sampling`, `pg_stat_kcache`, and `pg_qualstats` are **not available** on any of the three major cloud providers' managed PostgreSQL offerings. They require either custom background workers or OS-level system calls that the cloud control plane intentionally blocks.
- `pg_stat_monitor` is similarly unavailable on managed services.
- `pg_cron` is supported on AWS RDS/Aurora and Google Cloud SQL (AlloyDB), but requires specific flag configuration, a database restart, and elevated permissions — it is not available on Google Cloud SQL standard instances out of the box, and on Azure it is not supported at all.
- Even `pg_stat_statements`, which *is* available on all major cloud providers, requires explicit opt-in through portal configuration or parameter group changes before it can be enabled.

Cloud providers compensate with proprietary alternatives — AWS Performance Insights, Azure Query Performance Insight with its `pgms_wait_sampling` module, and GCP's Query Insights — but these are closed, vendor-specific, and expose only the data the provider chooses to surface.

**`pg_perf_schema` is deliberately designed around this reality.** It relies only on `pg_stat_statements` (available everywhere with opt-in), standard SQL system views (available everywhere), and an external or internal scheduler. It works on self-hosted PostgreSQL, on VMs, in containers, on RDS, on Cloud SQL, and on Azure Flexible Server — anywhere you can run a SQL statement on a schedule.

---

## License

MIT