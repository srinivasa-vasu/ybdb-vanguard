#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# YugabyteDB Query Tuning demo  —  "The Performance Tuning Playbook"
#
# Full query optimisation stack on the Chinook music database:
# storage-layer pushdowns, index strategies, join optimisation, advanced SQL.
#
#   Part 1 · Query Execution Patterns — point lookup, range scan, ORDER BY, keyset
#   Part 2 · Pushdown Operations      — aggregate, expression pushdown
#   Part 3 · Index Strategies         — hash, covering, partial
#   Part 4 · Join Optimisation        — Batch Nested Loop batch size
#   Part 5 · Advanced SQL             — window functions, recursive CTE, materialised view
#
# Pre-requisites (handled by postStartCommand):
#   - 3-node YugabyteDB cluster running on 127.0.0.1:5433
# ─────────────────────────────────────────────────────────────────────────────

. pscript
set -f  # disable filename expansion — prevents SELECT * glob-expanding in eval $@

TYPE_SPEED=70
NO_WAIT=false
DEMO_PROMPT="${GREEN}➜ ${CYAN}\W ${COLOR_RESET}"

run_cmd "ysqlsh -h 127.0.0.1 -X -c \"alter role yugabyte set enable_seqscan=off; analyze verbose; \""

clear

# ── Scene 1: Seed the Chinook database ────────────────────────────────────

p "=== YugabyteDB Query Tuning: The Performance Tuning Playbook ==="
p ""
p "Chinook music database: artist(200) album(400) track(3000) customer(60) invoice(412)"
p "Loading seed data..."

pe "ysqlsh -h 127.0.0.1 -X -f tuning.sql"

p ""
p "EXPLAIN flag: EXPLAIN (ANALYZE, DIST, COSTS ON, BUFFERS OFF)"
p "'Storage Table Read Requests' = tablet round-trips — the cost metric for distributed queries."

# ── Scene 2: Query Execution Patterns ─────────────────────────────────────

p ""
p "=== Part 1: Query Execution Patterns ==="
p ""
p "-- 1.1 Point lookup"
p "Hash PK: hash(trackid) → 1 tablet → 1 RPC. O(1) regardless of table size."

pe "ysqlsh -h 127.0.0.1 -X -c \"EXPLAIN (ANALYZE, DIST) SELECT * FROM track WHERE trackid = 42;\""

p ""
p "-- 1.2 Range scan vs full scan"
p "No index on unitprice: Seq Scan across all tablets (high Rows Scanned vs returned)."

pe "ysqlsh -h 127.0.0.1 -X -c \"EXPLAIN (ANALYZE, DIST) SELECT * FROM track WHERE unitprice > 0.99;\""

pe "ysqlsh -h 127.0.0.1 -X -c \"CREATE INDEX IF NOT EXISTS idx_track_price ON track (unitprice ASC);\""

p ""
p "Range index: scan touches only relevant tablets (Rows Scanned ≈ Rows Returned):"

pe "ysqlsh -h 127.0.0.1 -X -c \"EXPLAIN (ANALYZE, DIST) SELECT * FROM track WHERE unitprice > 0.99;\""

p ""
p "-- 1.3 ORDER BY: hash penalty vs range benefit"
p "Hash PK: scatter all tablets + Sort node. Range index: streaming scan, no Sort."

pe "ysqlsh -h 127.0.0.1 -X -c \"EXPLAIN (ANALYZE, DIST) SELECT * FROM track ORDER BY trackid ASC LIMIT 10;\""

pe "ysqlsh -h 127.0.0.1 -X -c \"CREATE INDEX IF NOT EXISTS idx_invoice_date ON invoice (invoicedate ASC);\""

pe "ysqlsh -h 127.0.0.1 -X -c \"EXPLAIN (ANALYZE, DIST) SELECT * FROM invoice ORDER BY invoicedate ASC LIMIT 10;\""

p ""
p "-- 1.4 Keyset pagination vs OFFSET"
p "OFFSET N reads and discards N rows — O(OFFSET). Keyset cursor is always O(log N)."

pe "ysqlsh -h 127.0.0.1 -X -c \"EXPLAIN (ANALYZE, DIST) SELECT invoiceid, invoicedate, total FROM invoice ORDER BY invoicedate ASC, invoiceid ASC LIMIT 10 OFFSET 200;\""

p ""
p "Keyset: pass last page's values as cursor — Rows Scanned ≈ LIMIT:"

pe "ysqlsh -h 127.0.0.1 -X -c \"EXPLAIN (ANALYZE, DIST) SELECT invoiceid, invoicedate, total FROM invoice WHERE (invoicedate, invoiceid) > ('2009-03-04'::DATE, 100) ORDER BY invoicedate ASC, invoiceid ASC LIMIT 10;\""

# ── Scene 3: Pushdown Operations ──────────────────────────────────────────

p ""
p "=== Part 2: Pushdown Operations ==="
p ""
p "-- 2.1 Aggregate pushdown"
p "COUNT / SUM computed per-tablet in DocDB — only partial results cross the network."

pe "ysqlsh -h 127.0.0.1 -X -c \"EXPLAIN (ANALYZE, DIST) SELECT count(1), sum(milliseconds) FROM track;\""

p ""
p "'Partial Aggregate' nodes in the plan = executed inside DocDB, not YSQL tier."
p ""
p "-- 2.2 Expression pushdown"
p "WHERE predicates with functions evaluated at the storage layer."

pe "ysqlsh -h 127.0.0.1 -X -c \"EXPLAIN (ANALYZE, DIST) SELECT * FROM invoice WHERE total > 5;\""

p ""
p "'Storage Filter' in the plan = predicate ran in DocDB, only matching rows returned."
p ""
p "Disable pushdown to see the difference (all rows transferred, then filtered):"

pe "ysqlsh -h 127.0.0.1 -X -c \"SET yb_enable_expression_pushdown = false; EXPLAIN (ANALYZE, DIST) SELECT * FROM invoice WHERE total > 5; SET yb_enable_expression_pushdown = true;\""

# ── Scene 4: Index Strategies ─────────────────────────────────────────────

p ""
p "=== Part 3: Index Strategies ==="
p ""
p "-- 3.1 Hash index → 2-RPC path"

pe "ysqlsh -h 127.0.0.1 -X -c \"EXPLAIN (ANALYZE, DIST) SELECT * FROM track WHERE albumid = 1;\""

pe "ysqlsh -h 127.0.0.1 -X -c \"CREATE INDEX IF NOT EXISTS idx_track_albumid ON track (albumid HASH);\""

pe "ysqlsh -h 127.0.0.1 -X -c \"EXPLAIN (ANALYZE, DIST) SELECT * FROM track WHERE albumid = 1;\""

p ""
p "-- 3.2 Covering index (INCLUDE) → 1-RPC path"
p "Store projected columns in the index leaf — no main-table fetch needed."

pe "ysqlsh -h 127.0.0.1 -X -c \"CREATE INDEX IF NOT EXISTS idx_track_albumid_cover ON track (albumid HASH) INCLUDE (trackid, name);\""

p ""
p "Index Only Scan: trackid + name served from index leaf (1 RPC, no heap fetch):"

pe "ysqlsh -h 127.0.0.1 -X -c \"EXPLAIN (ANALYZE, DIST) SELECT trackid, name FROM track WHERE albumid = 1;\""

p ""
p "SELECT * still needs the main table — milliseconds, unitprice not in INCLUDE:"

pe "ysqlsh -h 127.0.0.1 -X -c \"EXPLAIN (ANALYZE, DIST) SELECT * FROM track WHERE albumid = 1;\""

p ""
p "-- 3.3 Partial index — index only the rows you actually query"

pe "ysqlsh -h 127.0.0.1 -X -c \"
CREATE INDEX IF NOT EXISTS idx_employee_calgary
  ON employee (city HASH)
  WHERE city = 'Calgary';\""

p ""
p "Predicate-compatible → partial index used:"

pe "ysqlsh -h 127.0.0.1 -X -c \"EXPLAIN (ANALYZE, DIST) SELECT * FROM employee WHERE city = 'Calgary';\""

p ""
p "Predicate not compatible → falls back to full scan:"

pe "ysqlsh -h 127.0.0.1 -X -c \"EXPLAIN (ANALYZE, DIST) SELECT * FROM employee WHERE city = 'Lethbridge';\""

# ── Scene 5: Join Optimisation ─────────────────────────────────────────────

p ""
p "=== Part 4: Join Optimisation — Batch Nested Loop ==="
p ""
p "BNL batches multiple inner-side keys into one storage RPC."
p "Batch=1 → 1 RPC per inner row (worst case). Compare Storage Table Read Requests:"

pe "ysqlsh -h 127.0.0.1 -X -c \"
SET yb_bnl_batch_size = 1;
EXPLAIN (ANALYZE, DIST)
SELECT p.name AS playlist, t.name AS track, ar.name AS artist
FROM   playlist p
JOIN   playlisttrack pt ON  p.playlistid = pt.playlistid
JOIN   track         t  ON pt.trackid    = t.trackid
JOIN   album         a  ON  t.albumid    = a.albumid
JOIN   artist       ar  ON  a.artistid   = ar.artistid
WHERE  p.playlistid = 3;\""

p ""
p "Batch=1024 → 1 RPC per 1024 keys (default). Dramatically fewer Read Requests:"

pe "ysqlsh -h 127.0.0.1 -X -c \"
SET yb_bnl_batch_size = 1024;
EXPLAIN (ANALYZE, DIST)
SELECT p.name AS playlist, t.name AS track, ar.name AS artist
FROM   playlist p
JOIN   playlisttrack pt ON  p.playlistid = pt.playlistid
JOIN   track         t  ON pt.trackid    = t.trackid
JOIN   album         a  ON  t.albumid    = a.albumid
JOIN   artist       ar  ON  a.artistid   = ar.artistid
WHERE  p.playlistid = 3;
RESET yb_bnl_batch_size;\""

# ── Scene 6: Advanced SQL ──────────────────────────────────────────────────

p ""
p "=== Part 5: Advanced SQL ==="
p ""
p "-- 5.1 Window function: invoice delta per customer using LAG()"

pe "ysqlsh -h 127.0.0.1 -X -c \"
SELECT customerid, invoicedate, total,
       LAG(total) OVER per_customer              AS prev_invoice,
       total - LAG(total) OVER per_customer      AS delta
FROM   invoice
WINDOW per_customer AS (PARTITION BY customerid ORDER BY invoicedate)
ORDER BY customerid, invoicedate
LIMIT 15;\""

p ""
p "-- 5.2 Recursive CTE: walk the employee org chart"

pe "ysqlsh -h 127.0.0.1 -X -c \"
WITH RECURSIVE org_tree AS (
  SELECT employeeid,
         firstname || ' ' || lastname AS name,
         title, reportsto,
         firstname || ' ' || lastname AS path,
         0 AS depth
  FROM   employee WHERE reportsto IS NULL
  UNION ALL
  SELECT e.employeeid, e.firstname || ' ' || e.lastname,
         e.title, e.reportsto,
         ot.path || ' → ' || e.firstname || ' ' || e.lastname,
         ot.depth + 1
  FROM   employee e
  JOIN   org_tree ot ON e.reportsto = ot.employeeid
)
SELECT depth, repeat('  ', depth) || name AS org_chart, title
FROM   org_tree ORDER BY path;\""

p ""
p "-- 5.3 Materialized view: pre-computed revenue by country"

pe "ysqlsh -h 127.0.0.1 -X -c \"
CREATE MATERIALIZED VIEW IF NOT EXISTS mv_revenue_by_country AS
SELECT c.country,
       count(DISTINCT c.customerid)   AS customers,
       count(i.invoiceid)             AS invoices,
       round(SUM(i.total)::numeric,2) AS total_revenue
FROM   customer c
JOIN   invoice  i USING (customerid)
GROUP BY c.country
ORDER BY total_revenue DESC;

CREATE INDEX IF NOT EXISTS idx_mv_revenue
  ON mv_revenue_by_country (total_revenue DESC);

REFRESH MATERIALIZED VIEW mv_revenue_by_country;\""

p ""
p "Index scan on the materialised view — no aggregation at query time:"

pe "ysqlsh -h 127.0.0.1 -X -c \"EXPLAIN (ANALYZE, DIST) SELECT * FROM mv_revenue_by_country WHERE total_revenue > 50 ORDER BY total_revenue DESC;\""

pe "ysqlsh -h 127.0.0.1 -X -c \"SELECT * FROM mv_revenue_by_country LIMIT 10;\""

# ── Summary ────────────────────────────────────────────────────────────────

p ""
p "=== Key Mental Models ==="
p ""
p "RPC cost:"
p "  Seq Scan        → N RPCs (one per tablet, parallel scatter-gather)"
p "  Index Scan      → 2 RPCs (index tablet + main tablet)"
p "  Index Only Scan → 1 RPC  (INCLUDE covers all projected columns)"
p ""
p "Pushdowns (reduce data movement between storage and YSQL):"
p "  Storage Filter     → WHERE evaluated in DocDB"
p "  Partial Aggregate  → COUNT/SUM computed per tablet"
p ""
p "ORDER BY:"
p "  Hash PK  → Sort node required (scatter all tablets first)"
p "  Range PK → streaming scan, no Sort node"
p ""
p "Join:"
p "  yb_bnl_batch_size=1024 → 1 RPC per 1024 inner keys (default, best for OLTP)"

cmd

p ""
