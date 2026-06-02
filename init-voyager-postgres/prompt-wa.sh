#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# yb-voyager-wa shell  —  Steps 6–11
#
# Run AFTER Steps 4+5 are streaming in the export/import shells.
#
#   Step 6   Check data-migration-report (lag before cutover)
#   Step 7   Simulate live writes — shows zero-downtime streaming
#   Step 8   Initiate cutover (stops new writes to PostgreSQL)
#   Step 9   Finalize schema (indexes, triggers, materialized views)
#   Step 10  Archive changes
#   Step 11  End migration + verify row counts
# ─────────────────────────────────────────────────────────────────────────────

. pscript

TYPE_SPEED=35
NO_WAIT=false
DEMO_PROMPT="${GREEN}➜ ${CYAN}\W ${COLOR_RESET}"

EXPORT_DIR="/workspaces/ybdb-vanguard/voyager-data"
mkdir -p "${EXPORT_DIR}"

clear

p "=== yb-voyager-wa: Steps 6–11 (cutover + finalise) ==="
p ""
p "Steps 4+5 should be streaming in the other shells."

# ── Step 6: Migration report ──────────────────────────────────────────────────

p ""
p "--- Step 6: Get Data-Migration-Report ---"
p "Check replication lag before initiating cutover."

pe "yb-voyager get data-migration-report \
  --export-dir ${EXPORT_DIR} \
  --target-db-password ${TARGET_SECRET:-yugabyte}"

# ── Step 7: Simulate live write to prove streaming ────────────────────────────

p ""
p "--- Step 7: Simulate Live Write (app keeps running during migration) ---"

pe "psql -h ${SRC_HOST:-postgres} -c \
  \"INSERT INTO public.\\\"Artist\\\" (\\\"ArtistId\\\", \\\"Name\\\") VALUES (999, 'YugabyteDB Band');\""

p "Waiting for CDC to stream the change to YugabyteDB..."
sleep 5

pe "ysqlsh -h 127.0.0.1 -c \
  \"SELECT * FROM public.\\\"Artist\\\" WHERE \\\"ArtistId\\\" = 999;\""

# ── Step 8: Initiate cutover ──────────────────────────────────────────────────

p ""
p "--- Step 8: Initiate Cutover ---"
p "Stops writes to PostgreSQL; drains remaining WAL to YugabyteDB."

pe "yb-voyager initiate cutover to target \
  --export-dir ${EXPORT_DIR} \
  --prepare-for-fall-back false"

pe "yb-voyager cutover status --export-dir ${EXPORT_DIR}"

p ""
p "Steps 4+5 will now terminate in their shells."
p "Press ENTER to continue with schema finalisation."
cmd

# ── Step 9: Finalize schema ───────────────────────────────────────────────────

p ""
p "--- Step 9: Finalize Schema (indexes, triggers, materialized views) ---"

pe "yb-voyager finalize-schema-post-data-import \
  --export-dir ${EXPORT_DIR} \
  --target-db-host 127.0.0.1 \
  --target-db-user ${TARGET_USER:-yugabyte} \
  --target-db-password ${TARGET_SECRET:-yugabyte} \
  --target-db-name ${TARGET_DB_ID:-yugabyte} \
  --target-db-schema ${SCHEMA:-public} \
  --refresh-mviews true"

# ── Step 10: Archive changes ──────────────────────────────────────────────────

p ""
p "--- Step 10: Archive Changes ---"

pe "yb-voyager archive changes \
  --export-dir ${EXPORT_DIR} \
  --policy delete-on-success"

# ── Step 11: End migration + verify ──────────────────────────────────────────

p ""
p "--- Step 11: End Migration ---"

pe "yb-voyager end migration \
  --export-dir ${EXPORT_DIR} \
  --backup-log-files yes \
  --backup-data-files no \
  --backup-schema-files no \
  --save-migration-reports yes \
  --backup-dir ${EXPORT_DIR}/backup"

p ""
p "--- Final Verification: Row counts in YugabyteDB ---"

pe "ysqlsh -h 127.0.0.1 -c \"
SELECT relname AS table_name, n_live_tup AS rows
FROM pg_stat_user_tables
ORDER BY rows DESC;\""

p ""
p "✅ Zero-downtime live migration complete."
p "   PostgreSQL → YugabyteDB. Application was live throughout."
p "   Snapshot + CDC streaming → cutover."

cmd
