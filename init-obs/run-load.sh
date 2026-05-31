#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# run-load.sh  —  background query load generator
#
# Runs slow queries against obs_demo in a continuous loop so that
# pg_stat_statements and ASH (yb_active_session_history) accumulate
# meaningful data for the observability exercises.
#
# Leave this running in its own terminal while you explore obs.sql or
# the guided demo in prompt.sh.
# ─────────────────────────────────────────────────────────────────────────────

DB="obs_demo"
TOTAL=0

echo "🔄 Load generator running against ${DB}"
echo "   Press Ctrl+C to stop."
echo ""

_q() {
  ysqlsh -d "$DB" -X -q -c "$1" 2>/dev/null
}

while true; do
    # ── Slow query 1: customer order lookup — no index on customer_id ──────
    # High docdb_rows_scanned, high DocDB RPC latency → shows in pg_stat_statements
    _q "SELECT o.order_id, o.amount, o.status, p.name, p.category
        FROM orders o JOIN products p ON o.product_id = p.product_id
        WHERE o.customer_id = $((RANDOM % 100 + 1))
        ORDER BY o.created_at DESC LIMIT 20;"

    # ── Slow query 2: status filter aggregation — no index on status ───────
    # Full scan of 500k rows → creates heavy TServer TableRead wait events
    _q "SELECT status, COUNT(*) AS cnt, ROUND(SUM(amount), 2) AS total
        FROM orders
        WHERE status = 'pending'
        GROUP BY status;"

    # ── Fast query: PK lookup — for contrast in pg_stat_statements ─────────
    _q "SELECT * FROM products WHERE product_id = $((RANDOM % 1000 + 1));"

    # ── Join query: region revenue — exercises BNL and tablet fan-out ──────
    _q "SELECT c.region, COUNT(*) AS orders, ROUND(SUM(o.amount), 2) AS revenue
        FROM orders o JOIN customers c ON o.customer_id = c.customer_id
        WHERE o.created_at >= now() - interval '30 days'
        GROUP BY c.region ORDER BY revenue DESC;"

    TOTAL=$((TOTAL + 4))
    printf "\r   %6d queries sent   (Ctrl+C to stop)" "$TOTAL"
done
