#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION_FILE="$SCRIPT_DIR/VERSION"
INSTALL_SQL_DEFAULT="$SCRIPT_DIR/install.sql"
INSTALL_DB_NAME="performance_schema_db"
DEFAULT_PG_CRON_DB=""

if [[ -f "$VERSION_FILE" ]]; then
  INSTALLER_VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
else
  INSTALLER_VERSION="0.0.1"
fi

SUPPORTED_PG_VERSIONS="13, 14, 15, 16, 17"

if command -v tput >/dev/null 2>&1 && [[ -n "${TERM:-}" ]] && [[ "${TERM:-}" != "dumb" ]]; then
  BOLD="$(tput bold)"
  RED="$(tput setaf 1)"
  GREEN="$(tput setaf 2)"
  YELLOW="$(tput setaf 3)"
  BLUE="$(tput setaf 4)"
  MAGENTA="$(tput setaf 5)"
  CYAN="$(tput setaf 6)"
  RESET="$(tput sgr0)"
else
  BOLD=""
  RED=""
  GREEN=""
  YELLOW=""
  BLUE=""
  MAGENTA=""
  CYAN=""
  RESET=""
fi

TARGET_DB=""
TARGET_DB_INSTALL=""
TARGET_DB_CRON=""
ADMIN_DB=""
INSTALL_SQL="$INSTALL_SQL_DEFAULT"
DRY_RUN="false"
AUTO_CONFIRM="false"
STATUS_ONLY="false"
PG_CRON_DB="$DEFAULT_PG_CRON_DB"

info() {
  printf "%b[INFO]%b %s\n" "$BLUE" "$RESET" "$1"
}

step() {
  printf "%b[STEP]%b %s\n" "$CYAN" "$RESET" "$1"
}

success() {
  printf "%b[SUCCESS]%b %s\n" "$GREEN" "$RESET" "$1"
}

warn() {
  printf "%b[WARN]%b %s\n" "$YELLOW" "$RESET" "$1"
}

error() {
  printf "%b[ERROR]%b %s\n" "$RED" "$RESET" "$1" >&2
}

show_banner() {
  printf "\n%bWelcome to Postgres Performance Schema Installer%b\n" "$BOLD$MAGENTA" "$RESET"
  printf "%bInstaller version:%b %s\n" "$BOLD" "$RESET" "$INSTALLER_VERSION"
  printf "%bSupported PostgreSQL versions:%b %s\n\n" "$BOLD" "$RESET" "$SUPPORTED_PG_VERSIONS"
}

show_help() {
  cat <<EOF
Usage: ./installer.sh [options]

Options:
  --db <connection>        PostgreSQL connection string or psql connection target.
  --pg-cron-db <name>      Database where pg_cron extension/jobs are managed.
  --status                 Read-only status report and exit.
  --admin-db <connection>  Admin connection used for CREATE DATABASE and checks.
  --yes                    Skip confirmation prompt.
  --install-sql <path>     Path to install.sql (default: ./install.sql).
  --dry-run                Print steps without executing SQL changes.
  --version                Print installer version and exit.
  -h, --help               Show this help message.

Examples:
  ./installer.sh
  ./installer.sh --db "postgresql://postgres:postgres@localhost:5432/defaultdb" --pg-cron-db defaultdb
  ./installer.sh --status --db "postgresql://postgres:postgres@localhost:5432/defaultdb" --pg-cron-db defaultdb
  ./installer.sh --status --db "postgresql://postgres:postgres@localhost:5432/postgres"
  ./installer.sh --db "postgresql://postgres:postgres@localhost:5432/postgres"
  ./installer.sh --db "service=mydb" --install-sql ./sql/install.sql
  ./installer.sh --dry-run
EOF
}

print_version_only() {
  echo "$INSTALLER_VERSION"
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
      --status)
        STATUS_ONLY="true"
        shift
        ;;
      --admin-db)
        [[ $# -lt 2 ]] && { error "Missing value for --admin-db"; exit 1; }
        ADMIN_DB="$2"
        shift 2
        ;;
      --yes)
        AUTO_CONFIRM="true"
        shift
        ;;
      --install-sql)
        [[ $# -lt 2 ]] && { error "Missing value for --install-sql"; exit 1; }
        INSTALL_SQL="$2"
        shift 2
        ;;
      --dry-run)
        DRY_RUN="true"
        shift
        ;;
      --version)
        print_version_only
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

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    error "Required command not found: $1"
    exit 1
  fi
}

psql_cmd() {
  if [[ -n "$TARGET_DB_INSTALL" ]]; then
    psql "$TARGET_DB_INSTALL" "$@"
  elif [[ -n "$TARGET_DB" ]]; then
    psql "$TARGET_DB" "$@"
  else
    psql "$@"
  fi
}

psql_cron_cmd() {
  if [[ -n "$TARGET_DB_CRON" ]]; then
    psql "$TARGET_DB_CRON" "$@"
  elif [[ -n "$TARGET_DB" ]]; then
    psql "$TARGET_DB" "$@"
  else
    psql "$@"
  fi
}

psql_admin_cmd() {
  if [[ -n "$ADMIN_DB" ]]; then
    psql "$ADMIN_DB" "$@"
  elif [[ -n "$TARGET_DB" ]]; then
    psql "$TARGET_DB" "$@"
  else
    psql "$@"
  fi
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

    local conn_out
    conn_out="${base%/*}/$target_db_name"
    if [[ -n "$query" ]]; then
      conn_out="$conn_out?$query"
    fi
    printf '%s\n' "$conn_out"
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

validate_runtime_options() {
  TARGET_DB_INSTALL="$(build_connection_for_db "$TARGET_DB" "$INSTALL_DB_NAME")"

  if [[ -z "$PG_CRON_DB" ]]; then
    PG_CRON_DB="$INSTALL_DB_NAME"
  fi

  TARGET_DB_CRON="$(build_connection_for_db "$TARGET_DB" "$PG_CRON_DB")"
}

show_execution_plan() {
  local planned_target

  planned_target="$TARGET_DB"
  if [[ -z "$planned_target" ]]; then
    planned_target="$INSTALL_DB_NAME"
  fi

  step "Execution Plan"
  printf "%bTarget database:%b %s (hardcoded)\n" "$BOLD$CYAN" "$RESET" "$INSTALL_DB_NAME"
  printf "%bpg_cron control DB:%b %s\n" "$BOLD$CYAN" "$RESET" "$PG_CRON_DB"
  printf "%bExtensions:%b pg_stat_statements (required), pg_cron (required for scheduler)\n" "$BOLD$CYAN" "$RESET"
  printf "%bSchema:%b performance_schema\n" "$BOLD$CYAN" "$RESET"
  printf "%bMonitoring:%b pg_stat_activity, pg_stat_statements, pg_locks, pg_stat_database, pg_wait_sampling (optional)\n" "$BOLD$CYAN" "$RESET"
}

print_status_report() {
  local db_name
  local db_exists
  local total_size
  local table_sql
  local job_sql
  local run_sql

  step "Status Report"

  if [[ "$DRY_RUN" == "true" ]]; then
    info "[DRY-RUN] Would collect status report"
    return 0
  fi

  if ! command -v psql >/dev/null 2>&1; then
    error "psql command not found"
    exit 1
  fi

  db_name="$INSTALL_DB_NAME"
  if ! psql_admin_cmd -Atqc "SELECT 1;" >/dev/null 2>&1; then
    error "Could not connect to PostgreSQL"
    exit 1
  fi

  printf "%bConnected database:%b %s\n" "$BOLD$CYAN" "$RESET" "$db_name"

  db_exists="$(psql_admin_cmd -Atqc "SELECT 1 FROM pg_database WHERE datname = '$db_name';" 2>/dev/null || true)"
  if [[ "$db_exists" == "1" ]]; then
    printf "%bDatabase exists:%b %bYes%b\n" "$BOLD$CYAN" "$RESET" "$GREEN" "$RESET"
  else
    printf "%bDatabase exists:%b %bNo%b\n" "$BOLD$CYAN" "$RESET" "$YELLOW" "$RESET"
  fi

  total_size="$(psql_admin_cmd -Atqc "SELECT pg_size_pretty(pg_database_size('$db_name'));" 2>/dev/null || true)"
  if [[ -n "$total_size" ]]; then
    printf "%bDatabase total size:%b %s\n" "$BOLD$CYAN" "$RESET" "$total_size"
  fi

  if [[ "$db_exists" != "1" ]]; then
    info "Database $db_name not found, skipping object and cron details"
    return 0
  fi

  step "Extensions (read-only)"
  report_extensions_read_only

  printf "\n%bManaged table sizes:%b\n" "$BOLD$CYAN" "$RESET"
  table_sql=$(cat <<'EOF'
SELECT c.relname || '|' || pg_size_pretty(pg_total_relation_size(c.oid))
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'performance_schema'
  AND c.relkind = 'r'
  AND c.relname IN (
    'schema_version',
    'pg_stat_activity_history',
    'pg_locks_history',
    'pg_stat_statements_history',
    'pg_stat_database_history',
    'pg_wait_sampling_history'
  )
ORDER BY c.relname;
EOF
)
  table_rows="$(psql_cmd -Atqc "$table_sql" 2>/dev/null || true)"
  if [[ -z "$table_rows" ]]; then
    info "No managed tables found in performance_schema"
  else
    while IFS='|' read -r tbl sz; do
      [[ -z "$tbl" ]] && continue
      printf "  - %s: %s\n" "$tbl" "$sz"
    done <<< "$table_rows"
  fi

  printf "\n%bCron jobs:%b\n" "$BOLD$CYAN" "$RESET"
  job_sql=$(cat <<'EOF'
SELECT jobid::text || '|' || jobname || '|' || schedule || '|' || command || '|' || CASE WHEN active THEN 'active' ELSE 'inactive' END
FROM cron.job
ORDER BY jobid;
EOF
)
  if psql_cron_cmd -Atqc "SELECT 1 FROM pg_extension WHERE extname = 'pg_cron';" >/dev/null 2>&1; then
    job_rows="$(psql_cron_cmd -Atqc "$job_sql" 2>/dev/null || true)"
    if [[ -z "$job_rows" ]]; then
      info "No cron jobs found"
    else
      while IFS='|' read -r jobid jobname schedule command state; do
        [[ -z "$jobid" ]] && continue
        printf "  - #%s [%s] %s (%s)\n" "$jobid" "$state" "$jobname" "$schedule"
      done <<< "$job_rows"
    fi
  else
    info "pg_cron extension not installed"
  fi

  printf "\n%bLast 10 cron runs:%b\n" "$BOLD$CYAN" "$RESET"
  run_sql=$(cat <<'EOF'
SELECT start_time::text || '|' || COALESCE(jobid::text, '-') || '|' || COALESCE(status, '-') || '|' || COALESCE(return_message, '-')
FROM cron.job_run_details
ORDER BY start_time DESC
LIMIT 10;
EOF
)
  if psql_cron_cmd -Atqc "SELECT 1 FROM pg_extension WHERE extname = 'pg_cron';" >/dev/null 2>&1 && psql_cron_cmd -Atqc "SELECT to_regclass('cron.job_run_details');" 2>/dev/null | grep -q "cron.job_run_details"; then
    run_rows="$(psql_cron_cmd -Atqc "$run_sql" 2>/dev/null || true)"
    if [[ -z "$run_rows" ]]; then
      info "No cron run history found"
    else
      while IFS='|' read -r started jobid status msg; do
        [[ -z "$started" ]] && continue
        printf "  - %s | job %s | %s | %s\n" "$started" "$jobid" "$status" "$msg"
      done <<< "$run_rows"
    fi
  else
    info "cron.job_run_details not available"
  fi
}

report_extensions_read_only() {
  local pgss_ver
  local pgcron_ver

  if [[ "$DRY_RUN" == "true" ]]; then
    info "[DRY-RUN] Would check extension pg_stat_statements and print version"
    info "[DRY-RUN] Would check extension pg_cron and print version"
    return 0
  fi

  pgss_ver="$(psql_cmd -Atqc "SELECT extversion FROM pg_extension WHERE extname = 'pg_stat_statements';" 2>/dev/null || true)"
  if [[ -n "$pgss_ver" ]]; then
    info "Exists: extension pg_stat_statements (version $pgss_ver)"
  else
    warn "Missing: extension pg_stat_statements"
  fi

  pgcron_ver="$(psql_cron_cmd -Atqc "SELECT extversion FROM pg_extension WHERE extname = 'pg_cron';" 2>/dev/null || true)"
  if [[ -n "$pgcron_ver" ]]; then
    info "Exists: extension pg_cron (version $pgcron_ver) in $PG_CRON_DB"
  else
    warn "Missing: extension pg_cron in $PG_CRON_DB"
  fi
}

confirm_plan() {
  if [[ "$DRY_RUN" == "true" || "$AUTO_CONFIRM" == "true" ]]; then
    return 0
  fi

  step "Confirmation"
  printf "%bProceed with the plan above? Type 'yes' or 'y' to continue:%b " "$BOLD$YELLOW" "$RESET"
  read -r answer
  answer_lower="$(echo "$answer" | tr '[:upper:]' '[:lower:]')"
  if [[ "$answer_lower" != "yes" && "$answer_lower" != "y" ]]; then
    warn "Installation aborted by user."
    exit 0
  fi
}

show_environment_versions() {
  if ! command -v psql >/dev/null 2>&1; then
    if [[ "$DRY_RUN" == "true" ]]; then
      info "psql not installed (OK for dry-run)"
      return 0
    fi
    error "psql command not found"
    exit 1
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    info "[DRY-RUN] Skipping connection test"
    return 0
  fi

  if server_ver="$(psql_admin_cmd -Atqc "SHOW server_version;" 2>/dev/null)"; then
    major_ver="${server_ver%%.*}"
    printf "%bConnecting to PostgreSQL:%b Version %b%s%b\n" "$BOLD$CYAN" "$RESET" "$BOLD$GREEN" "$server_ver" "$RESET"
    case "$major_ver" in
      13|14|15|16|17)
        success "Supported version"
        ;;
      *)
        warn "Version $major_ver may not be fully tested"
        ;;
    esac
  else
    error "Could not connect to PostgreSQL"
    exit 1
  fi
}

ensure_database_exists() {
  if [[ "$DRY_RUN" == "true" ]]; then
    info "[DRY-RUN] Would check/create database: $INSTALL_DB_NAME"
    return 0
  fi

  local check_sql
  check_sql="SELECT datname FROM pg_database WHERE datname = '$INSTALL_DB_NAME'"

  if db_exists="$(psql_admin_cmd -Atqc "$check_sql" 2>/dev/null)"; then
    if [[ -n "$db_exists" ]]; then
      printf "%bLooking for database %b%s%b:%b %bFound%b\n" "$BOLD$CYAN" "$BOLD$YELLOW" "$INSTALL_DB_NAME" "$RESET" "$BOLD$CYAN" "$BOLD$GREEN" "$RESET"
    else
      printf "%bLooking for database %b%s%b:%b %bNot found%b, creating...\n" "$BOLD$CYAN" "$BOLD$YELLOW" "$INSTALL_DB_NAME" "$RESET" "$BOLD$CYAN" "$BOLD$YELLOW" "$RESET"
      psql_admin_cmd -v ON_ERROR_STOP=1 -c "CREATE DATABASE $INSTALL_DB_NAME;" >/dev/null 2>&1
      success "Created database $INSTALL_DB_NAME"
    fi
  else
    warn "Could not check database"
    exit 1
  fi
}

report_existing_objects() {
  if [[ "$DRY_RUN" == "true" ]]; then
    info "[DRY-RUN] Would inspect existing objects"
    return 0
  fi

  local inventory_sql
  inventory_sql=$(cat <<'EOF'
SELECT kind || '|' || name
FROM (
  SELECT 'schema' AS kind, nspname AS name
  FROM pg_namespace
  WHERE nspname = 'performance_schema'

  UNION ALL

  SELECT 'table' AS kind, c.relname AS name
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'performance_schema'
    AND c.relkind = 'r'
    AND c.relname IN (
      'schema_version',
      'pg_stat_activity_history',
      'pg_locks_history',
      'pg_stat_statements_history',
      'pg_stat_database_history'
    )

  UNION ALL

  SELECT 'view' AS kind, c.relname AS name
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'performance_schema'
    AND c.relkind = 'v'
    AND c.relname IN (
      'current_schema_version',
      'recent_activity',
      'recent_locks',
      'recent_wait_samples',
      'recent_stat_database',
      'stat_database_rates_1m',
      'statements_history_flat'
    )

  UNION ALL

  SELECT 'function' AS kind, p.proname AS name
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'performance_schema'
    AND p.proname IN (
      'snapshot_activity',
      'snapshot_locks',
      'snapshot_statements',
      'snapshot_stat_database',
      'snapshot_stat_database_v13',
      'snapshot_stat_database_v14',
      'snapshot_stat_database_v15',
      'snapshot_stat_database_v16',
      'snapshot_stat_database_v17',
      'snapshot_stat_database_v18',
      'snapshot_wait_samples',
      'cleanup'
    )

  UNION ALL

  SELECT 'extension' AS kind, extname AS name
  FROM pg_extension
  WHERE extname IN ('pg_stat_statements', 'pg_cron')
) x
ORDER BY kind, name;
EOF
)

  local inventory_rows
  if ! inventory_rows="$(psql_cmd -Atqc "$inventory_sql" 2>/dev/null)"; then
    warn "Could not inspect existing objects"
    return 0
  fi

  if [[ -z "$inventory_rows" ]]; then
    info "No existing performance_schema objects detected"
    return 0
  fi

  step "Existing Objects"
  while IFS='|' read -r kind name; do
    [[ -z "$kind" || -z "$name" ]] && continue
    info "Exists: $kind $name"
  done <<< "$inventory_rows"
}

validate_inputs() {
  if [[ ! -f "$INSTALL_SQL" ]]; then
    if [[ "$DRY_RUN" == "true" ]]; then
      warn "install.sql not found (OK for dry-run)"
      return 0
    fi
    error "install.sql not found at: $INSTALL_SQL"
    exit 1
  fi
}

install_extensions() {
  if [[ "$DRY_RUN" == "true" ]]; then
    info "[DRY-RUN] Would check extension pg_stat_statements and print version"
    info "[DRY-RUN] Would check extension pg_cron and print version"
    return 0
  fi

  local has_pgss
  local pgss_ver
  info "Checking extension pg_stat_statements"
  has_pgss="$(psql_cmd -Atqc "SELECT extversion FROM pg_extension WHERE extname = 'pg_stat_statements';" 2>/dev/null || true)"
  if [[ -n "$has_pgss" ]]; then
    info "Exists: extension pg_stat_statements (version $has_pgss)"
  else
    psql_cmd -v ON_ERROR_STOP=1 -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;" >/dev/null 2>&1
    pgss_ver="$(psql_cmd -Atqc "SELECT extversion FROM pg_extension WHERE extname = 'pg_stat_statements';" 2>/dev/null || true)"
    if [[ -n "$pgss_ver" ]]; then
      success "pg_stat_statements enabled (version $pgss_ver)"
    else
      success "pg_stat_statements enabled"
    fi
  fi

  local has_pgcron
  local pgcron_ver
  info "Checking extension pg_cron"
  has_pgcron="$(psql_cron_cmd -Atqc "SELECT extversion FROM pg_extension WHERE extname = 'pg_cron';" 2>/dev/null || true)"
  if [[ -n "$has_pgcron" ]]; then
    info "Exists: extension pg_cron (version $has_pgcron)"
  elif psql_cron_cmd -v ON_ERROR_STOP=1 -c "CREATE EXTENSION IF NOT EXISTS pg_cron;" >/dev/null 2>&1; then
    pgcron_ver="$(psql_cron_cmd -Atqc "SELECT extversion FROM pg_extension WHERE extname = 'pg_cron';" 2>/dev/null || true)"
    if [[ -n "$pgcron_ver" ]]; then
      success "pg_cron enabled (version $pgcron_ver)"
    else
      success "pg_cron enabled"
    fi
  else
    error "Failed to create extension pg_cron"
    error "Check permissions/platform support (some managed PostgreSQL services do not allow pg_cron)."
    exit 1
  fi
}

run_install_sql() {
  if [[ "$DRY_RUN" == "true" ]]; then
    info "[DRY-RUN] Would execute install.sql"
    return 0
  fi

  psql_cmd -v ON_ERROR_STOP=1 -f "$INSTALL_SQL" >/dev/null 2>&1
  success "Schema and functions installed"
}

ensure_cron_jobs() {
  if [[ "$DRY_RUN" == "true" ]]; then
    info "[DRY-RUN] Would ensure pg_cron jobs (pg_perf_activity, pg_perf_statements, pg_perf_locks, pg_perf_database, pg_perf_wait_samples, pg_perf_cleanup)"
    return 0
  fi

  local jobs_sql
  jobs_sql=$(cat <<EOF
DO \\$\
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'pg_perf_activity') THEN
    PERFORM cron.unschedule((SELECT jobid FROM cron.job WHERE jobname = 'pg_perf_activity' LIMIT 1));
  END IF;
  PERFORM cron.schedule_in_database('pg_perf_activity', '* * * * *', 'SELECT performance_schema.snapshot_activity()', '$INSTALL_DB_NAME');

  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'pg_perf_statements') THEN
    PERFORM cron.unschedule((SELECT jobid FROM cron.job WHERE jobname = 'pg_perf_statements' LIMIT 1));
  END IF;
  PERFORM cron.schedule_in_database('pg_perf_statements', '* * * * *', 'SELECT performance_schema.snapshot_statements()', '$INSTALL_DB_NAME');

  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'pg_perf_locks') THEN
    PERFORM cron.unschedule((SELECT jobid FROM cron.job WHERE jobname = 'pg_perf_locks' LIMIT 1));
  END IF;
  PERFORM cron.schedule_in_database('pg_perf_locks', '* * * * *', 'SELECT performance_schema.snapshot_locks()', '$INSTALL_DB_NAME');

  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'pg_perf_database') THEN
    PERFORM cron.unschedule((SELECT jobid FROM cron.job WHERE jobname = 'pg_perf_database' LIMIT 1));
  END IF;
  PERFORM cron.schedule_in_database('pg_perf_database', '* * * * *', 'SELECT performance_schema.snapshot_stat_database()', '$INSTALL_DB_NAME');

  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'pg_perf_wait_samples') THEN
    PERFORM cron.unschedule((SELECT jobid FROM cron.job WHERE jobname = 'pg_perf_wait_samples' LIMIT 1));
  END IF;
  PERFORM cron.schedule_in_database('pg_perf_wait_samples', '* * * * *', 'SELECT performance_schema.snapshot_wait_samples()', '$INSTALL_DB_NAME');

  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'pg_perf_cleanup') THEN
    PERFORM cron.unschedule((SELECT jobid FROM cron.job WHERE jobname = 'pg_perf_cleanup' LIMIT 1));
  END IF;
  PERFORM cron.schedule_in_database('pg_perf_cleanup', '0 * * * *', 'SELECT performance_schema.cleanup(retention => interval ''7 days'')', '$INSTALL_DB_NAME');
END
\$;
EOF
)

  psql_cron_cmd -v ON_ERROR_STOP=1 -c "$jobs_sql" >/dev/null 2>&1
  success "pg_cron jobs ensured"
}

print_next_steps() {
  cat <<EOF

${BOLD}${GREEN}✓ Installation complete${RESET}

${BOLD}Next steps:${RESET}
  1. Default pg_cron jobs were created from '$PG_CRON_DB' into '$INSTALL_DB_NAME':
     SELECT cron.schedule_in_database('pg_perf_activity',  '* * * * *', 'SELECT performance_schema.snapshot_activity()', '$INSTALL_DB_NAME');
     SELECT cron.schedule_in_database('pg_perf_statements','* * * * *', 'SELECT performance_schema.snapshot_statements()', '$INSTALL_DB_NAME');
     SELECT cron.schedule_in_database('pg_perf_locks',     '* * * * *', 'SELECT performance_schema.snapshot_locks()', '$INSTALL_DB_NAME');
      SELECT cron.schedule_in_database('pg_perf_database',  '* * * * *', 'SELECT performance_schema.snapshot_stat_database()', '$INSTALL_DB_NAME');
      SELECT cron.schedule_in_database('pg_perf_wait_samples','* * * * *', 'SELECT performance_schema.snapshot_wait_samples()', '$INSTALL_DB_NAME');
     SELECT cron.schedule_in_database('pg_perf_cleanup',   '0 * * * *', 'SELECT performance_schema.cleanup(retention => interval ''7 days'')', '$INSTALL_DB_NAME');

  2. Query history from performance_schema schema.
EOF
}

main() {
  parse_args "$@"
  show_banner
  validate_runtime_options

  if [[ "$STATUS_ONLY" == "true" ]]; then
    print_status_report
    printf "\n%bStatus check completed%b\n\n" "$BOLD$GREEN" "$RESET"
    exit 0
  fi

  show_execution_plan
  confirm_plan
  show_environment_versions
  ensure_database_exists
  report_existing_objects
  validate_inputs
  install_extensions
  run_install_sql
  ensure_cron_jobs
  print_next_steps

  printf "\n%bInstaller v%s completed successfully%b\n\n" "$BOLD$GREEN" "$INSTALLER_VERSION" "$RESET"
}

main "$@"