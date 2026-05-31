# Observability & Performance Diagnosis

[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/srinivasa-vasu/ybdb-vanguard?devcontainer_path=.devcontainer%2Finit-obs%2Fdevcontainer.json)

End-to-end performance investigation on a YugabyteDB 3-node cluster using the full built-in observability stack — no external agents or dashboards required. Every query in this exercise is plain SQL.

---

> **Run queries interactively**: Select any SQL block → **`Ctrl+Shift+Enter`** (Windows/Linux) or **`Cmd+Shift+Enter`** (Mac) → runs in the active terminal.

---

## What's covered

| Tool | What you learn |
|---|---|
| `pg_stat_statements` | `docdb_rows_scanned`, `yb_latency_histogram`, P50/P95/P99, retry counters |
| `yb_active_session_history` | ASH standalone: wait event distribution, timeline, hot tablets, background tasks |
| ASH × `pg_stat_statements` | Which queries drive which wait events |
| ASH × `yb_local_tablets` | Which table and tablet partition is hot |
| ASH × `yb_tablet_metadata` | Cluster-wide tablet distribution with hash ranges |
| ASH × `yb_servers()` | Which cluster node carries the load |
| ASH × `pg_stat_activity` | Which sessions are stuck and how much memory they hold |
| ASH trifecta | Query + node + tablet in a single cross-dimension query |
| `EXPLAIN (ANALYZE, DIST)` | Storage Table Rows Scanned, DocDB RPC breakdown |
| `pg_locks` + `yb_cancel_transaction()` | Distributed lock contention, cancel from any node |
| `yb_query_diagnostics` | Single-function diagnostic bundle: bind vars, plans, ASH, schema |
| `yb_terminated_queries` | Post-mortem on crashed or OOM-killed queries |

---

## Prerequisites

The devcontainer starts a **3-node cluster** with:
- `ysql_yb_enable_ash=true` (ASH at 500ms sampling)
- `ysql_yb_enable_query_diagnostics=true`

`setup.sql` runs automatically on every start — it creates `obs_demo`, seeds 500k orders, and configures `yb_enable_pg_stat_statements_rpc_stats`.

---

## Running the exercises

| Task | What it opens |
|---|---|
| **Terminal → Run Task → `run-load`** | Background query load generator — keep this running while exploring |
| **Terminal → Run Task → `ysql-obs`** | YSQL shell connected directly to `obs_demo` |
| **Terminal → Run Task → `obs-demo`** | Guided investigation demo (`prompt.sh`) |

**Start `run-load` first** — ASH and `pg_stat_statements` need sustained load to accumulate meaningful data.

Then open `obs.sql` in the `ysql-obs` shell:

```sql
\i init-obs/obs.sql
```

Or paste individual blocks from each part below.

---

## Part 1 · `pg_stat_statements` — DocDB-aware query statistics

### What makes it different from PostgreSQL

Standard Postgres columns like `shared_blks_hit` are **not populated** in YugabyteDB. Instead, YugabyteDB adds:

| Column | What it tells you |
|---|---|
| `docdb_rows_scanned` | Rows scanned at the DocDB (storage) layer |
| `docdb_rows_returned` | Rows sent back to YSQL — compare to scanned for full-scan signal |
| `docdb_read_rpcs` | RPC round trips for reads — high = many tablet fan-outs |
| `docdb_wait_time` | Wall-clock DocDB I/O wait time (ms) |
| `yb_latency_histogram` | JSONB histogram for P50/P95/P99 via `yb_get_percentile()` |
| `conflict_retries` | Retries due to transaction conflicts |
| `read_restart_retries` | Retries due to concurrent updates |

Enable the DocDB columns:
```sql
SET yb_enable_pg_stat_statements_rpc_stats = true;
```

Top queries by `docdb_rows_scanned / docdb_rows_returned` ratio (the distributed full-scan signal):
```sql
SELECT LEFT(query, 70) AS query, calls,
       docdb_rows_scanned, docdb_rows_returned,
       ROUND(docdb_rows_scanned::numeric / NULLIF(docdb_rows_returned, 0), 0) AS scan_ratio,
       ROUND(docdb_wait_time::numeric, 2) AS docdb_wait_ms
FROM pg_stat_statements
WHERE docdb_read_rpcs > 0
ORDER BY docdb_rows_scanned DESC LIMIT 10;
```

P99 latency from the histogram:
```sql
SELECT LEFT(query, 70) AS query, calls,
       ROUND(yb_get_percentile(yb_latency_histogram, 50)::numeric, 2) AS p50_ms,
       ROUND(yb_get_percentile(yb_latency_histogram, 95)::numeric, 2) AS p95_ms,
       ROUND(yb_get_percentile(yb_latency_histogram, 99)::numeric, 2) AS p99_ms
FROM pg_stat_statements
WHERE yb_latency_histogram IS NOT NULL
ORDER BY yb_get_percentile(yb_latency_histogram, 99) DESC NULLS LAST LIMIT 10;
```

---

## Part 2 · ASH standalone — `yb_active_session_history`

ASH samples active sessions every 500ms (configured). Each row represents one session in a wait state at that moment.

Key columns: `sample_time`, `wait_event_component` (YSQL/YCQL/TServer), `wait_event_class`, `wait_event_type`, `wait_event`, `wait_event_aux` (tablet ID prefix for TServer events), `query_id` (matches `pg_stat_statements.queryid`), `top_level_node_id` (node UUID), `pid`, `pss_mem_bytes`.

### 2.1 Overall wait distribution
```sql
SELECT wait_event_component, wait_event_class, wait_event_type, wait_event,
       COUNT(*) AS samples,
       ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 1) AS pct_total
FROM yb_active_session_history
WHERE sample_time >= current_timestamp - interval '15 minutes'
GROUP BY wait_event_component, wait_event_class, wait_event_type, wait_event
ORDER BY samples DESC LIMIT 20;
```

### 2.2 Activity timeline (1-minute buckets)
```sql
SELECT date_trunc('minute', sample_time) AS minute,
       wait_event_component, wait_event_type,
       COUNT(*) AS samples
FROM yb_active_session_history
WHERE sample_time >= current_timestamp - interval '30 minutes'
GROUP BY minute, wait_event_component, wait_event_type
ORDER BY minute, samples DESC;
```

### 2.3 Hot tablet detection — no joins needed
```sql
SELECT wait_event_aux AS tablet_id_prefix, wait_event,
       COUNT(*) AS samples
FROM yb_active_session_history
WHERE wait_event_component = 'TServer'
  AND wait_event_aux IS NOT NULL
  AND sample_time >= current_timestamp - interval '15 minutes'
GROUP BY wait_event_aux, wait_event
ORDER BY samples DESC LIMIT 15;
```

### 2.4 Background server tasks (fixed query IDs)
Query IDs 1–12 represent server background work, not user queries:

```sql
SELECT
    CASE query_id
        WHEN 1 THEN 'WAL appender'       WHEN 2 THEN 'Background flush'
        WHEN 3 THEN 'Background compaction' WHEN 4 THEN 'Raft consensus'
        WHEN 6 THEN 'WAL background sync'  WHEN 12 THEN 'xCluster poller'
        ELSE 'system query_id=' || query_id
    END AS background_task,
    wait_event, COUNT(*) AS samples
FROM yb_active_session_history
WHERE query_id BETWEEN 1 AND 12
  AND sample_time >= current_timestamp - interval '15 minutes'
GROUP BY query_id, wait_event ORDER BY samples DESC;
```

---

## Part 3 · ASH × `pg_stat_statements` — grouped by query

Join key: `yb_active_session_history.query_id = pg_stat_statements.queryid`

### Which wait events does each query drive?
```sql
SELECT s.queryid, LEFT(s.query, 60) AS query_snippet,
       a.wait_event_component, a.wait_event_type, a.wait_event,
       COUNT(*) AS ash_samples,
       ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (PARTITION BY s.queryid), 1) AS pct_of_query
FROM yb_active_session_history a
JOIN pg_stat_statements s ON a.query_id = s.queryid
WHERE a.sample_time >= current_timestamp - interval '15 minutes'
GROUP BY s.queryid, s.query, a.wait_event_component, a.wait_event_type, a.wait_event
ORDER BY ash_samples DESC LIMIT 20;
```

### Queries ranked by total ASH time
```sql
SELECT LEFT(s.query, 70) AS query, s.calls,
       ROUND(s.mean_time::numeric, 2) AS mean_ms,
       COUNT(a.*) AS ash_samples
FROM yb_active_session_history a
JOIN pg_stat_statements s ON a.query_id = s.queryid
WHERE a.sample_time >= current_timestamp - interval '15 minutes'
GROUP BY s.queryid, s.query, s.calls, s.mean_time
ORDER BY ash_samples DESC LIMIT 10;
```

---

## Part 4 · ASH × `yb_local_tablets` / `yb_tablet_metadata` — grouped by object

Join key: `wait_event_aux = SUBSTRING(tablet_id, 1, 15)`

`yb_local_tablets` — tablets on the **current node** only.
`yb_tablet_metadata` — tablets cluster-wide with hash range info.

### Hot tablets with table name (local node)
```sql
SELECT lt.table_name, lt.namespace_name, lt.tablet_id,
       a.wait_event, COUNT(*) AS ash_samples
FROM yb_active_session_history a
JOIN yb_local_tablets lt ON a.wait_event_aux = SUBSTRING(lt.tablet_id, 1, 15)
WHERE a.wait_event_component = 'TServer'
  AND a.sample_time >= current_timestamp - interval '15 minutes'
GROUP BY lt.table_name, lt.namespace_name, lt.tablet_id, a.wait_event
ORDER BY ash_samples DESC LIMIT 20;
```

### Hot tablets cluster-wide with hash range (yb_tablet_metadata)
```sql
SELECT tm.relname AS table_name, tm.tablet_id,
       tm.start_hash_code, tm.end_hash_code, tm.leader AS tablet_leader,
       a.wait_event, COUNT(*) AS ash_samples
FROM yb_active_session_history a
JOIN yb_tablet_metadata tm ON a.wait_event_aux = SUBSTRING(tm.tablet_id, 1, 15)
WHERE a.wait_event_component = 'TServer'
  AND a.sample_time >= current_timestamp - interval '15 minutes'
GROUP BY tm.relname, tm.tablet_id, tm.start_hash_code, tm.end_hash_code, tm.leader, a.wait_event
ORDER BY ash_samples DESC LIMIT 20;
```

---

## Part 5 · ASH × `yb_servers()` — grouped by node

Join key: `top_level_node_id = uuid::uuid`

```sql
SELECT s.host, s.zone, s.node_type,
       a.wait_event_component, a.wait_event_type,
       COUNT(*) AS ash_samples,
       ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (PARTITION BY s.host), 1) AS pct_of_node
FROM yb_active_session_history a
JOIN yb_servers() s ON a.top_level_node_id = s.uuid::uuid
WHERE a.sample_time >= current_timestamp - interval '15 minutes'
GROUP BY s.host, s.zone, s.node_type, a.wait_event_component, a.wait_event_type
ORDER BY ash_samples DESC;
```

---

## Part 6 · ASH × `pg_stat_activity` — grouped by session

Join key: `yb_active_session_history.pid = pg_stat_activity.pid`

```sql
SELECT a.pid, sa.usename, sa.application_name, sa.state AS current_state,
       ROUND(sa.allocated_mem_bytes / 1024.0 / 1024, 2) AS alloc_mem_mb,
       a.wait_event, COUNT(*) AS ash_samples
FROM yb_active_session_history a
LEFT JOIN pg_stat_activity sa ON a.pid = sa.pid
WHERE a.sample_time >= current_timestamp - interval '15 minutes'
  AND a.wait_event_component = 'YSQL'
GROUP BY a.pid, sa.usename, sa.application_name, sa.state,
         sa.allocated_mem_bytes, a.wait_event
ORDER BY ash_samples DESC LIMIT 20;
```

---

## Part 7 · ASH Trifecta — query × node × tablet

All three dimensions in a single query:

```sql
SELECT LEFT(st.query, 50) AS query_snippet,
       sv.host AS node, sv.zone,
       lt.table_name,
       a.wait_event,
       COUNT(*) AS ash_samples
FROM yb_active_session_history a
LEFT JOIN pg_stat_statements st ON a.query_id = st.queryid
LEFT JOIN yb_servers() sv       ON a.top_level_node_id = sv.uuid::uuid
LEFT JOIN yb_local_tablets lt   ON a.wait_event_aux = SUBSTRING(lt.tablet_id, 1, 15)
WHERE a.sample_time >= current_timestamp - interval '15 minutes'
GROUP BY st.query, sv.host, sv.zone, lt.table_name, a.wait_event
ORDER BY ash_samples DESC LIMIT 20;
```

---

## Key wait events to recognise

| Wait event | What it means |
|---|---|
| `TableRead` | YSQL waiting for a DocDB table read RPC |
| `IndexRead` | YSQL waiting for an index read RPC |
| `StorageFlush` | YSQL waiting for a combined read/write DocDB RPC |
| `OnCpu_Active` | Session actively using CPU |
| `ConflictResolution_WaitOnConflictingTxns` | Waiting for another transaction to commit or rollback |
| `LockedBatchEntry_Lock` | Waiting for a DocDB row-level lock |
| `MVCC_WaitForSafeTime` | Read waiting for safe MVCC timestamp |
| `WAL_Append` / `WAL_Sync` | Raft log write to disk |
| `Raft_WaitingForReplication` | Write waiting for quorum acknowledgement |
| `RocksDB_Compaction` | Background compaction consuming CPU/disk |

---

## Useful commands reference

```sql
-- Enable DocDB RPC stats for the current session
SET yb_enable_pg_stat_statements_rpc_stats = true;

-- Reset pg_stat_statements
SELECT pg_stat_statements_reset();

-- All wait event descriptions
SELECT * FROM yb_wait_event_desc ORDER BY wait_event_component, wait_event;

-- Cluster topology
SELECT host, zone, node_type, num_connections, uuid FROM yb_servers();

-- Cancel a blocking distributed transaction (works from any node)
SELECT yb_cancel_transaction('<uuid>');

-- Start a diagnostic bundle
SELECT yb_query_diagnostics(
    query_id => <queryid>, diagnostics_interval_sec => 60,
    explain_sample_rate => 20, explain_analyze => true,
    explain_dist => true, bind_var_query_min_duration_ms => 5
);

-- Check bundle status and output path
SELECT query_id, state, folder_path, status FROM yb_query_diagnostics_status;

-- Cancel a running bundle
SELECT yb_cancel_query_diagnostics(query_id => <queryid>);

-- Terminated/crashed queries
SELECT * FROM yb_terminated_queries ORDER BY query_end_time DESC LIMIT 20;
```
