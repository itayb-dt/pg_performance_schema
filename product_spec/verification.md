# Verification Specification

## Overview

`verify.sh` is a command-line tool that provides read-only operational status and health checks of an installed `pg_perf_schema` system. It reports database configuration, sizes, installed extensions, cron job status, and recent job execution history.

**Status**: Read-only. No modifications to database.

## Execution Flow

1. **Parse Arguments** — Validate CLI parameters and build connection strings.
2. **Connect** — Test connectivity to PostgreSQL instance.
3. **Verify Install DB Exists** — Check if `performance_schema_db` exists and report size.
4. **Report Installed Objects** — List tables, functions, views in `performance_schema` schema with sizes.
5. **Report Extensions** — Check `pg_stat_statements` and `pg_cron` presence and versions.
6. **Report Cron Jobs** — List all jobs from cron DB with names, schedules, and active status.
7. **Report Job History** — Show last 10 executions of each job with timestamps, status, and messages.

## Command-Line Interface

### Usage

```bash
./verify.sh [options]
```

### Options

| Option | Required | Value | Description |
|--------|----------|-------|-------------|
| `--db` | No | connection string | Base PostgreSQL connection. |
| `--pg-cron-db` | No | database name | Database where cron jobs are managed. Default: `performance_schema_db`. |
| `--admin-db` | No | connection string | Admin connection for DB existence checks. Default: uses `--db`. |
| `--verify-sql` | No | file path | Path to SQL verification script. Default: `./verify.sql`. |
| `--dry-run` | No | — | Print checks without querying. |
| `--version` | No | — | Print version and exit. |
| `-h, --help` | No | — | Show help and exit. |

### Examples

```bash
# Local PostgreSQL
./verify.sh --db postgresql://localhost:5432/defaultdb --pg-cron-db defaultdb

# Aiven
./verify.sh --db "postgresql://user:pass@host:25782/defaultdb?sslmode=require" --pg-cron-db defaultdb

# Dry run
./verify.sh --db "..." --pg-cron-db defaultdb --dry-run

# Check status
./verify.sh --db "..." --pg-cron-db defaultdb
```

## Output Sections

### 1. Header

```
Verify Script v0.0.3
[INFO] Install DB: performance_schema_db
[INFO] Cron DB: defaultdb
[INFO] Mode: read-only
```

### 2. Connection Test

```
[SUCCESS] Database exists: performance_schema_db
[INFO] Database size for performance_schema_db: 2.5 MB
```

Or if database missing:
```
[WARN] Database missing: performance_schema_db
```

### 3. Managed Tables and Sizes

```
Managed tables (performance_schema_db):
schema_version | 48 kB
pg_stat_activity_history | 1.2 MB
pg_stat_statements_history | 4.5 MB
pg_locks_history | 256 kB
pg_stat_database_history | 1.1 MB
pg_wait_sampling_history | 768 kB
```

### 4. Extensions

```
[INFO] pg_stat_statements version: 1.9
[INFO] pg_cron version: 1.4 (in defaultdb)
```

Or if missing:
```
[WARN] pg_stat_statements not installed in performance_schema_db
[WARN] pg_cron not installed in defaultdb
```

### 5. Cron Jobs

```
Cron jobs (defaultdb):
1 | pg_perf_activity | * * * * * | active
2 | pg_perf_statements | * * * * * | active
3 | pg_perf_locks | * * * * * | active
4 | pg_perf_database | * * * * * | active
5 | pg_perf_wait_samples | * * * * * | active
6 | pg_perf_cleanup | 0 * * * * | active
```

Or if no jobs:
```
[INFO] No cron jobs found
```

### 6. Job Execution History

Shows last 10 runs for all jobs with status summary:

```
Last 10 cron runs (defaultdb):
2026-06-28 14:35:00 | job 1 | succeeded | 
2026-06-28 14:34:00 | job 1 | succeeded | 
2026-06-28 14:33:00 | job 1 | succeeded | 
2026-06-28 14:35:01 | job 2 | succeeded | 
2026-06-28 14:34:01 | job 2 | succeeded | 
2026-06-28 14:33:01 | job 2 | succeeded | 
2026-06-28 14:35:02 | job 3 | succeeded | 
2026-06-28 14:34:02 | job 3 | succeeded | 
2026-06-28 14:33:02 | job 3 | succeeded | 
2026-06-28 14:35:03 | job 4 | succeeded |
2026-06-28 14:35:04 | job 5 | succeeded |
2026-06-28 01:00:00 | job 6 | succeeded |
```

### 7. Job Status Summary (Calculated)

After listing runs, verification calculates and displays status per job:

```
Job Status Summary:
  pg_perf_activity (job 1):
    Last run: 2026-06-28 14:35:00
    Success rate: 10/10 (100%)
    Failures: 0
    
  pg_perf_statements (job 2):
    Last run: 2026-06-28 14:35:01
    Success rate: 10/10 (100%)
    Failures: 0
    
  pg_perf_locks (job 3):
    Last run: 2026-06-28 14:35:02
    Success rate: 10/10 (100%)
    Failures: 0

  pg_perf_database (job 4):
    Last run: 2026-06-28 14:35:03
    Success rate: 10/10 (100%)
    Failures: 0

  pg_perf_wait_samples (job 5):
    Last run: 2026-06-28 14:35:04
    Success rate: 10/10 (100%)
    Failures: 0
    
  pg_perf_cleanup (job 6):
    Last run: 2026-06-28 01:00:00
    Success rate: 1/1 (100%)
    Failures: 0
```

## Dry Run Output

When `--dry-run` is specified, only prints what it would check:

```
Verify Script v0.0.3
[INFO] Install DB: performance_schema_db
[INFO] Cron DB: defaultdb
[INFO] Mode: read-only
[INFO] [DRY-RUN] Would verify database existence and size
[INFO] [DRY-RUN] Would run verify SQL on performance_schema_db
[INFO] [DRY-RUN] Would check extension versions
[INFO] [DRY-RUN] Would list cron jobs and last 10 runs from defaultdb
[INFO] [DRY-RUN] Would calculate job status summary
```

## Error Handling

| Error | Action |
|-------|--------|
| `psql` not found | Fail with error. |
| Connection fails | Fail with error; suggest checking connection string (e.g., `sslmode=require`). |
| `performance_schema_db` missing | Warn and skip object/extension details; exit 1. |
| `verify.sql` not found | Fail with error. |
| Cannot read `cron.job` | Warn and continue. |
| Cannot read `cron.job_run_details` | Warn and continue. |

## SQL Verification Queries

`verify.sql` runs read-only queries to check:
- Schema `performance_schema` exists
- Table names and row counts
- Function names
- View names
- Extension availability

## Version

Reads from `./VERSION` file. Format: `MAJOR.MINOR.PATCH`.

## Exit Codes

- `0` — Success. Database exists and all major checks passed.
- `1` — Fatal error (cannot connect, database missing, file not found).

## Related Files

- `verify.sql` — SQL queries for schema validation (run once per execution).
- `VERSION` — Version file (shared with `install.sh`).

## Design Principles

- **Read-only**: No `CREATE`, `ALTER`, or `DELETE` statements.
- **Informative**: Clearly report what is and is not configured.
- **Actionable**: Help users understand job health and success rates at a glance.
- **Transparent**: Show connection targets, sizes, and failure details.
