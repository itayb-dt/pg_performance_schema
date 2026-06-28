#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION_FILE="$SCRIPT_DIR/VERSION"
VERIFY_SQL_DEFAULT="$SCRIPT_DIR/verify.sql"
INSTALL_DB_NAME="performance_schema_db"

if [[ -f "$VERSION_FILE" ]]; then
  SCRIPT_VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
else
  SCRIPT_VERSION="0.0.1"
fi

if command -v tput >/dev/null 2>&1 && [[ -n "${TERM:-}" ]] && [[ "${TERM:-}" != "dumb" ]]; then
  BOLD="$(tput bold)"
  RED="$(tput setaf 1)"
  GREEN="$(tput setaf 2)"
  YELLOW="$(tput setaf 3)"
  CYAN="$(tput setaf 6)"
  RESET="$(tput sgr0)"
else
  BOLD=""
  RED=""
  GREEN=""
  YELLOW=""
  CYAN=""
  RESET=""
fi

TARGET_DB=""
TARGET_DB_INSTALL=""
TARGET_DB_CRON=""
ADMIN_DB=""
VERIFY_SQL="$VERIFY_SQL_DEFAULT"
PG_CRON_DB=""
DRY_RUN="false"

info() { printf "%b[INFO]%b %s\n" "$CYAN" "$RESET" "$1"; }
success() { printf "%b[SUCCESS]%b %s\n" "$GREEN" "$RESET" "$1"; }
warn() { printf "%b[WARN]%b %s\n" "$YELLOW" "$RESET" "$1"; }
error() { printf "%b[ERROR]%b %s\n" "$RED" "$RESET" "$1" >&2; }

show_help() {
  cat <<EOF
Usage: ./verify.sh [options]

Options:
  --db <connection>        Base PostgreSQL connection string/target.
  --pg-cron-db <name>      Database where cron jobs/history are queried.
  --admin-db <connection>  Admin connection for database existence checks.
  --verify-sql <path>      Path to verify SQL (default: ./verify.sql).
  --dry-run                Print checks without querying.
  --version                Print version and exit.
  -h, --help               Show this help.

Notes:
  - Verification always targets hardcoded database: performance_schema_db.
  - Status is read-only; no CREATE/ALTER statements are executed.
EOF
}

build_connection_for_db() {
  local source_conn="$1"
  local target_db_name="$2"
  local base
  local query

  if [[ -z "$source_conn" ]]; then
    printf '%s\n' "$target_db_name"
    return 0
  fi

  if [[ "$source_conn" == *"://"* ]]; then
    base="${source_conn%%\?*}"
    query=""
    if [[ "$base" != "$source_conn" ]]; then
      query="${source_conn#*\?}"
    fi
    local out
    out="${base%/*}/$target_db_name"
    if [[ -n "$query" ]]; then
      out="$out?$query"
    fi
    printf '%s\n' "$out"
    return 0
  fi

  if [[ "$source_conn" == *"="* ]]; then
    if [[ "$source_conn" == *"dbname="* ]]; then
      printf '%s\n' "$(printf '%s' "$source_conn" | sed -E "s/(^|[[:space:]])dbname=[^[:space:]]+/\\1dbname=$target_db_name/")"
    else
      printf '%s\n' "$source_conn dbname=$target_db_name"
    fi
    return 0
  fi

  printf '%s\n' "$target_db_name"
}

psql_install() { psql "$TARGET_DB_INSTALL" "$@"; }
psql_cron() { psql "$TARGET_DB_CRON" "$@"; }
psql_admin() {
  if [[ -n "$ADMIN_DB" ]]; then
    psql "$ADMIN_DB" "$@"
  elif [[ -n "$TARGET_DB" ]]; then
    psql "$TARGET_DB" "$@"
  else
    psql "$TARGET_DB_INSTALL" "$@"
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --db)
        [[ $# -lt 2 ]] && { error "Missing value for --db"; exit 1; }
        TARGET_DB="$2"
        shift 2
        ;;
      --pg-cron-db)
        [[ $# -lt 2 ]] && { error "Missing value for --pg-cron-db"; exit 1; }
        PG_CRON_DB="$2"
        shift 2
        ;;
      --admin-db)
        [[ $# -lt 2 ]] && { error "Missing value for --admin-db"; exit 1; }
        ADMIN_DB="$2"
        shift 2
        ;;
      --verify-sql)
        [[ $# -lt 2 ]] && { error "Missing value for --verify-sql"; exit 1; }
        VERIFY_SQL="$2"
        shift 2
        ;;
      --dry-run)
        DRY_RUN="true"
        shift
        ;;
      --version)
        echo "$SCRIPT_VERSION"
        exit 0
        ;;
      -h|--help)
        show_help
        exit 0
        ;;
      *)
        error "Unknown argument: $1"
        show_help
        exit 1
        ;;
    esac
  done
}

main() {
  parse_args "$@"

  if ! command -v psql >/dev/null 2>&1; then
    error "psql command not found"
    exit 1
  fi

  if [[ -z "$PG_CRON_DB" ]]; then
    PG_CRON_DB="$INSTALL_DB_NAME"
  fi

  TARGET_DB_INSTALL="$(build_connection_for_db "$TARGET_DB" "$INSTALL_DB_NAME")"
  TARGET_DB_CRON="$(build_connection_for_db "$TARGET_DB" "$PG_CRON_DB")"

  printf "\n%bVerify Script v%s%b\n" "$BOLD$CYAN" "$SCRIPT_VERSION" "$RESET"
  info "Install DB: $INSTALL_DB_NAME"
  info "Cron DB: $PG_CRON_DB"
  info "Mode: read-only"

  if ! psql_admin -Atqc "SELECT 1;" >/dev/null 2>&1; then
    error "Could not connect to PostgreSQL"
    error "Check your connection string:"
    error "  - Verify hostname and port are correct"
    error "  - Check for typos (e.g., sslmode=require, not reqire)"
    error "  - Ensure credentials are valid"
    exit 1
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    info "[DRY-RUN] Would verify database existence and size"
    info "[DRY-RUN] Would run verify SQL on $INSTALL_DB_NAME"
    info "[DRY-RUN] Would check extension versions"
    info "[DRY-RUN] Would list cron jobs and last 10 runs from $PG_CRON_DB"
    exit 0
  fi

  db_exists="$(psql_admin -Atqc "SELECT 1 FROM pg_database WHERE datname = '$INSTALL_DB_NAME';" 2>/dev/null || true)"
  if [[ "$db_exists" == "1" ]]; then
    success "Database exists: $INSTALL_DB_NAME"
  else
    warn "Database missing: $INSTALL_DB_NAME"
    exit 1
  fi

  db_size="$(psql_admin -Atqc "SELECT pg_size_pretty(pg_database_size('$INSTALL_DB_NAME'));" 2>/dev/null || true)"
  info "Database size: ${db_size:-unknown}"

  echo
  printf "%bSchema Status (%s):%b\n" "$BOLD$CYAN" "$INSTALL_DB_NAME" "$RESET"
  
  schema_exists="$(psql_install -Atqc "SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = 'performance_schema') THEN 'yes' ELSE 'no' END;" 2>/dev/null || true)"
  if [[ "$schema_exists" == "yes" ]]; then
    success "performance_schema: exists"
  else
    warn "performance_schema: missing"
  fi

  echo
  printf "%bManaged Tables (%s):%b\n" "$BOLD$CYAN" "$INSTALL_DB_NAME" "$RESET"
  psql_install -Atqc "SELECT c.relname || ' | ' || pg_size_pretty(pg_total_relation_size(c.oid)) || ' | ' || n_live_tup || ' rows' FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace JOIN pg_stat_user_tables s ON s.relid = c.oid WHERE n.nspname = 'performance_schema' AND c.relkind = 'r' ORDER BY c.relname;" 2>/dev/null || warn "Could not read managed tables"

  echo
  printf "%bFunctions (%s):%b\n" "$BOLD$CYAN" "$INSTALL_DB_NAME" "$RESET"
  psql_install -Atqc "SELECT p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'performance_schema' ORDER BY p.proname;" 2>/dev/null || warn "Could not read functions"

  echo
  printf "%bViews (%s):%b\n" "$BOLD$CYAN" "$INSTALL_DB_NAME" "$RESET"
  psql_install -Atqc "SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'performance_schema' AND c.relkind = 'v' ORDER BY c.relname;" 2>/dev/null || warn "Could not read views"

  echo
  printf "%bExtensions:%b\n" "$BOLD$CYAN" "$RESET"
  pgss_ver="$(psql_install -Atqc "SELECT extversion FROM pg_extension WHERE extname='pg_stat_statements';" 2>/dev/null || true)"
  if [[ -n "$pgss_ver" ]]; then
    info "pg_stat_statements: $pgss_ver (in $INSTALL_DB_NAME)"
  else
    warn "pg_stat_statements: not installed in $INSTALL_DB_NAME"
  fi

  pgcron_ver="$(psql_cron -Atqc "SELECT extversion FROM pg_extension WHERE extname='pg_cron';" 2>/dev/null || true)"
  if [[ -n "$pgcron_ver" ]]; then
    info "pg_cron: $pgcron_ver (in $PG_CRON_DB)"
  else
    warn "pg_cron: not installed in $PG_CRON_DB"
  fi

  echo
  printf "%bCron Jobs (%s):%b\n" "$BOLD$CYAN" "$PG_CRON_DB" "$RESET"
  psql_cron -Atqc "SELECT jobid || ' | ' || jobname || ' | ' || schedule || ' | ' || CASE WHEN active THEN 'active' ELSE 'inactive' END FROM cron.job ORDER BY jobid;" 2>/dev/null || warn "Could not read cron.job"

  echo
  printf "%bJob Status Summary (Last 10 Executions, %s):%b\n" "$BOLD$CYAN" "$PG_CRON_DB" "$RESET"
  psql_cron << 'JOBSQL' 2>/dev/null || warn "Could not read job execution history"
WITH job_runs AS (
  SELECT 
    j.jobid,
    j.jobname,
    d.start_time,
    d.status,
    ROW_NUMBER() OVER (PARTITION BY j.jobid ORDER BY d.start_time DESC) as run_rank
  FROM cron.job j
  LEFT JOIN cron.job_run_details d ON j.jobid = d.jobid
),
job_stats AS (
  SELECT 
    jobid,
    jobname,
    COUNT(*) FILTER (WHERE run_rank <= 10) as total_runs,
    COUNT(*) FILTER (WHERE run_rank <= 10 AND status = 'succeeded') as successful_runs,
    COUNT(*) FILTER (WHERE run_rank <= 10 AND status != 'succeeded') as failed_runs,
    ROUND(100.0 * COUNT(*) FILTER (WHERE run_rank <= 10 AND status = 'succeeded') / NULLIF(COUNT(*) FILTER (WHERE run_rank <= 10), 0), 1) as success_rate_pct,
    STRING_AGG(TO_CHAR(start_time, 'YYYY-MM-DD HH24:MI:SS'), E'\n  ' ORDER BY start_time DESC) FILTER (WHERE run_rank <= 10) as last_10_times
  FROM job_runs
  GROUP BY jobid, jobname
)
SELECT 
  jobid || '. ' || jobname || E'\n' ||
  '  Last 10 runs: ' || COALESCE(last_10_times, '(none)') || E'\n' ||
  '  Success rate: ' || COALESCE(successful_runs::text || '/' || total_runs::text || ' (' || success_rate_pct::text || '%)', '(no data)') ||
  CASE WHEN failed_runs > 0 THEN ' | Failures: ' || failed_runs::text ELSE '' END
FROM job_stats
ORDER BY jobid;
JOBSQL

  echo
  printf "%bLast 10 Job Executions (raw history, %s):%b\n" "$BOLD$CYAN" "$PG_CRON_DB" "$RESET"
  psql_cron -Atqc "SELECT start_time || ' | job ' || COALESCE(jobid::text,'-') || ' | ' || COALESCE(status,'-') || ' | ' || COALESCE(return_message,'-') FROM cron.job_run_details ORDER BY start_time DESC LIMIT 10;" 2>/dev/null || warn "Could not read cron.job_run_details"

  printf "\n%bVerification completed%b\n\n" "$BOLD$GREEN" "$RESET"
}

main "$@"
