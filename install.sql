-- pg_perf_schema install script
-- Version: 0.0.1
-- This script is intentionally idempotent where practical.

BEGIN;

CREATE SCHEMA IF NOT EXISTS performance_schema;

CREATE TABLE IF NOT EXISTS performance_schema.schema_version (
  version text PRIMARY KEY,
  installed_at timestamptz NOT NULL DEFAULT now(),
  notes text
);

INSERT INTO performance_schema.schema_version (version, notes)
VALUES ('0.0.1', 'Initial pg_perf_schema baseline install')
ON CONFLICT (version) DO NOTHING;

CREATE TABLE IF NOT EXISTS performance_schema.pg_stat_activity_history (
  sampled_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  datid oid,
  datname name,
  pid integer,
  leader_pid integer,
  usesysid oid,
  usename name,
  application_name text,
  client_addr inet,
  client_hostname text,
  client_port integer,
  backend_start timestamptz,
  xact_start timestamptz,
  query_start timestamptz,
  state_change timestamptz,
  wait_event_type text,
  wait_event text,
  state text,
  backend_xid xid,
  backend_xmin xid,
  query_id bigint,
  query text,
  backend_type text
);

CREATE TABLE IF NOT EXISTS performance_schema.pg_locks_history (
  sampled_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  locktype text,
  database oid,
  relation oid,
  relation_name text,
  page integer,
  tuple smallint,
  virtualxid text,
  transactionid xid,
  classid oid,
  objid oid,
  objsubid smallint,
  virtualtransaction text,
  pid integer,
  mode text,
  granted boolean,
  fastpath boolean,
  waitstart timestamptz
);

CREATE TABLE IF NOT EXISTS performance_schema.pg_stat_statements_history (
  sampled_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  row_data jsonb NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_pg_stat_activity_history_sampled_at
  ON performance_schema.pg_stat_activity_history (sampled_at);

CREATE INDEX IF NOT EXISTS idx_pg_locks_history_sampled_at
  ON performance_schema.pg_locks_history (sampled_at);

CREATE INDEX IF NOT EXISTS idx_pg_stat_statements_history_sampled_at
  ON performance_schema.pg_stat_statements_history (sampled_at);

CREATE INDEX IF NOT EXISTS idx_pg_stat_statements_history_queryid
  ON performance_schema.pg_stat_statements_history ((row_data ->> 'queryid'));

CREATE OR REPLACE FUNCTION performance_schema.snapshot_activity()
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  inserted_count bigint;
BEGIN
  INSERT INTO performance_schema.pg_stat_activity_history (
    sampled_at,
    datid,
    datname,
    pid,
    leader_pid,
    usesysid,
    usename,
    application_name,
    client_addr,
    client_hostname,
    client_port,
    backend_start,
    xact_start,
    query_start,
    state_change,
    wait_event_type,
    wait_event,
    state,
    backend_xid,
    backend_xmin,
    query_id,
    query,
    backend_type
  )
  SELECT
    clock_timestamp(),
    a.datid,
    a.datname,
    a.pid,
    a.leader_pid,
    a.usesysid,
    a.usename,
    a.application_name,
    a.client_addr,
    a.client_hostname,
    a.client_port,
    a.backend_start,
    a.xact_start,
    a.query_start,
    a.state_change,
    a.wait_event_type,
    a.wait_event,
    a.state,
    a.backend_xid,
    a.backend_xmin,
    a.query_id,
    a.query,
    a.backend_type
  FROM pg_stat_activity a
  WHERE a.pid <> pg_backend_pid();

  GET DIAGNOSTICS inserted_count = ROW_COUNT;
  RETURN inserted_count;
END;
$$;

CREATE OR REPLACE FUNCTION performance_schema.snapshot_locks()
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  inserted_count bigint;
BEGIN
  INSERT INTO performance_schema.pg_locks_history (
    sampled_at,
    locktype,
    database,
    relation,
    relation_name,
    page,
    tuple,
    virtualxid,
    transactionid,
    classid,
    objid,
    objsubid,
    virtualtransaction,
    pid,
    mode,
    granted,
    fastpath,
    waitstart
  )
  SELECT
    clock_timestamp(),
    l.locktype,
    l.database,
    l.relation,
    CASE
      WHEN l.relation IS NOT NULL THEN l.relation::regclass::text
      ELSE NULL
    END,
    l.page,
    l.tuple,
    l.virtualxid,
    l.transactionid,
    l.classid,
    l.objid,
    l.objsubid,
    l.virtualtransaction,
    l.pid,
    l.mode,
    l.granted,
    l.fastpath,
    l.waitstart
  FROM pg_locks l;

  GET DIAGNOSTICS inserted_count = ROW_COUNT;
  RETURN inserted_count;
END;
$$;

CREATE OR REPLACE FUNCTION performance_schema.snapshot_statements()
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  inserted_count bigint;
BEGIN
  INSERT INTO performance_schema.pg_stat_statements_history (sampled_at, row_data)
  SELECT clock_timestamp(), to_jsonb(s)
  FROM pg_stat_statements s;

  GET DIAGNOSTICS inserted_count = ROW_COUNT;
  RETURN inserted_count;
END;
$$;

CREATE OR REPLACE FUNCTION performance_schema.cleanup(retention interval DEFAULT interval '7 days')
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  deleted_total bigint := 0;
  deleted_rows bigint;
BEGIN
  DELETE FROM performance_schema.pg_stat_activity_history
  WHERE sampled_at < now() - retention;
  GET DIAGNOSTICS deleted_rows = ROW_COUNT;
  deleted_total := deleted_total + deleted_rows;

  DELETE FROM performance_schema.pg_locks_history
  WHERE sampled_at < now() - retention;
  GET DIAGNOSTICS deleted_rows = ROW_COUNT;
  deleted_total := deleted_total + deleted_rows;

  DELETE FROM performance_schema.pg_stat_statements_history
  WHERE sampled_at < now() - retention;
  GET DIAGNOSTICS deleted_rows = ROW_COUNT;
  deleted_total := deleted_total + deleted_rows;

  RETURN deleted_total;
END;
$$;

CREATE OR REPLACE VIEW performance_schema.current_schema_version AS
SELECT version, installed_at, notes
FROM performance_schema.schema_version
ORDER BY installed_at DESC;

CREATE OR REPLACE VIEW performance_schema.recent_activity AS
SELECT *
FROM performance_schema.pg_stat_activity_history
WHERE sampled_at >= now() - interval '15 minutes';

CREATE OR REPLACE VIEW performance_schema.recent_locks AS
SELECT *
FROM performance_schema.pg_locks_history
WHERE sampled_at >= now() - interval '15 minutes';

CREATE OR REPLACE VIEW performance_schema.statements_history_flat AS
SELECT
  sampled_at,
  (row_data ->> 'userid')::oid AS userid,
  (row_data ->> 'dbid')::oid AS dbid,
  NULLIF(row_data ->> 'queryid', '')::bigint AS queryid,
  row_data ->> 'query' AS query,
  COALESCE(
    NULLIF(row_data ->> 'total_exec_time', '')::double precision,
    NULLIF(row_data ->> 'total_time', '')::double precision
  ) AS total_exec_time,
  NULLIF(row_data ->> 'calls', '')::bigint AS calls,
  NULLIF(row_data ->> 'rows', '')::bigint AS rows
FROM performance_schema.pg_stat_statements_history;

COMMIT;
