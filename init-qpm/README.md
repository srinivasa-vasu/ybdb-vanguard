# Query Plan Management (QPM)

[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/srinivasa-vasu/ybdb-vanguard?devcontainer_path=.devcontainer%2Finit-qpm%2Fdevcontainer.json)

Stable, consistent query performance — even as statistics change, indexes appear, you turn on the cost-based optimizer, or you upgrade. **Query Plan Management (QPM)** records every unique plan a query has ever used, along with the hints needed to reproduce it, so you can **detect** a plan regression, **correct** it by pinning a known-good plan, and **prevent** future regressions.

> QPM is an **Early Access** feature available in **YugabyteDB v2025.2.3.0 and later**. This devcontainer pins a compatible build, so everything works out of the box.

---

## The database is ready when the container starts

The devcontainer's `postStartCommand` starts a single-node cluster **and** runs [`setup.sql`](setup.sql), so the moment DevPod / Codespaces finishes you have a fully QPM-ready database — no manual setup:

- `pg_stat_statements` and `pg_hint_plan` extensions created.
- QPM tracking, the cost-based optimizer, and the hint table enabled as **database-level defaults** (via `ALTER DATABASE`), so **every** `ysqlsh` session inherits them:
  - `yb_enable_cbo = on`
  - `yb_pg_stat_plans_track = 'all'`
  - `pg_hint_plan.enable_hint_table = on`
  - `pg_hint_plan.yb_use_query_id_for_hinting = on`
- `orders` / `order_details` seeded with the baseline (1000 accounts × 20 orders) and `ANALYZE`d.

Confirm any time with:

```bash
ysqlsh -h 127.0.0.1 -c "SHOW yb_enable_cbo; SHOW yb_pg_stat_plans_track; SHOW pg_hint_plan.enable_hint_table;"
```

---

## Two ways to run this

| Option | How |
|---|---|
| **Guided demo** | **Terminal → Run Task → `qpm-demo`**, then `bash prompt.sh`. Auto-types each step. |
| **Manual workshop** | Follow the steps below. Each command is a terminal one-liner you can paste and run, so you can pause and inspect the output. (Tip: open a shell with **Terminal → Run Task → `ysql`** too.) |

The steps below are the same statements the guided demo runs.

---

## Workshop

The demo query joins `orders` and `order_details` to read all orders of one account:

```sql
SELECT d.details FROM orders o JOIN order_details d ON o.order_id = d.order_id WHERE account_id = 10;
```

### Part 1 — Capture a plan

Start from a clean slate — drop any pinned hint from a previous run and reset the statistics:

```bash
ysqlsh -h 127.0.0.1 -c "DELETE FROM hint_plan.hints; SELECT pg_stat_statements_reset(); SELECT yb_pg_stat_plans_reset(NULL,NULL,NULL,NULL);"
```

Run the query with `EXPLAIN (queryid on, planid on)`. QPM uses the **query id** and **plan id** to identify the query and its plan:

```bash
ysqlsh -h 127.0.0.1 -c "EXPLAIN (queryid on, planid on) SELECT d.details FROM orders o JOIN order_details d ON o.order_id = d.order_id WHERE account_id = 10;"
```

For this query the good plan is a batched nested loop. Force it with `yb_bnl_batch_size = 1024` (the default) so the baseline plan is always the same:

```bash
ysqlsh -h 127.0.0.1 -c "SET yb_bnl_batch_size = 1024; EXPLAIN (ANALYZE, DIST) SELECT d.details FROM orders o JOIN order_details d ON o.order_id = d.order_id WHERE account_id = 10;"
```

`EXPLAIN` itself is not tracked by QPM — only real executions are. Run the query 100 times to populate `pg_stat_statements` and `yb_pg_stat_plans`:

```bash
ysqlsh -h 127.0.0.1 -f init-qpm/workload.sql
```

Read the captured plan back. `yb_pg_stat_plans` has no query text, so join `pg_stat_statements` on `queryid`:

```bash
ysqlsh -h 127.0.0.1 -c "
SELECT p.queryid, p.planid, p.calls,
       round(p.avg_exec_time::numeric,3) AS avg_ms,
       round(p.avg_est_cost::numeric,1)  AS est_cost,
       p.first_used
FROM   yb_pg_stat_plans p
JOIN   pg_stat_statements s ON s.queryid = p.queryid
WHERE  s.query LIKE 'SELECT d.details FROM orders o JOIN order_details%' /* __YB_STAT_PLANS_SKIP */;"
```

You should see **one** plan.

### Part 2 — Detect a regression

A plan can change for many reasons — new table statistics, a new index, turning ON the cost-based optimizer, or a database upgrade. These are hard to trigger on demand, so **only for this workshop** we force a different plan by switching off the batched nested loop.

> **Demo device only.** `yb_enable_batchednl = off` + `yb_bnl_batch_size = 1` make the planner pick a plain nested loop — a second, different plan we can fix later. `yb_bnl_batch_size = 1` is the dependable knob (`yb_enable_batchednl = off` alone can still pick a batched nested loop); we set both. In real life you do **not** change these flags — the plan changes on its own for the reasons above.

See the different (regressed) plan:

```bash
ysqlsh -h 127.0.0.1 -c "SET yb_enable_batchednl = off; SET yb_bnl_batch_size = 1; EXPLAIN (ANALYZE, DIST) SELECT d.details FROM orders o JOIN order_details d ON o.order_id = d.order_id WHERE account_id = 10;"
```

Run the workload 100 times in that regressed state so QPM captures the new plan (`workload_nobnl.sql` sets both flags in the same session):

```bash
ysqlsh -h 127.0.0.1 -f init-qpm/workload_nobnl.sql
```

`yb_pg_stat_plans` now shows **two** plans for the same query — note the different `planid`, `first_used`, and `avg_exec_time`. This is the plan history:

```bash
ysqlsh -h 127.0.0.1 -c "
SELECT p.planid, p.calls,
       round(p.avg_exec_time::numeric,3) AS avg_ms,
       round(p.avg_est_cost::numeric,1)  AS est_cost,
       p.first_used, p.last_used
FROM   yb_pg_stat_plans p
JOIN   pg_stat_statements s ON s.queryid = p.queryid
WHERE  s.query LIKE 'SELECT d.details FROM orders o JOIN order_details%'
ORDER  BY p.first_used /* __YB_STAT_PLANS_SKIP */;"
```

The `yb_pg_stat_plans_insights` view points to the best plan. `plan_min_exec_time = 'Yes'` is the fastest plan; `plan_require_evaluation = 'Yes'` means the cheapest plan (by cost) and the fastest plan are not the same — so check it:

```bash
ysqlsh -h 127.0.0.1 -c "
SELECT planid,
       round(avg_exec_time::numeric,3) AS avg_ms,
       round(avg_est_cost::numeric,1)  AS est_cost,
       plan_min_exec_time, plan_require_evaluation
FROM   yb_pg_stat_plans_insights
ORDER  BY avg_exec_time;"
```

### Part 3 — Correct: pin the good plan

Every captured plan stores the `hints` that reproduce it. Look at the hints for each plan:

```bash
ysqlsh -h 127.0.0.1 -c "
SELECT p.planid, p.first_used, p.hints
FROM   yb_pg_stat_plans p
JOIN   pg_stat_statements s ON s.queryid = p.queryid
WHERE  s.query LIKE 'SELECT d.details FROM orders o JOIN order_details%'
ORDER  BY p.first_used /* __YB_STAT_PLANS_SKIP */;"
```

Pin the **fastest** plan into the hint table. We let QPM choose it — `yb_pg_stat_plans_insights.plan_min_exec_time = 'Yes'` marks the lowest-execution-time plan. The `substring(...)` strips the surrounding `/*+ … */` wrapper (see the note under the manual reference below):

```bash
ysqlsh -h 127.0.0.1 -c "
DELETE FROM hint_plan.hints;
INSERT INTO hint_plan.hints (norm_query_string, application_name, hints)
SELECT i.queryid::text, '', substring(i.hints from 5 for char_length(i.hints) - 7)
FROM   yb_pg_stat_plans_insights i
JOIN   pg_stat_statements s ON s.queryid = i.queryid
WHERE  s.query LIKE 'SELECT d.details FROM orders o JOIN order_details%'
  AND  i.plan_min_exec_time = 'Yes'
LIMIT  1
ON CONFLICT (norm_query_string, application_name) DO UPDATE
   SET hints = EXCLUDED.hints;"
```

The hint table now holds one pinned entry:

```bash
ysqlsh -h 127.0.0.1 -c "SELECT norm_query_string, application_name, hints FROM hint_plan.hints;"
```

Verify the pin. We keep BNL **disabled** — the same regressed condition from Part 2 — yet the hint forces the good plan back. `EXPLAIN (..., HINTS)` echoes the hints applied:

```bash
ysqlsh -h 127.0.0.1 -c "SET yb_enable_batchednl = off; SET yb_bnl_batch_size = 1; EXPLAIN (ANALYZE, DIST, HINTS) SELECT d.details FROM orders o JOIN order_details d ON o.order_id = d.order_id WHERE account_id = 10;"
```

The plan comes back as the good batched nested loop — the pinned hint overrode the optimizer.

> Do **not** reset QPM and re-run the query in the regressed state to "confirm". Executing it while the session has `yb_bnl_batch_size = 1` would bake that value into the newly captured hints. Leaving QPM untouched keeps the clean good-plan entry (captured at `batch_size = 1024`) as the source to pin from — which is why the pinned hint correctly reads `Set(yb_bnl_batch_size 1024)`, not `1`.

### Part 4 — Prevent future regressions

The pin lives in `hint_plan.hints` (keyed by query id), so it stays even after such changes. To prove the pin is what protects the query, remove it — the slow plan comes back:

```bash
ysqlsh -h 127.0.0.1 -c "DELETE FROM hint_plan.hints; SET yb_enable_batchednl = off; SET yb_bnl_batch_size = 1; EXPLAIN (ANALYZE, DIST) SELECT d.details FROM orders o JOIN order_details d ON o.order_id = d.order_id WHERE account_id = 10;"
```

Re-pin the fastest plan to lock it in again:

```bash
ysqlsh -h 127.0.0.1 -c "
INSERT INTO hint_plan.hints (norm_query_string, application_name, hints)
SELECT i.queryid::text, '', substring(i.hints from 5 for char_length(i.hints) - 7)
FROM   yb_pg_stat_plans_insights i
JOIN   pg_stat_statements s ON s.queryid = i.queryid
WHERE  s.query LIKE 'SELECT d.details FROM orders o JOIN order_details%'
  AND  i.plan_min_exec_time = 'Yes'
LIMIT  1
ON CONFLICT (norm_query_string, application_name) DO UPDATE
   SET hints = EXCLUDED.hints;"
```

```bash
ysqlsh -h 127.0.0.1 -c "SET yb_enable_batchednl = off; SET yb_bnl_batch_size = 1; EXPLAIN (ANALYZE, DIST, HINTS) SELECT d.details FROM orders o JOIN order_details d ON o.order_id = d.order_id WHERE account_id = 10;"
```

Good plan is locked in again. **Best practice:** for important queries, pin a known-good plan in advance — then any future change cannot make it slow. To remove a pin, just `DELETE` it from `hint_plan.hints`.

---

## Configuration parameters

QPM is controlled by these YSQL configuration parameters (set per-session with `SET`, or as a database default with `ALTER DATABASE`, as this exercise does):

| Parameter | Description | Default |
|---|---|---|
| `yb_pg_stat_plans_track` | `none` (off) · `top` (top-level statements) · `all` (all statements) | `none` |
| `yb_pg_stat_plans_max_cache_size` | Max entries to store (1–50000) | `5000` |
| `yb_pg_stat_plans_cache_replacement_algorithm` | `simple_clock_lru` · `true_lru` (requires restart) | `simple_clock_lru` |
| `yb_pg_stat_plans_track_catalog_queries` | Track statements referencing catalog tables | `true` |
| `yb_pg_stat_plans_verbose_plans` | Store verbose plans | `false` |
| `yb_pg_stat_plans_plan_format` | `text` · `json` · `yaml` · `xml` | `json` |

Only `SELECT`, `INSERT`, `UPDATE`, `MERGE`, `DELETE`, and `EXECUTE` statements **for which hints can be generated** are tracked. `EXPLAIN ANALYZE` is not tracked. Add the comment **`__YB_STAT_PLANS_SKIP`** to any statement to exclude it from QPM.

---

## The two views

### `yb_pg_stat_plans` — every plan, with stats and hints

| Column | Purpose |
|---|---|
| `dbid`, `userid`, `queryid`, `planid` | Identify a plan |
| `plan` | Text representation of the plan |
| `first_used` / `last_used` | Detect plan changes |
| `calls` / `avg_exec_time` / `max_exec_time` / `max_exec_time_params` / `avg_est_cost` | Detect regressions |
| `hints` | The hints that reproduce this plan — used to pin it |

`yb_pg_stat_plans` stores **no query text** — join `pg_stat_statements` on `queryid` to get it.

### `yb_pg_stat_plans_insights` — which plan to trust

- `plan_min_exec_time = 'Yes'` → the plan with the lowest average execution time for that query.
- `plan_require_evaluation = 'Yes'` → the cheapest-estimated-cost plan and the fastest-executing plan are **not** the same — worth a closer look.

---

## Manual reference

> The pinning `INSERT` uses `substring(i.hints from 5 for char_length(i.hints) - 7)`. The stored hints are wrapped like `/*+ … */`; this drops the 4-char prefix `/*+ ` (start at position 5) and the 3-char suffix ` */` (4 + 3 = 7 fewer characters), leaving the bare hint text the hint table expects. Note: very long hints are truncated by QPM and **truncated hints cannot pin a plan**.

```bash
# Re-run the bootstrap (idempotent — recreates the demo tables)
ysqlsh -h 127.0.0.1 -f init-qpm/setup.sql

# Open a YSQL shell
ysqlsh -h 127.0.0.1

# All QPM entries on this node
ysqlsh -h 127.0.0.1 -c "SELECT * FROM yb_pg_stat_plans;"

# Reset QPM entries  (dbid, userid, queryid, planid — NULL = wildcard)
ysqlsh -h 127.0.0.1 -c "SELECT yb_pg_stat_plans_reset(NULL, NULL, NULL, NULL);"
```

---

## Reference

- [YFTT #157 — Query Plan Management: Detecting, Correcting, and Preventing Plan Regressions](https://www.youtube.com/watch?v=yvIZdr8ejdU) (the talk this exercise is based on, by Bill McKenna)
- [Query plan management — YugabyteDB docs](https://docs.yugabyte.com/stable/launch-and-manage/monitor-and-alert/query-tuning/query-plan-manage/)
- [Optimize YSQL queries using pg_hint_plan](https://docs.yugabyte.com/stable/launch-and-manage/monitor-and-alert/query-tuning/pg-hint-plan/)
- [Get query statistics using pg_stat_statements](https://docs.yugabyte.com/stable/launch-and-manage/monitor-and-alert/query-tuning/pg-stat-statements/)
