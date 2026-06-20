-- ─────────────────────────────────────────────────────────────────────────────
-- setup.sql  —  Query Plan Management (QPM) exercise bootstrap
--
-- Run automatically by the devcontainer postStartCommand so the database is
-- READY THE MOMENT the cluster comes up:
--   • pg_stat_statements + pg_hint_plan extensions created
--   • QPM tracking, the cost-based optimizer, and the hint table enabled as
--     DATABASE-LEVEL defaults (so every new ysqlsh session inherits them)
--   • orders / order_details schema seeded with the "good plan" baseline
--     (1000 accounts × 20 orders) and ANALYZEd
--
-- Re-runnable: drops and recreates the demo tables, so it is safe to run again.
--
-- QPM requires YugabyteDB v2025.2.3.0 or later (Early Access).
-- ─────────────────────────────────────────────────────────────────────────────

-- ── Extensions ───────────────────────────────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS pg_hint_plan;

-- ── Database-level defaults: make the DB "QPM-ready" for every connection ─────
-- yb_enable_cbo            → cost-based optimizer (plans react to statistics)
-- yb_pg_stat_plans_track   → QPM: 'all' tracks every trackable statement
-- enable_hint_table        → pg_hint_plan consults hint_plan.hints to pin plans
-- yb_use_query_id_for_hinting → key the hint table by query id (not query text)
ALTER DATABASE yugabyte SET yb_enable_cbo = on;
ALTER DATABASE yugabyte SET yb_pg_stat_plans_track = 'all';
ALTER DATABASE yugabyte SET pg_hint_plan.enable_hint_table = on;
ALTER DATABASE yugabyte SET pg_hint_plan.yb_use_query_id_for_hinting = on;

-- ── Demo schema ───────────────────────────────────────────────────────────────
DROP TABLE IF EXISTS order_details, orders CASCADE;

CREATE TABLE orders (
    account_id INT,
    order_no   INT,
    order_id   TEXT,
    PRIMARY KEY (account_id, order_no));

CREATE TABLE order_details (
    order_id TEXT PRIMARY KEY,
    details  json);

-- ── Baseline data: 1000 accounts, each with 20 orders (20,000 orders) ─────────
-- This is the "healthy" state in which the join uses a batched nested loop.
INSERT INTO orders (account_id, order_no, order_id)
SELECT a, o, a::text || '_' || o::text
FROM generate_series(1, 1000) a, generate_series(1, 20) o;

INSERT INTO order_details (order_id, details)
SELECT order_id, '{}' FROM orders;

ANALYZE orders;
ANALYZE order_details;

-- Clean slate: drop any pinned hints left over from a previous run. A stale
-- entry in hint_plan.hints would force one plan on every execution (the hint
-- table is enabled by default above), so the regression demo would only ever
-- show a single plan.
DELETE FROM hint_plan.hints;

-- Start each session from clean statistics.
SELECT pg_stat_statements_reset();
SELECT yb_pg_stat_plans_reset(NULL, NULL, NULL, NULL);

\echo '✅ QPM exercise ready: extensions, DB defaults, and 1000×20 baseline loaded.'
