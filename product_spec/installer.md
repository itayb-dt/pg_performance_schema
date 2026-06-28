# Installer Specification

## Overview

`install.sh` is a command-line tool that sets up the `pg_perf_schema` infrastructure on a PostgreSQL instance. It creates the hardcoded target database, installs required extensions, loads the schema and functions, and schedules default monitoring jobs.

**Status**: Modifies database. Creates/alters objects.

## Execution Flow

1. **Parse Arguments** — Validate CLI parameters and build connection strings.
2. **Connect** — Test basic connectivity to the PostgreSQL instance.
3. **Ensure Database** — Check if `performance_schema_db` exists; create it if missing.
4. **Ensure Extensions** — Check and create `pg_stat_statements` in target DB and `pg_cron` in cron DB.
5. **Run Install SQL** — Execute `install.sql` to create schema, tables, functions, views.
6. **Ensure Default Jobs** — Create/update default cron jobs in the cron DB.

## Command-Line Interface

### Usage

```bash
./install.sh [options]
```

### Options

| Option | Required | Value | Description |
|--------|----------|-------|-------------|
| `--db` | No | connection string | Base PostgreSQL connection (localhost/service/URI). |
| `--pg-cron-db` | No | database name | Database where `pg_cron` extension/jobs are managed. Default: `performance_schema_db`. |
| `--admin-db` | No | connection string | Admin connection for CREATE DATABASE. Default: uses `--db`. |
| `--install-sql` | No | file path | Path to SQL installation script. Default: `./install.sql`. |
| `--yes` | No | — | Skip confirmation prompt. |
| `--dry-run` | No | — | Print actions without executing. |
| `--version` | No | — | Print version and exit. |
| `-h, --help` | No | — | Show help and exit. |

### Examples

```bash
# Local PostgreSQL
./install.sh --db postgresql://localhost:5432/defaultdb --pg-cron-db defaultdb

# Aiven (pg_cron in defaultdb, schema in performance_schema_db)
./install.sh --db "postgresql://user:pass@host:25782/defaultdb?sslmode=require" --pg-cron-db defaultdb

# Dry run
./install.sh --db "..." --pg-cron-db defaultdb --dry-run

# Skip confirmation
./install.sh --db "..." --pg-cron-db defaultdb --yes
```

## Database Targets

| Component | Database | Notes |
|-----------|----------|-------|
| Schema (`performance_schema`) | `performance_schema_db` | Hardcoded. Created if missing. |
| Tables, Functions, Views | `performance_schema_db` | Installed via `install.sql`. |
| `pg_stat_statements` | `performance_schema_db` | Required extension. |
| `pg_cron` | `--pg-cron-db` (or `performance_schema_db`) | Required. Fails if not available on platform. |
| Cron Jobs | `--pg-cron-db` | Jobs schedule work into `performance_schema_db`. |

## Default Cron Jobs

The installer creates/updates these jobs:

| Job Name | Schedule | Function | Target DB |
|----------|----------|----------|-----------|
| `pg_perf_activity` | `* * * * *` (every minute) | `performance_schema.snapshot_activity()` | `performance_schema_db` |
| `pg_perf_statements` | `* * * * *` (every minute) | `performance_schema.snapshot_statements()` | `performance_schema_db` |
| `pg_perf_locks` | `* * * * *` (every minute) | `performance_schema.snapshot_locks()` | `performance_schema_db` |
| `pg_perf_cleanup` | `0 * * * *` (every hour) | `performance_schema.cleanup(retention => interval '7 days')` | `performance_schema_db` |

Jobs are managed via `cron.schedule_in_database()` from the cron DB.

## Error Handling

| Error | Action |
|-------|--------|
| `psql` not found | Fail with error. |
| Connection fails | Fail with error. |
| `CREATE DATABASE` fails | Fail with error. |
| `pg_stat_statements` creation fails | Fail with error. |
| `pg_cron` creation fails | Fail with error and suggest platform limitations. |
| `install.sql` not found | Fail with error. |

## Output

### Normal Run

```
Install Script v0.0.3
[INFO] Install DB: performance_schema_db
[INFO] pg_cron DB: defaultdb
[INFO] [DRY-RUN] Would check/create database performance_schema_db
...
[SUCCESS] Created database performance_schema_db
[INFO] Exists: pg_stat_statements (version X.Y.Z)
[SUCCESS] Enabled pg_cron (version X.Y.Z) in defaultdb
[SUCCESS] Installed performance_schema objects
[SUCCESS] Ensured default pg_cron jobs

Installation finished successfully
```

### Dry Run

```
Install Script v0.0.3
[INFO] Install DB: performance_schema_db
[INFO] pg_cron DB: defaultdb
[INFO] [DRY-RUN] Would check/create database performance_schema_db
[INFO] [DRY-RUN] Would check/create pg_stat_statements in performance_schema_db
[INFO] [DRY-RUN] Would check/create pg_cron in defaultdb
[INFO] [DRY-RUN] Would execute ./install.sql in performance_schema_db
[INFO] [DRY-RUN] Would create/update default pg_cron jobs from defaultdb

Installation finished successfully
```

## Confirmation

Unless `--yes` or `--dry-run` is set, the script prompts:
```
Proceed with install? Type 'yes' or 'y':
```

## Version

Reads from `./VERSION` file. Format: `MAJOR.MINOR.PATCH`.

## Exit Codes

- `0` — Success.
- `1` — Any fatal error (connection, permissions, missing files, extension creation fails).
