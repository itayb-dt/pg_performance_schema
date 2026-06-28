#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION_FILE="$SCRIPT_DIR/VERSION"
INSTALL_SQL_DEFAULT="$SCRIPT_DIR/install.sql"
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
INSTALL_SQL="$INSTALL_SQL_DEFAULT"
PG_CRON_DB=""
AUTO_CONFIRM="false"
DRY_RUN="false"

info() { printf "%b[INFO]%b %s\n" "$CYAN" "$RESET" "$1"; }
success() { printf "%b[SUCCESS]%b %s\n" "$GREEN" "$RESET" "$1"; }
warn() { printf "%b[WARN]%b %s\n" "$YELLOW" "$RESET" "$1"; }
error() { printf "%b[ERROR]%b %s\n" "$RED" "$RESET" "$1" >&2; }

show_help() {
  cat <<EOF
Usage: ./install.sh [options]

Options:
  --db <connection>        Base PostgreSQL connection string/target.
  --pg-cron-db <name>      Database where pg_cron extension/jobs are managed.
  --admin-db <connection>  Admin connection for CREATE DATABASE checks.
  --install-sql <path>     Path to install SQL (default: ./install.sql).
  --yes                    Skip confirmation prompt.
  --dry-run                Print actions without applying changes.
  --version                Print version and exit.
  -h, --help               Show this help.

Notes:
  - Installation always targets hardcoded database: performance_schema_db.
  - pg_stat_statements is installed in performance_schema_db.
  - pg_cron is installed in --pg-cron-db (or performance_schema_db by default).
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

psql_install() {
  psql "$TARGET_DB_INSTALL" "$@"
}

psql_cron() {
  psql "$TARGET_DB_CRON" "$@"
}

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
      --install-sql)
        [[ $# -lt 2 ]] && { error "Missing value for --install-sql"; exit 1; }
        INSTALL_SQL="$2"
        shift 2
        ;;
      --yes)
        AUTO_CONFIRM="true"
        shift
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

confirm() {
  if [[ "$AUTO_CONFIRM" == "true" || "$DRY_RUN" == "true" ]]; then
    return 0
  fi
  printf "%bProceed with install? Type 'yes' or 'y':%b " "$BOLD$YELLOW" "$RESET"
  read -r answer
  answer="$(echo "$answer" | tr '[:upper:]' '[:lower:]')"
  [[ "$answer" == "yes" || "$answer" == "y" ]] || { warn "Aborted"; exit 0; }
}

ensure_database() {
  if [[ "$DRY_RUN" == "true" ]]; then
    info "[DRY-RUN] Would check/create database $INSTALL_DB_NAME"
    return 0
  fi

  if psql_admin -Atqc "SELECT 1 FROM pg_database WHERE datname = '$INSTALL_DB_NAME';" | grep -q 1; then
    success "Database $INSTALL_DB_NAME exists"
  else
    info "Creating database $INSTALL_DB_NAME"
    psql_admin -v ON_ERROR_STOP=1 -c "CREATE DATABASE $INSTALL_DB_NAME;" >/dev/null
    success "Created database $INSTALL_DB_NAME"
  fi
}

ensure_extensions() {
  if [[ "$DRY_RUN" == "true" ]]; then
    info "[DRY-RUN] Would check/create pg_stat_statements in $INSTALL_DB_NAME"
    info "[DRY-RUN] Would check/create pg_cron in $PG_CRON_DB"
    return 0
  fi

  local pgss_ver
  pgss_ver="$(psql_install -Atqc "SELECT extversion FROM pg_extension WHERE extname='pg_stat_statements';" 2>/dev/null || true)"
  if [[ -n "$pgss_ver" ]]; then
    info "Exists: pg_stat_statements ($pgss_ver)"
  else
    psql_install -v ON_ERROR_STOP=1 -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;" >/dev/null
    pgss_ver="$(psql_install -Atqc "SELECT extversion FROM pg_extension WHERE extname='pg_stat_statements';" 2>/dev/null || true)"
    success "Enabled pg_stat_statements (${pgss_ver:-unknown})"
  fi

  local pgcron_ver
  pgcron_ver="$(psql_cron -Atqc "SELECT extversion FROM pg_extension WHERE extname='pg_cron';" 2>/dev/null || true)"
  if [[ -n "$pgcron_ver" ]]; then
    info "Exists: pg_cron ($pgcron_ver) in $PG_CRON_DB"
  else
    if psql_cron -v ON_ERROR_STOP=1 -c "CREATE EXTENSION IF NOT EXISTS pg_cron;" >/dev/null 2>&1; then
      pgcron_ver="$(psql_cron -Atqc "SELECT extversion FROM pg_extension WHERE extname='pg_cron';" 2>/dev/null || true)"
      success "Enabled pg_cron (${pgcron_ver:-unknown}) in $PG_CRON_DB"
    else
      error "Failed to create pg_cron in $PG_CRON_DB"
      exit 1
    fi
  fi
}

run_install_sql() {
  if [[ "$DRY_RUN" == "true" ]]; then
    info "[DRY-RUN] Would execute $INSTALL_SQL in $INSTALL_DB_NAME"
    return 0
  fi

  [[ -f "$INSTALL_SQL" ]] || { error "Install SQL not found: $INSTALL_SQL"; exit 1; }
  psql_install -v ON_ERROR_STOP=1 -f "$INSTALL_SQL" >/dev/null
  success "Installed performance_schema objects"
}

ensure_jobs() {
  if [[ "$DRY_RUN" == "true" ]]; then
    info "[DRY-RUN] Would create/update default pg_cron jobs from $PG_CRON_DB"
    return 0
  fi

  local sql
  sql=$(cat <<EOF
DO \$\$
BEGIN
  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname='pg_perf_activity') THEN
    PERFORM cron.unschedule((SELECT jobid FROM cron.job WHERE jobname='pg_perf_activity' LIMIT 1));
  END IF;
  PERFORM cron.schedule_in_database('pg_perf_activity','* * * * *','SELECT performance_schema.snapshot_activity()','$INSTALL_DB_NAME');

  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname='pg_perf_statements') THEN
    PERFORM cron.unschedule((SELECT jobid FROM cron.job WHERE jobname='pg_perf_statements' LIMIT 1));
  END IF;
  PERFORM cron.schedule_in_database('pg_perf_statements','* * * * *','SELECT performance_schema.snapshot_statements()','$INSTALL_DB_NAME');

  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname='pg_perf_locks') THEN
    PERFORM cron.unschedule((SELECT jobid FROM cron.job WHERE jobname='pg_perf_locks' LIMIT 1));
  END IF;
  PERFORM cron.schedule_in_database('pg_perf_locks','* * * * *','SELECT performance_schema.snapshot_locks()','$INSTALL_DB_NAME');

  IF EXISTS (SELECT 1 FROM cron.job WHERE jobname='pg_perf_cleanup') THEN
    PERFORM cron.unschedule((SELECT jobid FROM cron.job WHERE jobname='pg_perf_cleanup' LIMIT 1));
  END IF;
  PERFORM cron.schedule_in_database('pg_perf_cleanup','0 * * * *','SELECT performance_schema.cleanup(retention => interval ''7 days'')','$INSTALL_DB_NAME');
END
\$\$;
EOF
)
  psql_cron -v ON_ERROR_STOP=1 -c "$sql" >/dev/null
  success "Ensured default pg_cron jobs"
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

  printf "\n%bInstall Script v%s%b\n" "$BOLD$CYAN" "$SCRIPT_VERSION" "$RESET"
  info "Install DB: $INSTALL_DB_NAME"
  info "pg_cron DB: $PG_CRON_DB"

  confirm
  ensure_database
  ensure_extensions
  run_install_sql
  ensure_jobs

  printf "\n%bInstallation finished successfully%b\n\n" "$BOLD$GREEN" "$RESET"
}

main "$@"
