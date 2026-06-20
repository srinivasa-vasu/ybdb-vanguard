-- ─────────────────────────────────────────────────────────────────────────────
-- workload_nobnl.sql  —  run the demo query 100 times WITHOUT batched nested loop
--
-- DEMO DEVICE ONLY. We turn off the batched nested loop so the planner uses a
-- plain nested loop — producing a SECOND, distinct plan for the same query
-- deterministically, in any build. yb_bnl_batch_size = 1 is the dependable knob
-- (yb_enable_batchednl = off alone is NOT reliable — the planner can still pick a
-- batched nested loop); we set BOTH for good measure.
--
-- In production you would NOT flip these: a real regression appears on its own
-- when statistics change, an index is added, you enable the CBO, or you upgrade.
-- The knobs just let us reproduce that situation on demand so the rest of the
-- QPM workflow (compare → pin → prevent) has two plans to work with.
--
-- The SET must run in the SAME session as the executions, so it lives here
-- rather than in a separate `ysqlsh -c` call.
-- ─────────────────────────────────────────────────────────────────────────────
SET yb_enable_batchednl = off;   -- demo device: disable the batched nested loop
SET yb_bnl_batch_size = 1;       -- demo device: 1 disables BNL batching → plain nested loop
\set QUIET on
\o /dev/null
-- No trailing semicolon: \gexec sends the query buffer and runs each returned
-- row as its own statement.
SELECT 'SELECT d.details FROM orders o JOIN order_details d ON o.order_id = d.order_id WHERE account_id = 10;'
FROM generate_series(1, 100)
\gexec
\o
\unset QUIET
\echo 'workload: executed the demo query 100 times with BNL batching off (demo device)'
