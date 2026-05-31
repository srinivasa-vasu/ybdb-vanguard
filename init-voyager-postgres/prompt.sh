#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# YugabyteDB Voyager demo  —  "Zero-Downtime Live Migration"
#
# Scenario: The Chinook music store runs on PostgreSQL. The team needs to
# migrate to YugabyteDB with zero application downtime. yb-voyager streams
# a snapshot and then continuously ships WAL changes until cutover.
#
# The live migration workflow runs two long-lived processes in parallel:
#   export data from source  →  streams snapshot + CDC changes
#   import data to target    →  applies them to YugabyteDB continuously
#
# This demo script launches both as background jobs, verifies they are
# running, simulates live application writes, then performs the cutover.
# ─────────────────────────────────────────────────────────────────────────────

. pscript

TYPE_SPEED=35
NO_WAIT=false
DEMO_PROMPT="${GREEN}➜ ${CYAN}\W ${COLOR_RESET}"

EXPORT_DIR="${PWD}/voyager-data"
LOG_DIR="${EXPORT_DIR}/demo-logs"
mkdir -p "${EXPORT_DIR}" "${LOG_DIR}"

clear

# ── Scene 1: Show the source data ────────────────────────────────────────────

p "=== 'Zero-Downtime Live Migration' — PostgreSQL → YugabyteDB ==="
p ""
p "Source: PostgreSQL (Chinook music store — 11 tables, thousands of rows)"

pe "psql -c \"SELECT relname AS table_name, n_live_tup AS rows
FROM pg_stat_user_tables ORDER BY rows DESC;\""

# ── Scene 2: Assess migration ─────────────────────────────────────────────────

p ""
p "--- Step 0: Assess Migration ---"

pe "yb-voyager assess-migration --export-dir ${EXPORT_DIR} \
  --source-db-type ${SRC_DB_TYPE} \
  --source-db-host ${SRC_HOST} \
  --source-db-user ${SRC_USER} \
  --source-db-password ${SRC_SECRET} \
  --source-db-name ${SRC_DB_ID} \
  --source-db-schema ${SOURCE_DB_SCHEMA}"

# ── Scene 3: Export + import schema ──────────────────────────────────────────

p ""
p "--- Step 1: Export Schema ---"

pe "yb-voyager export schema --export-dir ${EXPORT_DIR} \
  --source-db-type ${SRC_DB_TYPE} \
  --source-db-host ${HOST} \
  --source-db-user ${SRC_USER} \
  --source-db-password ${SRC_SECRET} \
  --source-db-name ${SRC_DB_ID} \
  --source-db-schema ${SOURCE_DB_SCHEMA}"

p ""
p "--- Step 2: Analyse Schema ---"

pe "yb-voyager analyze-schema --export-dir ${EXPORT_DIR} --output-format txt"

p ""
p "--- Step 3: Import Schema to YugabyteDB ---"

pe "yb-voyager import schema --export-dir ${EXPORT_DIR} \
  --target-db-host ${HOST} \
  --target-db-user ${TARGET_USER} \
  --target-db-password ${TARGET_SECRET} \
  --target-db-name ${TARGET_DB_ID} \
  --target-db-schema ${SCHEMA}"

# ── Scene 4: Start live export + import (background) ─────────────────────────

p ""
p "--- Step 4: Start Export (snapshot + continuous CDC changes) ---"
p "This process runs until cutover. Starting it in the background..."

yb-voyager export data from source --export-dir "${EXPORT_DIR}" \
  --source-db-type "${SRC_DB_TYPE}" \
  --source-db-host "${HOST}" \
  --source-db-user "${SRC_USER}" \
  --source-db-password "${SRC_SECRET}" \
  --source-db-name "${SRC_DB_ID}" \
  --source-db-schema "${SOURCE_DB_SCHEMA}" \
  --export-type snapshot-and-changes \
  > "${LOG_DIR}/export.log" 2>&1 &

EXPORT_PID=$!
echo "   Export running (PID ${EXPORT_PID}) → ${LOG_DIR}/export.log"

sleep 5

p ""
p "--- Step 5: Start Import (apply to YugabyteDB continuously) ---"
p "This process runs alongside export. Starting it in the background..."

yb-voyager import data to target --export-dir "${EXPORT_DIR}" \
  --target-db-host "${HOST}" \
  --target-db-user "${TARGET_USER}" \
  --target-db-password "${TARGET_SECRET}" \
  --target-db-name "${TARGET_DB_ID}" \
  --target-db-schema "${SCHEMA}" \
  > "${LOG_DIR}/import.log" 2>&1 &

IMPORT_PID=$!
echo "   Import running (PID ${IMPORT_PID}) → ${LOG_DIR}/import.log"

sleep 10

# ── Scene 5: Show data landing in YugabyteDB ──────────────────────────────────

p ""
p "--- Snapshot data arriving in YugabyteDB ---"

pe "ysqlsh -c \"SELECT relname AS table_name, n_live_tup AS rows
FROM pg_stat_user_tables
WHERE n_live_tup > 0 ORDER BY rows DESC LIMIT 8;\""

# ── Scene 6: Live writes while migration streams ───────────────────────────────

p ""
p "--- Live writes on the source — app keeps running during migration ---"

pe "psql -c \"INSERT INTO public.\\\"Artist\\\" (\\\"ArtistId\\\", \\\"Name\\\") VALUES (999, 'YugabyteDB Band');\""

sleep 8

p "Change has been streamed to YugabyteDB:"

pe "ysqlsh -c \"SELECT * FROM public.\\\"Artist\\\" WHERE \\\"ArtistId\\\" = 999;\""

# ── Scene 7: Get migration report ─────────────────────────────────────────────

p ""
p "--- Step 6: Get Migration Report (lag check before cutover) ---"

pe "yb-voyager get data-migration-report --export-dir ${EXPORT_DIR} \
  --target-db-password ${TARGET_SECRET}"

# ── Scene 8: Cutover ──────────────────────────────────────────────────────────

p ""
p "--- Step 7: Initiate Cutover ---"
p "Stops new writes to PostgreSQL; drains remaining WAL to YugabyteDB."

pe "yb-voyager initiate cutover to target --export-dir ${EXPORT_DIR} \
  --prepare-for-fall-back false"

pe "yb-voyager cutover status --export-dir ${EXPORT_DIR}"

# Wait for background processes to finish
wait "${EXPORT_PID}" 2>/dev/null || true
wait "${IMPORT_PID}" 2>/dev/null || true

# ── Scene 9: Finalise schema ──────────────────────────────────────────────────

p ""
p "--- Step 8: Finalise Schema (indexes, triggers, materialized views) ---"

pe "yb-voyager finalize-schema-post-data-import --export-dir ${EXPORT_DIR} \
  --target-db-host ${HOST} \
  --target-db-user ${TARGET_USER} \
  --target-db-password ${TARGET_SECRET} \
  --target-db-name ${TARGET_DB_ID} \
  --target-db-schema ${SCHEMA} \
  --refresh-mviews true"

# ── Scene 10: Archive + end migration ────────────────────────────────────────

p ""
p "--- Step 9: Archive Changes ---"

pe "yb-voyager archive changes --export-dir ${EXPORT_DIR} \
  --policy delete-on-success"

p ""
p "--- Step 10: End Migration ---"

pe "yb-voyager end migration --export-dir ${EXPORT_DIR} \
  --backup-log-files yes \
  --backup-data-files no \
  --backup-schema-files no \
  --save-migration-reports yes \
  --backup-dir ${EXPORT_DIR}/backup"

# ── Scene 11: Final verification ─────────────────────────────────────────────

p ""
p "--- Final Verification ---"

pe "ysqlsh -c \"SELECT relname AS table_name, n_live_tup AS rows
FROM pg_stat_user_tables
ORDER BY rows DESC;\""

p ""
p "✅ Zero-downtime live migration complete."
p "   PostgreSQL → YugabyteDB."
p "   Application was live throughout — snapshot + streaming CDC → cutover."

cmd
p ""
