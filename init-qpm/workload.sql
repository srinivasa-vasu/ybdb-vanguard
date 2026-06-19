-- ─────────────────────────────────────────────────────────────────────────────
-- workload.sql  —  run the demo query 100 times to populate QPM statistics
--
-- Uses psql's \gexec: the outer SELECT emits the query text 100 times, and
-- \gexec executes each emitted row as its own top-level statement (which is
-- what pg_stat_statements and QPM track). Output is sent to /dev/null so the
-- terminal isn't flooded with 100 result sets.
--
-- The generate_series wrapper query references only a function, so QPM cannot
-- generate hints for it and does not store it — it won't pollute the results.
-- ─────────────────────────────────────────────────────────────────────────────
-- Capture the GOOD plan deterministically: yb_bnl_batch_size = 1024 (the default,
-- recommended value) keeps the batched nested loop — the right plan for this
-- point-lookup join. Part 2 sets it to 1 to "regress" to a plain nested loop,
-- guaranteeing two distinct plans for the demo.
SET yb_bnl_batch_size = 1024;
\set QUIET on
\o /dev/null
-- No trailing semicolon: \gexec sends the query buffer and runs each returned
-- row as its own statement. A semicolon would execute and clear the buffer,
-- leaving \gexec with nothing to run.
SELECT 'SELECT d.details FROM orders o JOIN order_details d ON o.order_id = d.order_id WHERE account_id = 10;'
FROM generate_series(1, 100)
\gexec
\o
\unset QUIET
\echo 'workload: executed the demo query 100 times'
