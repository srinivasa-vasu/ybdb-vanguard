#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# YugabyteDB Observability demo  —  "The Case of the Disappearing SLA"
#
# An e-commerce order API started breaching its 200ms SLA. Engineering
# suspects the database. Walk through: pg_stat_statements → ASH by query →
# ASH by tablet → ASH by node → ASH by session → trifecta → EXPLAIN DIST
# → fix → ASH confirms recovery → diagnostic bundle.
#
# Pre-requisites (handled by postStartCommand + postCreateCommand):
#   - obs_demo database seeded with 500k orders
#   - run-load task running in a separate terminal (populates ASH + pg_stat)
#   - pscript (demo-magic) downloaded into this directory
# ─────────────────────────────────────────────────────────────────────────────

. pscript
set -f  # disable filename expansion — prevents SELECT * glob-expanding in eval $@

TYPE_SPEED=70
NO_WAIT=false
DEMO_PROMPT="${GREEN}➜ ${CYAN}obs_demo ${COLOR_RESET}"

DB="obs_demo"

clear

# ── Enable DocDB RPC stats for this session ───────────────────────────────────
ysqlsh -h 127.0.0.1 -d "$DB" -X -q -c "SET yb_enable_pg_stat_statements_rpc_stats = true;" 2>/dev/null

# ── Plant a lock scenario in background (for Parts 5 + 6) ────────────────────
# Holds a row lock for 90 seconds so we can observe it in ASH and pg_locks.
ysqlsh -h 127.0.0.1 -d "$DB" -X -q -c "
BEGIN;
UPDATE orders SET status = 'on_hold'
WHERE order_id = (SELECT MIN(order_id) FROM orders);
SELECT pg_sleep(90);
ROLLBACK;" &>/dev/null &

LOCK_PID=$!

# Wait for lock to be acquired, then start a conflicting session
sleep 2
ysqlsh -h 127.0.0.1 -d "$DB" -X -q -c "
BEGIN;
UPDATE orders SET status = 'on_hold'
WHERE order_id = (SELECT MIN(order_id) FROM orders);
ROLLBACK;" &>/dev/null &

# ── Scene 1: Situation ───────────────────────────────────────────────────────

p "=== 'The Case of the Disappearing SLA' ==="
p ""
p "Order API has breached its 200ms SLA for 10 minutes."
p "pg_stat_statements has been collecting query stats. Let's start there."

# ── Scene 2: pg_stat_statements — find the hotspot ───────────────────────────

p ""
p "--- Step 1: pg_stat_statements — top queries by total time ---"

pe "ysqlsh -h 127.0.0.1 -d ${DB} -X -c \"SELECT LEFT(query,70) AS query, calls, ROUND(mean_time::numeric,2) AS mean_ms, ROUND(max_time::numeric,2) AS max_ms FROM pg_stat_statements WHERE query NOT LIKE '%pg_stat%' ORDER BY total_time DESC LIMIT 6;\""

p "Customer-ID lookup and status aggregation are at the top."
p "But mean_ms alone doesn't tell us WHY. DocDB does."

pe "ysqlsh -h 127.0.0.1 -d ${DB} -X -c \"SELECT LEFT(query,60) AS query, calls, docdb_rows_scanned, docdb_rows_returned, CASE WHEN docdb_rows_returned>0 THEN ROUND(docdb_rows_scanned::numeric/docdb_rows_returned,0) END AS scan_ratio, ROUND(docdb_wait_time::numeric,1) AS docdb_wait_ms FROM pg_stat_statements WHERE docdb_read_rpcs>0 AND query NOT LIKE '%pg_stat%' ORDER BY docdb_rows_scanned DESC LIMIT 5;\""

p "scan_ratio = 24,000 — 24k rows scanned to return 20. That is a full tablet scan."

pe "ysqlsh -h 127.0.0.1 -d ${DB} -X -c \"SELECT LEFT(query,60) AS query, ROUND(yb_get_percentile(yb_latency_histogram,50)::numeric,2) AS p50_ms, ROUND(yb_get_percentile(yb_latency_histogram,95)::numeric,2) AS p95_ms, ROUND(yb_get_percentile(yb_latency_histogram,99)::numeric,2) AS p99_ms FROM pg_stat_statements WHERE query LIKE '%customer_id%' AND query NOT LIKE '%pg_stat%' LIMIT 3;\""

p "P99 >> P50. The tail is killing the SLA."

# ── Scene 3: ASH standalone — overall wait distribution ──────────────────────

p ""
p "--- Step 2: ASH standalone — what is the cluster waiting on? ---"

pe "ysqlsh -h 127.0.0.1 -d ${DB} -X -c \"SELECT wait_event_component, wait_event_type, wait_event, COUNT(*) AS samples, ROUND(COUNT(*)*100.0/SUM(COUNT(*)) OVER(),1) AS pct FROM yb_active_session_history WHERE sample_time >= current_timestamp - interval '5 minutes' GROUP BY wait_event_component, wait_event_type, wait_event ORDER BY samples DESC LIMIT 12;\""

p "TableRead dominates — DocDB row fetch RPCs from YSQL to TServer."
p "ConflictResolution also appears — lock contention is happening."

# ── Scene 4: ASH × pg_stat_statements — waits by query ──────────────────────

p ""
p "--- Step 3: ASH × pg_stat_statements — which queries drive which waits? ---"

pe "ysqlsh -h 127.0.0.1 -d ${DB} -X -c \"SELECT LEFT(s.query,55) AS query, a.wait_event, COUNT(*) AS samples, ROUND(COUNT(*)*100.0/SUM(COUNT(*)) OVER(PARTITION BY s.queryid),1) AS pct_of_query FROM yb_active_session_history a JOIN pg_stat_statements s ON a.query_id=s.queryid AND s.dbid=(SELECT oid FROM pg_database WHERE datname='${DB}') WHERE a.sample_time >= current_timestamp - interval '5 minutes' GROUP BY s.queryid,s.query,a.wait_event ORDER BY samples DESC LIMIT 10;\""

p "The customer lookup drives TableRead. The status aggregation drives StorageFlush."
p "Now let's find exactly WHICH tablets are suffering."

# ── Scene 5: ASH × yb_local_tablets — waits by tablet/object ────────────────

p ""
p "--- Step 4: ASH × yb_local_tablets — which table and partition is hot? ---"

pe "ysqlsh -h 127.0.0.1 -d ${DB} -X -c \"SELECT lt.table_name, lt.tablet_id, a.wait_event, COUNT(*) AS samples FROM yb_active_session_history a JOIN yb_local_tablets lt ON a.wait_event_aux = SUBSTRING(lt.tablet_id,1,15) WHERE a.wait_event_component='TServer' AND a.sample_time >= current_timestamp - interval '5 minutes' GROUP BY lt.table_name, lt.tablet_id, a.wait_event ORDER BY samples DESC LIMIT 10;\""

p "The orders table tablets are the hottest. Consistent with the missing index."
p "Let's see if the load is evenly spread or concentrated on one cluster node."

# ── Scene 6: ASH × yb_servers() — waits by node ─────────────────────────────

p ""
p "--- Step 5: ASH × yb_servers() — which node carries the load? ---"

pe "ysqlsh -h 127.0.0.1 -d ${DB} -X -c \"SELECT s.host, s.zone, a.wait_event_component, a.wait_event_type, COUNT(*) AS samples, ROUND(COUNT(*)*100.0/SUM(COUNT(*)) OVER(PARTITION BY s.host),1) AS pct_of_node FROM yb_active_session_history a JOIN yb_servers() s ON a.top_level_node_id=s.uuid::uuid WHERE a.sample_time >= current_timestamp - interval '5 minutes' GROUP BY s.host,s.zone,a.wait_event_component,a.wait_event_type ORDER BY samples DESC;\""

p "Load is distributed across all three nodes — consistent with hash-sharded orders."
p "Now let's look at sessions to confirm the lock contention we saw earlier."

# ── Scene 7: ASH × pg_stat_activity — waits by session ──────────────────────

p ""
p "--- Step 6: ASH × pg_stat_activity — which sessions are stuck? ---"

pe "ysqlsh -h 127.0.0.1 -d ${DB} -X -c \"SELECT a.pid, sa.state, a.wait_event, COUNT(*) AS ash_samples, ROUND(sa.allocated_mem_bytes/1024.0/1024,1) AS mem_mb FROM yb_active_session_history a LEFT JOIN pg_stat_activity sa ON a.pid=sa.pid WHERE a.sample_time >= current_timestamp - interval '5 minutes' AND a.wait_event_component='YSQL' GROUP BY a.pid,sa.state,a.wait_event,sa.allocated_mem_bytes ORDER BY ash_samples DESC LIMIT 8;\""

pe "ysqlsh -h 127.0.0.1 -d ${DB} -X -c \"SELECT pid, state, wait_event_type, wait_event, LEFT(query,60) AS query, now()-query_start AS query_age FROM pg_stat_activity WHERE state!='idle' AND pid!=pg_backend_pid() ORDER BY query_age DESC NULLS LAST;\""

# ── Scene 8: ASH trifecta ─────────────────────────────────────────────────────

p ""
p "--- Step 7: ASH trifecta — query × node × tablet in one shot ---"

pe "ysqlsh -h 127.0.0.1 -d ${DB} -X -c \"SELECT LEFT(st.query,45) AS query, sv.host AS node, lt.table_name, a.wait_event, COUNT(*) AS samples FROM yb_active_session_history a LEFT JOIN pg_stat_statements st ON a.query_id=st.queryid AND st.dbid=(SELECT oid FROM pg_database WHERE datname='${DB}') LEFT JOIN yb_servers() sv ON a.top_level_node_id=sv.uuid::uuid LEFT JOIN yb_local_tablets lt ON a.wait_event_aux=SUBSTRING(lt.tablet_id,1,15) WHERE a.sample_time >= current_timestamp - interval '5 minutes' GROUP BY st.query,sv.host,lt.table_name,a.wait_event ORDER BY samples DESC LIMIT 12;\""

p "Full picture: the customer lookup, on all three nodes, on the orders tablets."

# ── Scene 9: pg_locks — find the blocker ─────────────────────────────────────

p ""
p "--- Step 8: pg_locks — the lock contention we saw in ASH ---"

pe "ysqlsh -h 127.0.0.1 -d ${DB} -X -c \"SELECT pid, granted, mode, ybdetails->>'transactionid' AS txn_id, ybdetails->>'tablet_id' AS tablet_id, ybdetails->>'blocked_by' AS blocked_by, waitstart FROM pg_locks WHERE locktype='keyrange' ORDER BY granted;\""

BLOCKER_TXN=$(ysqlsh -h 127.0.0.1 -d "$DB" -X -t -q -c "
SELECT ybdetails->>'transactionid'
FROM pg_locks
WHERE granted = true
  AND ybdetails->>'blocked_by' IS NULL
  AND locktype = 'keyrange'
LIMIT 1;" 2>/dev/null | xargs)

if [ -n "$BLOCKER_TXN" ]; then
    p "Blocker transaction: ${BLOCKER_TXN}"
    p "Cancelling it with yb_cancel_transaction()..."
    pe "ysqlsh -h 127.0.0.1 -d ${DB} -X -c \"SELECT yb_cancel_transaction('${BLOCKER_TXN}');\""
    p "Blocker cancelled. Blocked session unblocked."
fi

# ── Scene 10: EXPLAIN ANALYZE DIST — confirm the root cause ──────────────────

p ""
p "--- Step 9: EXPLAIN ANALYZE DIST — confirm the full-scan root cause ---"

pe "ysqlsh -h 127.0.0.1 -d ${DB} -X -c \"EXPLAIN (ANALYZE, DIST) SELECT o.order_id, o.amount FROM orders o WHERE o.customer_id = 42 ORDER BY o.created_at DESC LIMIT 20;\""

p "Storage Table Rows Scanned >> 20. Seq Scan on orders confirmed."
p "Fix: covering index."

pe "ysqlsh -h 127.0.0.1 -d ${DB} -X -c \"CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_orders_customer_id ON orders (customer_id) INCLUDE (created_at, amount, status, product_id);\""

pe "ysqlsh -h 127.0.0.1 -d ${DB} -X -c \"EXPLAIN (ANALYZE, DIST) SELECT o.order_id, o.amount FROM orders o WHERE o.customer_id = 42 ORDER BY o.created_at DESC LIMIT 20;\""

p "Index Scan. Storage Table Rows Scanned drops to ~20. Problem solved."

# ── Scene 11: ASH after fix ───────────────────────────────────────────────────

p ""
p "--- Step 10: ASH after the fix — TableRead events should decrease ---"

sleep 10

pe "ysqlsh -h 127.0.0.1 -d ${DB} -X -c \"SELECT wait_event, COUNT(*) AS samples FROM yb_active_session_history WHERE sample_time >= current_timestamp - interval '3 minutes' AND wait_event_component='YSQL' GROUP BY wait_event ORDER BY samples DESC LIMIT 10;\""

p "TableRead sample count lower — the index eliminated the full-tablet scans."

# ── Scene 12: Capture diagnostic bundle ──────────────────────────────────────

p ""
p "--- Step 11: yb_query_diagnostics — capture bundle for the post-mortem ---"

QUERY_ID=$(ysqlsh -h 127.0.0.1 -d "$DB" -X -t -q -c "
SELECT queryid FROM pg_stat_statements
WHERE query LIKE '%customer_id%' AND query NOT LIKE '%pg_stat%'
ORDER BY mean_time DESC LIMIT 1;" 2>/dev/null | xargs)

if [ -n "$QUERY_ID" ]; then
    pe "ysqlsh -h 127.0.0.1 -d ${DB} -X -c \"SELECT yb_query_diagnostics(query_id => ${QUERY_ID}, diagnostics_interval_sec => 30, explain_sample_rate => 25, explain_analyze => true, explain_dist => true, bind_var_query_min_duration_ms => 5);\""

    sleep 5

    pe "ysqlsh -h 127.0.0.1 -d ${DB} -X -c \"SELECT query_id, state, folder_path, status FROM yb_query_diagnostics_status ORDER BY start_time DESC LIMIT 3;\""

    p "Bundle running. Output files in folder_path:"
    p "  constants_and_bind_variables.csv — actual parameter values"
    p "  explain_plan.txt                 — sampled EXPLAIN DIST plans"
    p "  active_session_history.csv       — ASH snapshot for the window"
    p "  pg_stat_statements.csv           — stats for this query"
    p "  schema_details.txt               — table + index definitions"
fi

# ── Wrap up ───────────────────────────────────────────────────────────────────

kill "$LOCK_PID" 2>/dev/null

p ""
p "=== Investigation complete ==="
p ""
p "Root causes:"
p "  1. Missing index on orders(customer_id) → 24k rows scanned per query"
p "  2. Lock contention on the orders table → ConflictResolution waits in ASH"
p ""
p "Tools used — all built into YugabyteDB, all SQL:"
p "  pg_stat_statements  — docdb_rows_scanned, yb_latency_histogram"
p "  yb_active_session_history  — standalone + × query + × tablet + × node"
p "  pg_stat_activity + pg_locks + yb_cancel_transaction"
p "  EXPLAIN (ANALYZE, DIST)  — Storage Table Rows Scanned"
p "  yb_query_diagnostics  — full diagnostic bundle"

cmd
p ""
