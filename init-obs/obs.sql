-- ═════════════════════════════════════════════════════════════════════════════
-- obs.sql  —  YugabyteDB Observability & Performance Diagnosis
--
-- Load the full file:  \i init-obs/obs.sql
-- Or paste individual blocks into an active ysqlsh session.
--
-- Prerequisites: setup.sql has run (postStartCommand), run-load.sh is active.
-- ═════════════════════════════════════════════════════════════════════════════

\c obs_demo

-- Ensure DocDB RPC columns are enabled for this session
SET yb_enable_pg_stat_statements_rpc_stats = true;

\echo ''
\echo '════════════════════════════════════════════════════════════════════'
\echo ' Part 1 — pg_stat_statements: DocDB-aware query statistics          '
\echo '════════════════════════════════════════════════════════════════════'

-- ── 1.1  Top queries by cumulative execution time ────────────────────────────
\echo '-- 1.1  Top queries by total execution time'
SELECT
    LEFT(query, 80)                            AS query_snippet,
    calls,
    ROUND(total_time::numeric,      2)         AS total_ms,
    ROUND(mean_time::numeric,       2)         AS mean_ms,
    ROUND(max_time::numeric,        2)         AS max_ms,
    ROUND(stddev_time::numeric,     2)         AS stddev_ms,
    rows
FROM pg_stat_statements
WHERE query NOT LIKE '%pg_stat_statements%'
  AND query NOT LIKE '%obs.sql%'
ORDER BY total_time DESC
LIMIT 10;

-- ── 1.2  DocDB scan-to-return ratio (the distributed full-scan signal) ───────
\echo '-- 1.2  DocDB RPC columns: scan vs return ratio reveals missing indexes'
SELECT
    LEFT(query, 70)                                   AS query_snippet,
    calls,
    ROUND(mean_time::numeric,         2)              AS mean_ms,
    docdb_read_rpcs,
    docdb_rows_scanned,
    docdb_rows_returned,
    CASE WHEN docdb_rows_returned > 0
         THEN ROUND(docdb_rows_scanned::numeric / docdb_rows_returned, 0)
         ELSE NULL
    END                                               AS scan_to_return_ratio,
    ROUND(docdb_wait_time::numeric,   2)              AS docdb_wait_ms
FROM pg_stat_statements
WHERE docdb_read_rpcs > 0
  AND query NOT LIKE '%pg_stat%'
ORDER BY docdb_rows_scanned DESC
LIMIT 10;

-- ── 1.3  P50 / P95 / P99 latency from the histogram ─────────────────────────
\echo '-- 1.3  Latency percentiles from yb_latency_histogram'
SELECT
    LEFT(query, 70)                                                   AS query_snippet,
    calls,
    ROUND(yb_get_percentile(yb_latency_histogram, 50)::numeric, 2)   AS p50_ms,
    ROUND(yb_get_percentile(yb_latency_histogram, 95)::numeric, 2)   AS p95_ms,
    ROUND(yb_get_percentile(yb_latency_histogram, 99)::numeric, 2)   AS p99_ms
FROM pg_stat_statements
WHERE yb_latency_histogram IS NOT NULL
  AND query NOT LIKE '%pg_stat%'
ORDER BY yb_get_percentile(yb_latency_histogram, 99) DESC NULLS LAST
LIMIT 10;

-- ── 1.4  Transaction conflict and read-restart retries ───────────────────────
\echo '-- 1.4  Retry stats: conflict_retries + read_restart_retries'
SELECT
    LEFT(query, 70)                                                        AS query_snippet,
    calls,
    conflict_retries,
    read_restart_retries,
    total_retries,
    ROUND((total_retries::float / NULLIF(calls, 0) * 100)::numeric, 2)    AS retry_pct
FROM pg_stat_statements
WHERE total_retries > 0
  AND query NOT LIKE '%pg_stat%'
ORDER BY total_retries DESC
LIMIT 10;


\echo ''
\echo '════════════════════════════════════════════════════════════════════'
\echo ' Part 2 — ASH: Active Session History — standalone                  '
\echo '════════════════════════════════════════════════════════════════════'

-- ── 2.1  Overall wait event distribution (last 15 minutes) ──────────────────
\echo '-- 2.1  Top wait events across all components (last 15 min)'
SELECT
    wait_event_component,
    wait_event_class,
    wait_event_type,
    wait_event,
    COUNT(*)                                              AS samples,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 1)  AS pct_total
FROM yb_active_session_history
WHERE sample_time >= current_timestamp - interval '15 minutes'
GROUP BY wait_event_component, wait_event_class, wait_event_type, wait_event
ORDER BY samples DESC
LIMIT 20;

-- ── 2.2  Wait distribution by component — YSQL vs YCQL vs TServer ───────────
\echo '-- 2.2  Wait event types per component'
SELECT
    wait_event_component,
    wait_event_type,
    COUNT(*)                                                                    AS samples,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (PARTITION BY wait_event_component), 1)
                                                                                AS pct_within_component
FROM yb_active_session_history
WHERE sample_time >= current_timestamp - interval '15 minutes'
GROUP BY wait_event_component, wait_event_type
ORDER BY wait_event_component, samples DESC;

-- ── 2.3  Activity timeline — 1-minute buckets ────────────────────────────────
\echo '-- 2.3  Activity timeline (1-min buckets, last 30 min)'
SELECT
    date_trunc('minute', sample_time)   AS minute,
    wait_event_component,
    wait_event_type,
    COUNT(*)                            AS samples
FROM yb_active_session_history
WHERE sample_time >= current_timestamp - interval '30 minutes'
GROUP BY minute, wait_event_component, wait_event_type
ORDER BY minute, samples DESC;

-- ── 2.4  Hot tablet detection (pure ASH, no joins) ───────────────────────────
\echo '-- 2.4  Hot tablets: top TServer tablet_id prefixes by sample count'
SELECT
    wait_event_aux        AS tablet_id_prefix,
    wait_event,
    COUNT(*)              AS samples
FROM yb_active_session_history
WHERE wait_event_component = 'TServer'
  AND wait_event_aux IS NOT NULL
  AND sample_time >= current_timestamp - interval '15 minutes'
GROUP BY wait_event_aux, wait_event
ORDER BY samples DESC
LIMIT 15;

-- ── 2.5  Background server task activity (fixed query IDs 1–12) ─────────────
\echo '-- 2.5  Background tasks: Raft, RocksDB, WAL, snapshots (query_id 1-12)'
SELECT
    CASE query_id
        WHEN 1  THEN 'WAL appender'
        WHEN 2  THEN 'Background flush'
        WHEN 3  THEN 'Background compaction'
        WHEN 4  THEN 'Raft consensus'
        WHEN 6  THEN 'WAL background sync'
        WHEN 7  THEN 'YSQL background workers'
        WHEN 8  THEN 'Remote bootstrap'
        WHEN 9  THEN 'Snapshot operations'
        WHEN 12 THEN 'xCluster poller'
        ELSE         'system query_id=' || query_id
    END                   AS background_task,
    wait_event_class,
    wait_event,
    wait_event_type,
    COUNT(*)              AS samples
FROM yb_active_session_history
WHERE query_id BETWEEN 1 AND 12
  AND sample_time >= current_timestamp - interval '15 minutes'
GROUP BY query_id, wait_event_class, wait_event, wait_event_type
ORDER BY samples DESC;

-- ── 2.6  ASH by client IP — which application sends the most load ────────────
\echo '-- 2.6  Load by client IP address'
SELECT
    client_node_ip,
    wait_event_component,
    COUNT(*)                                              AS samples,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 1)  AS pct_total
FROM yb_active_session_history
WHERE client_node_ip IS NOT NULL
  AND sample_time >= current_timestamp - interval '15 minutes'
GROUP BY client_node_ip, wait_event_component
ORDER BY samples DESC;

-- ── 2.7  Memory usage by session over time ───────────────────────────────────
\echo '-- 2.7  PSS memory per session (from ASH pss_mem_bytes)'
SELECT
    pid,
    MIN(sample_time)                                AS first_seen,
    MAX(sample_time)                                AS last_seen,
    ROUND(MAX(pss_mem_bytes) / 1024.0 / 1024, 2)   AS peak_mem_mb,
    ROUND(AVG(pss_mem_bytes) / 1024.0 / 1024, 2)   AS avg_mem_mb,
    COUNT(*)                                        AS samples
FROM yb_active_session_history
WHERE pss_mem_bytes > 0
  AND sample_time >= current_timestamp - interval '15 minutes'
GROUP BY pid
ORDER BY peak_mem_mb DESC
LIMIT 15;


\echo ''
\echo '════════════════════════════════════════════════════════════════════'
\echo ' Part 3 — ASH × pg_stat_statements: waits grouped by query          '
\echo '════════════════════════════════════════════════════════════════════'

-- ── 3.1  Wait events per normalized query ────────────────────────────────────
\echo '-- 3.1  Which wait events does each query drive?'
SELECT
    s.queryid,
    LEFT(s.query, 65)                                                         AS query_snippet,
    a.wait_event_component,
    a.wait_event_type,
    a.wait_event,
    COUNT(*)                                                                   AS ash_samples,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (PARTITION BY s.queryid), 1) AS pct_of_query
FROM yb_active_session_history a
JOIN pg_stat_statements s
  ON a.query_id = s.queryid
 AND s.dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
WHERE a.sample_time >= current_timestamp - interval '15 minutes'
GROUP BY s.queryid, s.query, a.wait_event_component, a.wait_event_type, a.wait_event
ORDER BY ash_samples DESC
LIMIT 25;

-- ── 3.2  Top queries by total ASH samples (most time in the database) ────────
\echo '-- 3.2  Queries ranked by total ASH time (correlates with query load)'
SELECT
    LEFT(s.query, 70)                  AS query_snippet,
    s.calls,
    ROUND(s.mean_time::numeric, 2)     AS mean_ms,
    COUNT(a.*)                         AS ash_samples,
    s.docdb_rows_scanned,
    s.docdb_rows_returned
FROM yb_active_session_history a
JOIN pg_stat_statements s
  ON a.query_id = s.queryid
 AND s.dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
WHERE a.sample_time >= current_timestamp - interval '15 minutes'
GROUP BY s.queryid, s.query, s.calls, s.mean_time, s.docdb_rows_scanned, s.docdb_rows_returned
ORDER BY ash_samples DESC
LIMIT 10;

-- ── 3.3  Wait event timeline per query (minute buckets) ──────────────────────
\echo '-- 3.3  Per-query wait event timeline'
SELECT
    date_trunc('minute', a.sample_time)   AS minute,
    LEFT(s.query, 50)                     AS query_snippet,
    a.wait_event,
    COUNT(*)                              AS samples
FROM yb_active_session_history a
JOIN pg_stat_statements s
  ON a.query_id = s.queryid
 AND s.dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
WHERE a.sample_time >= current_timestamp - interval '20 minutes'
GROUP BY minute, s.query, a.wait_event
ORDER BY minute, samples DESC
LIMIT 30;


\echo ''
\echo '════════════════════════════════════════════════════════════════════'
\echo ' Part 4 — ASH × yb_local_tablets: waits grouped by tablet/object    '
\echo '════════════════════════════════════════════════════════════════════'

-- ── 4.1  Hot tablets with table name (yb_local_tablets) ──────────────────────
\echo '-- 4.1  Hot tablets with table/partition metadata (local node tablets)'
SELECT
    lt.table_name,
    lt.namespace_name,
    lt.tablet_id,
    lt.state                                        AS tablet_state,
    a.wait_event,
    COUNT(*)                                        AS ash_samples
FROM yb_active_session_history a
JOIN yb_local_tablets lt
  ON a.wait_event_aux = SUBSTRING(lt.tablet_id, 1, 15)
WHERE a.wait_event_component = 'TServer'
  AND a.sample_time >= current_timestamp - interval '15 minutes'
GROUP BY lt.table_name, lt.namespace_name, lt.tablet_id, lt.state, a.wait_event
ORDER BY ash_samples DESC
LIMIT 20;

-- ── 4.2  Hot tablets with hash-range info (yb_tablet_metadata, cluster-wide) ─
\echo '-- 4.2  Hot tablets cluster-wide with hash range (yb_tablet_metadata)'
SELECT
    tm.relname                          AS table_name,
    tm.db_name,
    tm.tablet_id,
    tm.start_hash_code,
    tm.end_hash_code,
    tm.leader                           AS tablet_leader,
    a.wait_event,
    COUNT(*)                            AS ash_samples
FROM yb_active_session_history a
JOIN yb_tablet_metadata tm
  ON a.wait_event_aux = SUBSTRING(tm.tablet_id, 1, 15)
WHERE a.wait_event_component = 'TServer'
  AND a.sample_time >= current_timestamp - interval '15 minutes'
GROUP BY tm.relname, tm.db_name, tm.tablet_id,
         tm.start_hash_code, tm.end_hash_code, tm.leader, a.wait_event
ORDER BY ash_samples DESC
LIMIT 20;

-- ── 4.3  Samples per table — top tables by TServer activity ──────────────────
\echo '-- 4.3  Tables ranked by TServer ASH sample count'
SELECT
    lt.table_name,
    lt.namespace_name,
    COUNT(DISTINCT lt.tablet_id)        AS tablet_count,
    COUNT(*)                            AS ash_samples,
    STRING_AGG(DISTINCT a.wait_event, ', ' ORDER BY a.wait_event)
                                        AS wait_events_seen
FROM yb_active_session_history a
JOIN yb_local_tablets lt
  ON a.wait_event_aux = SUBSTRING(lt.tablet_id, 1, 15)
WHERE a.wait_event_component = 'TServer'
  AND a.sample_time >= current_timestamp - interval '15 minutes'
GROUP BY lt.table_name, lt.namespace_name
ORDER BY ash_samples DESC;


\echo ''
\echo '════════════════════════════════════════════════════════════════════'
\echo ' Part 5 — ASH × yb_servers(): waits grouped by cluster node         '
\echo '════════════════════════════════════════════════════════════════════'

-- ── 5.1  Wait event distribution per node ────────────────────────────────────
\echo '-- 5.1  Wait events per cluster node'
SELECT
    s.host,
    s.zone,
    s.node_type,
    a.wait_event_component,
    a.wait_event_type,
    a.wait_event,
    COUNT(*)                                                              AS ash_samples,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (PARTITION BY s.host), 1) AS pct_of_node
FROM yb_active_session_history a
JOIN yb_servers() s ON a.top_level_node_id = s.uuid::uuid
WHERE a.sample_time >= current_timestamp - interval '15 minutes'
GROUP BY s.host, s.zone, s.node_type,
         a.wait_event_component, a.wait_event_type, a.wait_event
ORDER BY ash_samples DESC;

-- ── 5.2  Total load per node (sample count as proxy for resource use) ─────────
\echo '-- 5.2  Load distribution across nodes'
SELECT
    s.host,
    s.zone,
    s.num_connections                               AS live_connections,
    COUNT(*)                                        AS ash_samples,
    ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 1) AS pct_cluster_total
FROM yb_active_session_history a
JOIN yb_servers() s ON a.top_level_node_id = s.uuid::uuid
WHERE a.sample_time >= current_timestamp - interval '15 minutes'
GROUP BY s.host, s.zone, s.num_connections
ORDER BY ash_samples DESC;

-- ── 5.3  Query wait breakdown per node ───────────────────────────────────────
\echo '-- 5.3  Per-node × per-query wait event breakdown'
SELECT
    sv.host,
    sv.zone,
    LEFT(st.query, 55)                  AS query_snippet,
    a.wait_event,
    COUNT(*)                            AS ash_samples
FROM yb_active_session_history a
JOIN yb_servers() sv      ON a.top_level_node_id = sv.uuid::uuid
JOIN pg_stat_statements st ON a.query_id = st.queryid
                           AND st.dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
WHERE a.sample_time >= current_timestamp - interval '15 minutes'
GROUP BY sv.host, sv.zone, st.query, a.wait_event
ORDER BY ash_samples DESC
LIMIT 20;


\echo ''
\echo '════════════════════════════════════════════════════════════════════'
\echo ' Part 6 — ASH × pg_stat_activity: waits grouped by session/PID      '
\echo '════════════════════════════════════════════════════════════════════'

-- ── 6.1  Wait events per live session ────────────────────────────────────────
\echo '-- 6.1  ASH samples per session (pid) with current pg_stat_activity state'
SELECT
    a.pid,
    sa.usename,
    sa.application_name,
    sa.state                                            AS current_state,
    sa.wait_event_type                                  AS current_wait_type,
    sa.wait_event                                       AS current_wait_event,
    ROUND(sa.allocated_mem_bytes / 1024.0 / 1024, 2)   AS alloc_mem_mb,
    a.wait_event_component                              AS ash_component,
    a.wait_event_type                                   AS ash_wait_type,
    a.wait_event                                        AS ash_wait_event,
    COUNT(*)                                            AS ash_samples
FROM yb_active_session_history a
LEFT JOIN pg_stat_activity sa ON a.pid = sa.pid
WHERE a.sample_time >= current_timestamp - interval '15 minutes'
  AND a.wait_event_component = 'YSQL'
GROUP BY a.pid, sa.usename, sa.application_name, sa.state,
         sa.wait_event_type, sa.wait_event, sa.allocated_mem_bytes,
         a.wait_event_component, a.wait_event_type, a.wait_event
ORDER BY ash_samples DESC
LIMIT 20;

-- ── 6.2  Long-running or idle-in-transaction sessions (pg_stat_activity) ─────
\echo '-- 6.2  Potentially problematic sessions from pg_stat_activity'
SELECT
    pid,
    usename,
    application_name,
    state,
    wait_event_type,
    wait_event,
    ROUND(allocated_mem_bytes / 1024.0 / 1024, 2)  AS alloc_mem_mb,
    now() - query_start                             AS query_age,
    now() - xact_start                              AS txn_age,
    LEFT(query, 70)                                 AS query_snippet
FROM pg_stat_activity
WHERE state != 'idle'
  AND pid != pg_backend_pid()
ORDER BY txn_age DESC NULLS LAST, query_age DESC NULLS LAST;

-- ── 6.3  Sessions that appear frequently in ASH (persistent load holders) ────
\echo '-- 6.3  Sessions with most ASH samples (persistent resource holders)'
SELECT
    a.pid,
    COUNT(DISTINCT date_trunc('minute', a.sample_time))  AS active_minutes,
    COUNT(*)                                             AS total_samples,
    STRING_AGG(DISTINCT a.wait_event, ', '
               ORDER BY a.wait_event)                    AS wait_events,
    MAX(a.pss_mem_bytes) / 1024 / 1024                  AS peak_mem_mb
FROM yb_active_session_history a
WHERE a.sample_time >= current_timestamp - interval '15 minutes'
GROUP BY a.pid
ORDER BY total_samples DESC
LIMIT 10;


\echo ''
\echo '════════════════════════════════════════════════════════════════════'
\echo ' Part 7 — ASH Trifecta: query × node × tablet in one query          '
\echo '════════════════════════════════════════════════════════════════════'

-- ── 7.1  Full cross-dimension view ───────────────────────────────────────────
\echo '-- 7.1  Trifecta: which query, on which node, on which tablet?'
SELECT
    LEFT(st.query, 50)                  AS query_snippet,
    sv.host                             AS node_host,
    sv.zone                             AS node_zone,
    lt.table_name,
    a.wait_event,
    COUNT(*)                            AS ash_samples
FROM yb_active_session_history a
LEFT JOIN pg_stat_statements st ON a.query_id = st.queryid
                                AND st.dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
LEFT JOIN yb_servers() sv       ON a.top_level_node_id = sv.uuid::uuid
LEFT JOIN yb_local_tablets lt   ON a.wait_event_aux = SUBSTRING(lt.tablet_id, 1, 15)
WHERE a.sample_time >= current_timestamp - interval '15 minutes'
GROUP BY st.query, sv.host, sv.zone, lt.table_name, a.wait_event
ORDER BY ash_samples DESC
LIMIT 25;

-- ── 7.2  Conflict hot-spots: which queries fight over which tablet ────────────
\echo '-- 7.2  Transaction conflict hot-spots: query × tablet'
SELECT
    LEFT(st.query, 60)      AS query_snippet,
    lt.table_name,
    lt.tablet_id,
    a.wait_event,
    COUNT(*)                AS conflict_samples
FROM yb_active_session_history a
JOIN pg_stat_statements st ON a.query_id = st.queryid
                           AND st.dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
JOIN yb_local_tablets lt   ON a.wait_event_aux = SUBSTRING(lt.tablet_id, 1, 15)
WHERE a.wait_event IN (
        'ConflictResolution_WaitOnConflictingTxns',
        'ConflictResolution_ResolveConficts',
        'LockedBatchEntry_Lock'
      )
  AND a.sample_time >= current_timestamp - interval '15 minutes'
GROUP BY st.query, lt.table_name, lt.tablet_id, a.wait_event
ORDER BY conflict_samples DESC
LIMIT 15;


\echo ''
\echo '════════════════════════════════════════════════════════════════════'
\echo ' Part 8 — EXPLAIN ANALYZE DIST: distributed plan inspection          '
\echo '════════════════════════════════════════════════════════════════════'

-- ── 8.1  Baseline: customer order lookup without index ────────────────────────
\echo '-- 8.1  EXPLAIN DIST before index — observe Storage Table Rows Scanned'
EXPLAIN (ANALYZE, DIST, FORMAT TEXT)
SELECT o.order_id, o.amount, o.status, p.name, p.category
FROM orders o
JOIN products p ON o.product_id = p.product_id
WHERE o.customer_id = 42
ORDER BY o.created_at DESC
LIMIT 20;

-- ── 8.2  Create covering index ────────────────────────────────────────────────
\echo '-- 8.2  Creating covering index on customer_id'
CREATE INDEX CONCURRENTLY IF NOT EXISTS
    idx_orders_customer_id
ON orders (customer_id)
INCLUDE (created_at, amount, status, product_id);

-- ── 8.3  After index ──────────────────────────────────────────────────────────
\echo '-- 8.3  EXPLAIN DIST after index — Storage Table Rows Scanned drops'
EXPLAIN (ANALYZE, DIST, FORMAT TEXT)
SELECT o.order_id, o.amount, o.status, p.name, p.category
FROM orders o
JOIN products p ON o.product_id = p.product_id
WHERE o.customer_id = 42
ORDER BY o.created_at DESC
LIMIT 20;

-- ── 8.4  Status aggregation without index ─────────────────────────────────────
\echo '-- 8.4  Status aggregation — full scan of 500k rows'
EXPLAIN (ANALYZE, DIST)
SELECT status, COUNT(*), ROUND(SUM(amount), 2)
FROM orders
WHERE status = 'pending'
GROUP BY status;

CREATE INDEX CONCURRENTLY IF NOT EXISTS
    idx_orders_status
ON orders (status) INCLUDE (amount);

\echo '-- 8.4b  After partial-covering index on status'
EXPLAIN (ANALYZE, DIST)
SELECT status, COUNT(*), ROUND(SUM(amount), 2)
FROM orders
WHERE status = 'pending'
GROUP BY status;


\echo ''
\echo '════════════════════════════════════════════════════════════════════'
\echo ' Part 9 — pg_locks: lock contention and yb_cancel_transaction        '
\echo '════════════════════════════════════════════════════════════════════'

-- ── 9.1  All current locks ────────────────────────────────────────────────────
\echo '-- 9.1  All locks (granted and waiting)'
SELECT
    pid,
    locktype,
    granted,
    mode,
    waitstart,
    waitend,
    ybdetails->>'transactionid'     AS yb_txn_id,
    ybdetails->>'tablet_id'         AS tablet_id,
    ybdetails->>'is_explicit'       AS is_explicit,
    ybdetails->>'blocked_by'        AS blocked_by
FROM pg_locks
ORDER BY granted, waitstart NULLS LAST;

-- ── 9.2  Blocked sessions ─────────────────────────────────────────────────────
\echo '-- 9.2  Sessions waiting on a lock (granted = false)'
SELECT
    pid,
    locktype,
    mode,
    ybdetails->>'transactionid'     AS waiting_txn_id,
    ybdetails->>'tablet_id'         AS tablet_id,
    ybdetails->>'blocked_by'        AS blocked_by_txn_ids,
    waitstart,
    now() - waitstart               AS wait_duration
FROM pg_locks
WHERE granted = false
ORDER BY waitstart;

-- ── 9.3  Blocking chain with query text ──────────────────────────────────────
\echo '-- 9.3  Blocking chain: blocked pid, blocking pid, both queries'
SELECT
    b.pid                              AS blocked_pid,
    LEFT(ba.query, 60)                 AS blocked_query,
    b.ybdetails->>'transactionid'      AS blocked_txn,
    b.ybdetails->>'blocked_by'         AS blocked_by,
    k.pid                              AS blocking_pid,
    LEFT(ka.query, 60)                 AS blocking_query,
    k.ybdetails->>'transactionid'      AS blocking_txn
FROM pg_locks b
JOIN pg_stat_activity ba ON b.pid = ba.pid
JOIN pg_locks k
  ON k.ybdetails->>'transactionid' =
     ANY(ARRAY(SELECT jsonb_array_elements_text(b.ybdetails->'blocked_by')))
JOIN pg_stat_activity ka ON k.pid = ka.pid
WHERE b.granted = false;

-- ── 9.4  Cancel a blocking transaction (replace uuid) ────────────────────────
-- SELECT yb_cancel_transaction('<uuid-from-above>');

-- ── 9.5  Lock contention signal in ASH ───────────────────────────────────────
\echo '-- 9.5  Lock contention in ASH (ConflictResolution events)'
SELECT
    wait_event,
    wait_event_aux    AS tablet_id_prefix,
    COUNT(*)          AS samples,
    MIN(sample_time)  AS first_seen,
    MAX(sample_time)  AS last_seen
FROM yb_active_session_history
WHERE wait_event IN (
        'ConflictResolution_WaitOnConflictingTxns',
        'ConflictResolution_ResolveConficts',
        'LockedBatchEntry_Lock',
        'YBTxnConflictBackoff'
      )
  AND sample_time >= current_timestamp - interval '15 minutes'
GROUP BY wait_event, wait_event_aux
ORDER BY samples DESC;


\echo ''
\echo '════════════════════════════════════════════════════════════════════'
\echo ' Part 10 — yb_query_diagnostics: full diagnostic bundle              '
\echo '════════════════════════════════════════════════════════════════════'

-- ── 10.1  Find the query ID to diagnose ──────────────────────────────────────
\echo '-- 10.1  Find queryid for the slow customer lookup'
SELECT queryid, LEFT(query, 70) AS query_snippet, calls,
       ROUND(mean_time::numeric, 2) AS mean_ms,
       docdb_rows_scanned
FROM pg_stat_statements
WHERE query LIKE '%customer_id%'
  AND query NOT LIKE '%pg_stat%'
ORDER BY mean_time DESC
LIMIT 5;

-- ── 10.2  Start a 60-second diagnostic bundle ─────────────────────────────────
-- Replace the queryid with the value from the query above.
-- \echo '-- 10.2  Start diagnostic bundle (replace queryid)'
-- SELECT yb_query_diagnostics(
--     query_id                   => <queryid>,
--     diagnostics_interval_sec   => 60,
--     explain_sample_rate        => 20,
--     explain_analyze            => true,
--     explain_dist               => true,
--     bind_var_query_min_duration_ms => 5
-- );

-- ── 10.3  Monitor bundle status ───────────────────────────────────────────────
\echo '-- 10.3  Bundle status and output folder'
SELECT query_id, start_time, diagnostics_interval_sec,
       explain_params, folder_path, state, status
FROM yb_query_diagnostics_status
ORDER BY start_time DESC;

-- ── 10.4  Cancel early if needed ─────────────────────────────────────────────
-- SELECT yb_cancel_query_diagnostics(query_id => <queryid>);


\echo ''
\echo '════════════════════════════════════════════════════════════════════'
\echo ' Part 11 — yb_terminated_queries: crash and OOM investigation        '
\echo '════════════════════════════════════════════════════════════════════'

\echo '-- 11.1  Queries terminated unexpectedly (OOM, SIGKILL, temp limit)'
SELECT
    databasename,
    backend_pid,
    LEFT(query_text, 80)    AS query_text,
    termination_reason,
    query_start_time,
    query_end_time,
    query_end_time - query_start_time AS duration
FROM yb_terminated_queries
ORDER BY query_end_time DESC
LIMIT 20;

\echo ''
\echo '═══════════════════════════════════════════════════════════════════════'
\echo ' Reference — useful views and wait event descriptions                  '
\echo '═══════════════════════════════════════════════════════════════════════'

-- ── Ref 1: All known wait events with descriptions ───────────────────────────
\echo '-- Ref 1: Wait event descriptions (yb_wait_event_desc)'
SELECT wait_event_component, wait_event_class, wait_event_type,
       wait_event, wait_event_description
FROM yb_wait_event_desc
ORDER BY wait_event_component, wait_event_class, wait_event;

-- ── Ref 2: Cluster topology ───────────────────────────────────────────────────
\echo '-- Ref 2: Cluster nodes (yb_servers)'
SELECT host, port, num_connections, node_type, cloud, region, zone, uuid
FROM yb_servers();

-- ── Ref 3: Column statistics for index decisions ──────────────────────────────
\echo '-- Ref 3: Column statistics — cardinality and common values'
SELECT attname, null_frac, n_distinct, most_common_vals, most_common_freqs
FROM pg_stats
WHERE tablename = 'orders'
ORDER BY attname;
