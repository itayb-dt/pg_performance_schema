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

CREATE TABLE IF NOT EXISTS performance_schema.pg_wait_sampling_history (
  sampled_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  source_sampled_at timestamptz NOT NULL,
  pid integer,
  event_type text,
  event text,
  queryid bigint
);

CREATE TABLE IF NOT EXISTS performance_schema.pg_stat_database_history (
  sampled_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  datid oid,
  datname name,
  numbackends integer,
  xact_commit bigint,
  xact_rollback bigint,
  blks_read bigint,
  blks_hit bigint,
  tup_returned bigint,
  tup_fetched bigint,
  tup_inserted bigint,
  tup_updated bigint,
  tup_deleted bigint,
  conflicts bigint,
  temp_files bigint,
  temp_bytes bigint,
  deadlocks bigint,
  checksum_failures bigint,
  checksum_last_failure timestamptz,
  blk_read_time double precision,
  blk_write_time double precision,
  session_time double precision,
  active_time double precision,
  idle_in_transaction_time double precision,
  sessions bigint,
  sessions_abandoned bigint,
  sessions_fatal bigint,
  sessions_killed bigint,
  stats_reset timestamptz
);

CREATE INDEX IF NOT EXISTS idx_pg_stat_activity_history_sampled_at
  ON performance_schema.pg_stat_activity_history (sampled_at);

CREATE INDEX IF NOT EXISTS idx_pg_locks_history_sampled_at
  ON performance_schema.pg_locks_history (sampled_at);

CREATE INDEX IF NOT EXISTS idx_pg_stat_statements_history_sampled_at
  ON performance_schema.pg_stat_statements_history (sampled_at);

CREATE INDEX IF NOT EXISTS idx_pg_stat_statements_history_queryid
  ON performance_schema.pg_stat_statements_history ((row_data ->> 'queryid'));

CREATE UNIQUE INDEX IF NOT EXISTS idx_pg_wait_sampling_history_dedup
  ON performance_schema.pg_wait_sampling_history (
    source_sampled_at,
    pid,
    COALESCE(event_type, ''),
    COALESCE(event, ''),
    COALESCE(queryid, 0)
  );

CREATE INDEX IF NOT EXISTS idx_pg_wait_sampling_history_sampled_at
  ON performance_schema.pg_wait_sampling_history (sampled_at);

CREATE INDEX IF NOT EXISTS idx_pg_stat_database_history_sampled_at
  ON performance_schema.pg_stat_database_history (sampled_at);

CREATE INDEX IF NOT EXISTS idx_pg_stat_database_history_datid
  ON performance_schema.pg_stat_database_history (datid);

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

CREATE OR REPLACE FUNCTION performance_schema.snapshot_wait_samples()
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  inserted_count bigint;
  wait_schema text;
BEGIN
  SELECT n.nspname
  INTO wait_schema
  FROM pg_extension e
  JOIN pg_namespace n ON n.oid = e.extnamespace
  WHERE e.extname = 'pg_wait_sampling';

  IF wait_schema IS NULL THEN
    RETURN 0;
  END IF;

  EXECUTE format($sql$
    INSERT INTO performance_schema.pg_wait_sampling_history (
      sampled_at,
      source_sampled_at,
      pid,
      event_type,
      event,
      queryid
    )
    SELECT
      clock_timestamp(),
      h.ts,
      h.pid,
      h.event_type,
      h.event,
      h.queryid
    FROM %I.pg_wait_sampling_history AS h
    ON CONFLICT DO NOTHING
  $sql$, wait_schema);

  GET DIAGNOSTICS inserted_count = ROW_COUNT;
  RETURN inserted_count;
END;
$$;

CREATE OR REPLACE FUNCTION performance_schema.snapshot_stat_database_v13()
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  inserted_count bigint;
BEGIN
  EXECUTE $sql$
    INSERT INTO performance_schema.pg_stat_database_history (
      sampled_at,
      datid,
      datname,
      numbackends,
      xact_commit,
      xact_rollback,
      blks_read,
      blks_hit,
      tup_returned,
      tup_fetched,
      tup_inserted,
      tup_updated,
      tup_deleted,
      conflicts,
      temp_files,
      temp_bytes,
      deadlocks,
      checksum_failures,
      checksum_last_failure,
      blk_read_time,
      blk_write_time,
      session_time,
      active_time,
      idle_in_transaction_time,
      sessions,
      sessions_abandoned,
      sessions_fatal,
      sessions_killed,
      stats_reset
    )
    SELECT
      clock_timestamp(),
      s.datid,
      s.datname,
      s.numbackends,
      s.xact_commit,
      s.xact_rollback,
      s.blks_read,
      s.blks_hit,
      s.tup_returned,
      s.tup_fetched,
      s.tup_inserted,
      s.tup_updated,
      s.tup_deleted,
      s.conflicts,
      s.temp_files,
      s.temp_bytes,
      s.deadlocks,
      s.checksum_failures,
      s.checksum_last_failure,
      s.blk_read_time,
      s.blk_write_time,
      NULL::double precision,
      NULL::double precision,
      NULL::double precision,
      NULL::bigint,
      NULL::bigint,
      NULL::bigint,
      NULL::bigint,
      s.stats_reset
    FROM pg_stat_database AS s
  $sql$;

  GET DIAGNOSTICS inserted_count = ROW_COUNT;
  RETURN inserted_count;
END;
$$;

CREATE OR REPLACE FUNCTION performance_schema.snapshot_stat_database_v14()
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  inserted_count bigint;
BEGIN
  EXECUTE $sql$
    INSERT INTO performance_schema.pg_stat_database_history (
      sampled_at,
      datid,
      datname,
      numbackends,
      xact_commit,
      xact_rollback,
      blks_read,
      blks_hit,
      tup_returned,
      tup_fetched,
      tup_inserted,
      tup_updated,
      tup_deleted,
      conflicts,
      temp_files,
      temp_bytes,
      deadlocks,
      checksum_failures,
      checksum_last_failure,
      blk_read_time,
      blk_write_time,
      session_time,
      active_time,
      idle_in_transaction_time,
      sessions,
      sessions_abandoned,
      sessions_fatal,
      sessions_killed,
      stats_reset
    )
    SELECT
      clock_timestamp(),
      s.datid,
      s.datname,
      s.numbackends,
      s.xact_commit,
      s.xact_rollback,
      s.blks_read,
      s.blks_hit,
      s.tup_returned,
      s.tup_fetched,
      s.tup_inserted,
      s.tup_updated,
      s.tup_deleted,
      s.conflicts,
      s.temp_files,
      s.temp_bytes,
      s.deadlocks,
      s.checksum_failures,
      s.checksum_last_failure,
      s.blk_read_time,
      s.blk_write_time,
      s.session_time,
      s.active_time,
      s.idle_in_transaction_time,
      s.sessions,
      s.sessions_abandoned,
      s.sessions_fatal,
      s.sessions_killed,
      s.stats_reset
    FROM pg_stat_database AS s
  $sql$;

  GET DIAGNOSTICS inserted_count = ROW_COUNT;
  RETURN inserted_count;
END;
$$;

CREATE OR REPLACE FUNCTION performance_schema.snapshot_stat_database_v15()
RETURNS bigint
LANGUAGE plpgsql
AS $$
BEGIN
  RETURN performance_schema.snapshot_stat_database_v14();
END;
$$;

CREATE OR REPLACE FUNCTION performance_schema.snapshot_stat_database_v16()
RETURNS bigint
LANGUAGE plpgsql
AS $$
BEGIN
  RETURN performance_schema.snapshot_stat_database_v14();
END;
$$;

CREATE OR REPLACE FUNCTION performance_schema.snapshot_stat_database_v17()
RETURNS bigint
LANGUAGE plpgsql
AS $$
BEGIN
  RETURN performance_schema.snapshot_stat_database_v14();
END;
$$;

CREATE OR REPLACE FUNCTION performance_schema.snapshot_stat_database_v18()
RETURNS bigint
LANGUAGE plpgsql
AS $$
BEGIN
  RETURN performance_schema.snapshot_stat_database_v14();
END;
$$;

CREATE OR REPLACE FUNCTION performance_schema.snapshot_stat_database()
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  server_version_num integer;
BEGIN
  server_version_num := current_setting('server_version_num')::integer;

  IF server_version_num >= 180000 THEN
    RETURN performance_schema.snapshot_stat_database_v18();
  ELSIF server_version_num >= 170000 THEN
    RETURN performance_schema.snapshot_stat_database_v17();
  ELSIF server_version_num >= 160000 THEN
    RETURN performance_schema.snapshot_stat_database_v16();
  ELSIF server_version_num >= 150000 THEN
    RETURN performance_schema.snapshot_stat_database_v15();
  ELSIF server_version_num >= 140000 THEN
    RETURN performance_schema.snapshot_stat_database_v14();
  ELSE
    RETURN performance_schema.snapshot_stat_database_v13();
  END IF;
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

  DELETE FROM performance_schema.pg_wait_sampling_history
  WHERE sampled_at < now() - retention;
  GET DIAGNOSTICS deleted_rows = ROW_COUNT;
  deleted_total := deleted_total + deleted_rows;

  DELETE FROM performance_schema.pg_stat_database_history
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

CREATE OR REPLACE VIEW performance_schema.recent_wait_samples AS
SELECT *
FROM performance_schema.pg_wait_sampling_history
WHERE sampled_at >= now() - interval '15 minutes';

CREATE OR REPLACE VIEW performance_schema.recent_stat_database AS
SELECT *
FROM performance_schema.pg_stat_database_history
WHERE sampled_at >= now() - interval '15 minutes';

CREATE OR REPLACE VIEW performance_schema.stat_database_rates_1m AS
WITH ordered AS (
  SELECT
    sampled_at,
    datid,
    datname,
    LAG(sampled_at) OVER w AS prev_sampled_at,
    xact_commit,
    LAG(xact_commit) OVER w AS prev_xact_commit,
    xact_rollback,
    LAG(xact_rollback) OVER w AS prev_xact_rollback,
    blks_read,
    LAG(blks_read) OVER w AS prev_blks_read,
    blks_hit,
    LAG(blks_hit) OVER w AS prev_blks_hit,
    tup_returned,
    LAG(tup_returned) OVER w AS prev_tup_returned,
    tup_fetched,
    LAG(tup_fetched) OVER w AS prev_tup_fetched,
    tup_inserted,
    LAG(tup_inserted) OVER w AS prev_tup_inserted,
    tup_updated,
    LAG(tup_updated) OVER w AS prev_tup_updated,
    tup_deleted,
    LAG(tup_deleted) OVER w AS prev_tup_deleted,
    temp_files,
    LAG(temp_files) OVER w AS prev_temp_files,
    temp_bytes,
    LAG(temp_bytes) OVER w AS prev_temp_bytes,
    deadlocks,
    LAG(deadlocks) OVER w AS prev_deadlocks,
    blk_read_time,
    LAG(blk_read_time) OVER w AS prev_blk_read_time,
    blk_write_time,
    LAG(blk_write_time) OVER w AS prev_blk_write_time,
    session_time,
    LAG(session_time) OVER w AS prev_session_time,
    active_time,
    LAG(active_time) OVER w AS prev_active_time,
    idle_in_transaction_time,
    LAG(idle_in_transaction_time) OVER w AS prev_idle_in_transaction_time,
    sessions,
    LAG(sessions) OVER w AS prev_sessions,
    sessions_abandoned,
    LAG(sessions_abandoned) OVER w AS prev_sessions_abandoned,
    sessions_fatal,
    LAG(sessions_fatal) OVER w AS prev_sessions_fatal,
    sessions_killed,
    LAG(sessions_killed) OVER w AS prev_sessions_killed
  FROM performance_schema.pg_stat_database_history
  WINDOW w AS (PARTITION BY datid ORDER BY sampled_at)
),
deltas AS (
  SELECT
    sampled_at,
    datid,
    datname,
    prev_sampled_at,
    EXTRACT(EPOCH FROM sampled_at - prev_sampled_at) AS sample_interval_seconds,
    xact_commit - prev_xact_commit AS xact_commit_delta,
    xact_rollback - prev_xact_rollback AS xact_rollback_delta,
    blks_read - prev_blks_read AS blks_read_delta,
    blks_hit - prev_blks_hit AS blks_hit_delta,
    tup_returned - prev_tup_returned AS tup_returned_delta,
    tup_fetched - prev_tup_fetched AS tup_fetched_delta,
    tup_inserted - prev_tup_inserted AS tup_inserted_delta,
    tup_updated - prev_tup_updated AS tup_updated_delta,
    tup_deleted - prev_tup_deleted AS tup_deleted_delta,
    temp_files - prev_temp_files AS temp_files_delta,
    temp_bytes - prev_temp_bytes AS temp_bytes_delta,
    deadlocks - prev_deadlocks AS deadlocks_delta,
    blk_read_time - prev_blk_read_time AS blk_read_time_delta,
    blk_write_time - prev_blk_write_time AS blk_write_time_delta,
    session_time - prev_session_time AS session_time_delta,
    active_time - prev_active_time AS active_time_delta,
    idle_in_transaction_time - prev_idle_in_transaction_time AS idle_in_transaction_time_delta,
    sessions - prev_sessions AS sessions_delta,
    sessions_abandoned - prev_sessions_abandoned AS sessions_abandoned_delta,
    sessions_fatal - prev_sessions_fatal AS sessions_fatal_delta,
    sessions_killed - prev_sessions_killed AS sessions_killed_delta
  FROM ordered
)
SELECT
  sampled_at,
  datid,
  datname,
  sample_interval_seconds,
  xact_commit_delta,
  CASE WHEN xact_commit_delta >= 0 AND sample_interval_seconds > 0 THEN xact_commit_delta * 60.0 / sample_interval_seconds END AS xact_commit_per_minute,
  xact_rollback_delta,
  CASE WHEN xact_rollback_delta >= 0 AND sample_interval_seconds > 0 THEN xact_rollback_delta * 60.0 / sample_interval_seconds END AS xact_rollback_per_minute,
  blks_read_delta,
  CASE WHEN blks_read_delta >= 0 AND sample_interval_seconds > 0 THEN blks_read_delta * 60.0 / sample_interval_seconds END AS blks_read_per_minute,
  blks_hit_delta,
  CASE WHEN blks_hit_delta >= 0 AND sample_interval_seconds > 0 THEN blks_hit_delta * 60.0 / sample_interval_seconds END AS blks_hit_per_minute,
  tup_returned_delta,
  CASE WHEN tup_returned_delta >= 0 AND sample_interval_seconds > 0 THEN tup_returned_delta * 60.0 / sample_interval_seconds END AS tup_returned_per_minute,
  tup_fetched_delta,
  CASE WHEN tup_fetched_delta >= 0 AND sample_interval_seconds > 0 THEN tup_fetched_delta * 60.0 / sample_interval_seconds END AS tup_fetched_per_minute,
  tup_inserted_delta,
  CASE WHEN tup_inserted_delta >= 0 AND sample_interval_seconds > 0 THEN tup_inserted_delta * 60.0 / sample_interval_seconds END AS tup_inserted_per_minute,
  tup_updated_delta,
  CASE WHEN tup_updated_delta >= 0 AND sample_interval_seconds > 0 THEN tup_updated_delta * 60.0 / sample_interval_seconds END AS tup_updated_per_minute,
  tup_deleted_delta,
  CASE WHEN tup_deleted_delta >= 0 AND sample_interval_seconds > 0 THEN tup_deleted_delta * 60.0 / sample_interval_seconds END AS tup_deleted_per_minute,
  temp_files_delta,
  CASE WHEN temp_files_delta >= 0 AND sample_interval_seconds > 0 THEN temp_files_delta * 60.0 / sample_interval_seconds END AS temp_files_per_minute,
  temp_bytes_delta,
  CASE WHEN temp_bytes_delta >= 0 AND sample_interval_seconds > 0 THEN temp_bytes_delta * 60.0 / sample_interval_seconds END AS temp_bytes_per_minute,
  deadlocks_delta,
  CASE WHEN deadlocks_delta >= 0 AND sample_interval_seconds > 0 THEN deadlocks_delta * 60.0 / sample_interval_seconds END AS deadlocks_per_minute,
  blk_read_time_delta,
  CASE WHEN blk_read_time_delta >= 0 AND sample_interval_seconds > 0 THEN blk_read_time_delta * 60.0 / sample_interval_seconds END AS blk_read_time_per_minute,
  blk_write_time_delta,
  CASE WHEN blk_write_time_delta >= 0 AND sample_interval_seconds > 0 THEN blk_write_time_delta * 60.0 / sample_interval_seconds END AS blk_write_time_per_minute,
  session_time_delta,
  CASE WHEN session_time_delta >= 0 AND sample_interval_seconds > 0 THEN session_time_delta * 60.0 / sample_interval_seconds END AS session_time_per_minute,
  active_time_delta,
  CASE WHEN active_time_delta >= 0 AND sample_interval_seconds > 0 THEN active_time_delta * 60.0 / sample_interval_seconds END AS active_time_per_minute,
  idle_in_transaction_time_delta,
  CASE WHEN idle_in_transaction_time_delta >= 0 AND sample_interval_seconds > 0 THEN idle_in_transaction_time_delta * 60.0 / sample_interval_seconds END AS idle_in_transaction_time_per_minute,
  sessions_delta,
  CASE WHEN sessions_delta >= 0 AND sample_interval_seconds > 0 THEN sessions_delta * 60.0 / sample_interval_seconds END AS sessions_per_minute,
  sessions_abandoned_delta,
  CASE WHEN sessions_abandoned_delta >= 0 AND sample_interval_seconds > 0 THEN sessions_abandoned_delta * 60.0 / sample_interval_seconds END AS sessions_abandoned_per_minute,
  sessions_fatal_delta,
  CASE WHEN sessions_fatal_delta >= 0 AND sample_interval_seconds > 0 THEN sessions_fatal_delta * 60.0 / sample_interval_seconds END AS sessions_fatal_per_minute,
  sessions_killed_delta,
  CASE WHEN sessions_killed_delta >= 0 AND sample_interval_seconds > 0 THEN sessions_killed_delta * 60.0 / sample_interval_seconds END AS sessions_killed_per_minute
FROM deltas
WHERE prev_sampled_at IS NOT NULL
  AND sample_interval_seconds > 0;

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
