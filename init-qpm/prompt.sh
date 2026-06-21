#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# YugabyteDB Query Plan Management demo  —  "Catch and Pin the Plan"
#
# QPM lets you detect plan changes, compare every plan a query has ever used,
# and pin a known-good plan so a statistics change never regresses it.
#
#   Part 1 · Capture a plan      — EXPLAIN query/plan IDs, populate yb_pg_stat_plans
#   Part 2 · Detect a regression — force a different plan, watch a second plan appear
#   Part 3 · Pin the good plan   — copy its hints into hint_plan.hints, verify
#
# Pre-requisites (handled by the devcontainer postStartCommand → setup.sql):
#   - 1-node YugabyteDB cluster on 127.0.0.1:5433  (v2025.2.3.0+)
#   - pg_stat_statements + pg_hint_plan extensions
#   - yb_enable_cbo / yb_pg_stat_plans_track / hint table enabled as DB defaults
#   - orders + order_details seeded with the 1000×20 baseline
# ─────────────────────────────────────────────────────────────────────────────

. pscript
set -f  # disable filename expansion — prevents SELECT * / count(*) glob-expanding

TYPE_SPEED=70
NO_WAIT=false
# Each `pe` normally pauses TWICE (before typing the command, and again before
# running it). This removes the first pause so the command types out as soon as
# you reach it; you then press Enter ONCE to run it. One pause per step.
NO_WAIT_DISPLAY_CMD=true
DEMO_PROMPT="${GREEN}➜ ${CYAN}\W ${COLOR_RESET}"

clear

# ── Intro ──────────────────────────────────────────────────────────────────
p "=== YugabyteDB Query Plan Management (QPM): Catch and Pin the Plan ==="
p ""
p "A query plan can change over time, and the new plan can be slower than the old one."
p "QPM keeps a record of every plan a query has used, with the hints to reproduce each one. So you can find a bad change and pin a known-good plan."
p ""
p "The database is already QPM-ready. Let's confirm:"

pe "ysqlsh -h 127.0.0.1 -X -c \"SHOW yb_enable_cbo; SHOW yb_pg_stat_plans_track; SHOW pg_hint_plan.enable_hint_table;\""

p ""
p "Baseline data: 1000 accounts, 20 orders each."

pe "ysqlsh -h 127.0.0.1 -X -c \"SELECT count(*) AS orders, count(DISTINCT account_id) AS accounts FROM orders;\""

# ── Part 1: Capture a plan ───────────────────────────────────────────────────
p ""
p "=== Part 1: Capture a plan ==="
p ""
p "Start from a clean slate — drop any pinned hint from a previous run (else the query would always use that one plan) and reset the statistics:"

pe "ysqlsh -h 127.0.0.1 -X -c \"DELETE FROM hint_plan.hints; SELECT pg_stat_statements_reset(); SELECT yb_pg_stat_plans_reset(NULL,NULL,NULL,NULL);\""

p ""
p "This is the query we will track — it joins orders and order_details to read all orders of account 10:"
p ""
p "  ${CYAN}SELECT d.details FROM orders o JOIN order_details d ON o.order_id = d.order_id WHERE account_id = 10;${COLOR_RESET}"
p ""
p "First we run it with EXPLAIN (queryid on, planid on). QPM uses the query id and plan id to identify the query and its plan:"

pe "ysqlsh -h 127.0.0.1 -X -c \"EXPLAIN (queryid on, planid on) SELECT d.details FROM orders o JOIN order_details d ON o.order_id = d.order_id WHERE account_id = 10;\""

p ""
p "For this query, the good plan is a batched nested loop. We force it here so the baseline plan is always the same:"

pe "ysqlsh -h 127.0.0.1 -X -c \"SET yb_bnl_batch_size = 1024; EXPLAIN (ANALYZE, DIST) SELECT d.details FROM orders o JOIN order_details d ON o.order_id = d.order_id WHERE account_id = 10;\""

p ""
p "Run the query 100 times to populate pg_stat_statements and yb_pg_stat_plans:"

pe "ysqlsh -h 127.0.0.1 -X -f workload.sql"

p ""
p "One query, one plan so far. yb_pg_stat_plans holds the stats + hints;"
p "yb_pg_stat_plans has no query text, so we join pg_stat_statements on queryid for the text:"

pe "ysqlsh -h 127.0.0.1 -X -c \"
SELECT p.queryid, p.planid, p.calls,
       round(p.avg_exec_time::numeric,3) AS avg_ms,
       round(p.avg_est_cost::numeric,1)  AS est_cost,
       p.first_used
FROM   yb_pg_stat_plans p
JOIN   pg_stat_statements s ON s.queryid = p.queryid
WHERE  s.query LIKE 'SELECT d.details FROM orders o JOIN order_details%' /* __YB_STAT_PLANS_SKIP */;\""

# ── Part 2: Detect a regression ──────────────────────────────────────────────
p ""
p "=== Part 2: Detect a regression ==="
p ""
p "A plan can change for many reasons — new table statistics, a new index, turning ON the cost-based optimizer, or a database upgrade."
p "These reasons are hard to trigger on demand. So, only for this demo, we force a different plan by switching off the batched nested loop."
p ""
p ">> NOTE (FOR DEMO ONLY): setting yb_enable_batchednl = off and yb_bnl_batch_size = 1 switches off the batched nested loop. The planner then picks a plain nested loop — a second, different plan that we can fix later."
p ">> In real life you do NOT change these flags. The plan changes on its own, for the reasons above. We use the flags only to create that situation here."
p ""
p "With BNL batching off, the same query gets a different join (a plain nested loop):"

pe "ysqlsh -h 127.0.0.1 -X -c \"SET yb_enable_batchednl = off; SET yb_bnl_batch_size = 1; EXPLAIN (ANALYZE, DIST) SELECT d.details FROM orders o JOIN order_details d ON o.order_id = d.order_id WHERE account_id = 10;\""

p ""
p "Run the workload 100x in that regressed state so QPM captures the new plan"
p "(workload_nobnl.sql sets yb_enable_batchednl = off and yb_bnl_batch_size = 1 in the same session):"

pe "ysqlsh -h 127.0.0.1 -X -f workload_nobnl.sql"

p ""
p "yb_pg_stat_plans should now show TWO plans for the same query. Notice the different planid, first_used, and avg_exec_time. This is the plan history:"

pe "ysqlsh -h 127.0.0.1 -X -c \"
SELECT p.planid, p.calls,
       round(p.avg_exec_time::numeric,3) AS avg_ms,
       round(p.avg_est_cost::numeric,1)  AS est_cost,
       p.first_used, p.last_used
FROM   yb_pg_stat_plans p
JOIN   pg_stat_statements s ON s.queryid = p.queryid
WHERE  s.query LIKE 'SELECT d.details FROM orders o JOIN order_details%'
ORDER  BY p.first_used /* __YB_STAT_PLANS_SKIP */;\""

p ""
p "The yb_pg_stat_plans_insights view points to the best plan for each query."
p "plan_min_exec_time = 'Yes' is the fastest plan. plan_require_evaluation = 'Yes' means the cheapest plan (by cost) and the fastest plan are not the same — so check it:"

pe "ysqlsh -h 127.0.0.1 -X -c \"
SELECT planid,
       round(avg_exec_time::numeric,3) AS avg_ms,
       round(avg_est_cost::numeric,1)  AS est_cost,
       plan_min_exec_time, plan_require_evaluation
FROM   yb_pg_stat_plans_insights
ORDER  BY avg_exec_time;\""

# ── Part 3: Pin the good plan ────────────────────────────────────────────────
p ""
p "=== Part 3: Pin the good plan ==="
p ""
p "Every captured plan stores the HINTS that reproduce it. Look at the hints for each plan — we'll pin the fastest one (lowest avg_exec_time):"

pe "ysqlsh -h 127.0.0.1 -X -c \"
SELECT p.planid, p.first_used, p.hints
FROM   yb_pg_stat_plans p
JOIN   pg_stat_statements s ON s.queryid = p.queryid
WHERE  s.query LIKE 'SELECT d.details FROM orders o JOIN order_details%'
ORDER  BY p.first_used /* __YB_STAT_PLANS_SKIP */;\""

p ""
p "Pin it: copy the FASTEST plan's hints into the pg_hint_plan hint table, keyed by queryid. We let QPM choose — yb_pg_stat_plans_insights.plan_min_exec_time = 'Yes' marks the lowest-execution-time plan."

pe "ysqlsh -h 127.0.0.1 -X -c \"
DELETE FROM hint_plan.hints;
INSERT INTO hint_plan.hints (norm_query_string, application_name, hints)
SELECT i.queryid::text, '', substring(i.hints from 5 for char_length(i.hints) - 7)
FROM   yb_pg_stat_plans_insights i
JOIN   pg_stat_statements s ON s.queryid = i.queryid
WHERE  s.query LIKE 'SELECT d.details FROM orders o JOIN order_details%'
  AND  i.plan_min_exec_time = 'Yes'
LIMIT  1
ON CONFLICT (norm_query_string, application_name) DO UPDATE
   SET hints = EXCLUDED.hints /* __YB_STAT_PLANS_SKIP */;\""

p ""
p "The hint table now holds one pinned entry:"

pe "ysqlsh -h 127.0.0.1 -X -c \"SELECT norm_query_string, application_name, hints FROM hint_plan.hints;\""

p ""
p "Verify the pin takes effect. We deliberately keep BNL DISABLED — the same regressed condition from Part 2 — yet the hint forces the good plan back."
p "EXPLAIN (..., HINTS) echoes the hints applied:"

pe "ysqlsh -h 127.0.0.1 -X -c \"SET yb_enable_batchednl = off; SET yb_bnl_batch_size = 1; EXPLAIN (ANALYZE, DIST, HINTS) SELECT d.details FROM orders o JOIN order_details d ON o.order_id = d.order_id WHERE account_id = 10;\""

p ""
p "Even though the session disabled BNL batching, the plan came back as the good batched nested loop — the pinned hint overrode the optimizer. Regression fixed."
p ""

# ── Part 4: Prevent future regressions ───────────────────────────────────────
p ""
p "=== Part 4: Prevent future regressions ==="
p ""
p "The pin is saved in hint_plan.hints (by query id), so it stays even after such changes. To prove that the pin is what protects the query, let us remove it. The slow plan comes back:"

pe "ysqlsh -h 127.0.0.1 -X -c \"DELETE FROM hint_plan.hints; SET yb_enable_batchednl = off; SET yb_bnl_batch_size = 1; EXPLAIN (ANALYZE, DIST) SELECT d.details FROM orders o JOIN order_details d ON o.order_id = d.order_id WHERE account_id = 10;\""

p ""
p "Unpinned + BNL off -> the regressed nested loop is back. Re-pin the fastest plan (plan_min_exec_time = 'Yes') to lock it in again for the future:"

pe "ysqlsh -h 127.0.0.1 -X -c \"
INSERT INTO hint_plan.hints (norm_query_string, application_name, hints)
SELECT i.queryid::text, '', substring(i.hints from 5 for char_length(i.hints) - 7)
FROM   yb_pg_stat_plans_insights i
JOIN   pg_stat_statements s ON s.queryid = i.queryid
WHERE  s.query LIKE 'SELECT d.details FROM orders o JOIN order_details%'
  AND  i.plan_min_exec_time = 'Yes'
LIMIT  1
ON CONFLICT (norm_query_string, application_name) DO UPDATE
   SET hints = EXCLUDED.hints /* __YB_STAT_PLANS_SKIP */;\""

pe "ysqlsh -h 127.0.0.1 -X -c \"SET yb_enable_batchednl = off; SET yb_bnl_batch_size = 1; EXPLAIN (ANALYZE, DIST, HINTS) SELECT d.details FROM orders o JOIN order_details d ON o.order_id = d.order_id WHERE account_id = 10;\""

p ""
p "Good plan is locked in again. Best practice: for important queries, pin a known-good plan in advance. Then any future change cannot make it slow. To remove a pin, just DELETE it from hint_plan.hints."

# ── Summary ──────────────────────────────────────────────────────────────────
p ""
p "=== Key Mental Models  (QPM: Detect → Correct → Prevent) ==="
p ""
p "DETECT   yb_pg_stat_plans_track = 'top' | 'all'        (none = off)"
p "         EXPLAIN (queryid on, planid on) ...           (the keys QPM uses)"
p "         yb_pg_stat_plans          → every plan + stats + hints"
p "         yb_pg_stat_plans_insights → which plan is fastest / suspect"
p "CORRECT  INSERT a captured plan's hints into hint_plan.hints to pin it"
p "         (Yugabyte's enhanced plan hints reproduce the exact plan)"
p "PREVENT  pin a known-good plan in advance, so a future change to the"
p "         optimizer's inputs can never make this query slow"
p ""
p "Also:    __YB_STAT_PLANS_SKIP comment excludes a query from tracking;"
p "         yb_pg_stat_plans_reset(dbid, userid, queryid, planid) clears entries."
p ""

cmd

p ""
