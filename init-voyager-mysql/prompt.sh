#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# YugabyteDB Voyager demo  —  "The MySQL Migration"
#
# Scenario: The Chinook music store runs on MySQL. The team migrates it to
# YugabyteDB using yb-voyager's offline migration workflow: assess → export
# schema → analyse → export data → import schema → import data → finalise.
#
# Pre-requisites (handled by postStartCommand):
#   - YugabyteDB running on :5433
#   - MySQL running in Docker on :3306 (Chinook already loaded)
#   - yb-voyager installed at /usr/local/bin/yb-voyager
# ─────────────────────────────────────────────────────────────────────────────

. pscript
set -f  # disable filename expansion — prevents SELECT * glob-expanding in eval $@

TYPE_SPEED=35
NO_WAIT=false
DEMO_PROMPT="${GREEN}➜ ${CYAN}\W ${COLOR_RESET}"

EXPORT_DIR="/workspaces/ybdb-vanguard/init-voyager-mysql/voyager-data"
mkdir -p "${EXPORT_DIR}"

clear

# ── Scene 1: Show the source data ────────────────────────────────────────────

p "=== 'The MySQL Migration' — MySQL → YugabyteDB via yb-voyager ==="
p ""
p "Source: MySQL (Chinook music store database)"

pe "docker-compose -f compose.yml exec mysql \
  mysql -uroot -p${SRC_SECRET} -e \
  'SELECT table_name, table_rows FROM information_schema.tables WHERE table_schema=\"Chinook\" ORDER BY table_rows DESC;'"

# ── Scene 2: Assess migration ─────────────────────────────────────────────────

p ""
p "--- Step 1: Assess Migration ---"
p "yb-voyager inspects the MySQL schema and flags any incompatibilities."

pe "yb-voyager assess-migration --export-dir ${EXPORT_DIR} \
  --source-db-type ${SRC_DB_TYPE} \
  --source-db-host ${SRC_HOST:-mysql} \
  --source-db-user ${SRC_USER} \
  --source-db-password ${SRC_SECRET} \
  --source-db-name ${SRC_DB_ID}"

p "Assessment report saved to ${EXPORT_DIR}/reports/"

# ── Scene 3: Export schema ────────────────────────────────────────────────────

p ""
p "--- Step 2: Export Schema ---"

pe "yb-voyager export schema --export-dir ${EXPORT_DIR} \
  --source-db-type ${SRC_DB_TYPE} \
  --source-db-host ${SRC_HOST:-mysql} \
  --source-db-user ${SRC_USER} \
  --source-db-password ${SRC_SECRET} \
  --source-db-name ${SRC_DB_ID}"

pe "ls ${EXPORT_DIR}/schema/"

# ── Scene 4: Analyse schema ───────────────────────────────────────────────────

p ""
p "--- Step 3: Analyse Schema ---"
p "yb-voyager rewrites the exported DDL for YugabyteDB compatibility."

pe "yb-voyager analyze-schema --export-dir ${EXPORT_DIR} --output-format txt"

pe "cat ${EXPORT_DIR}/reports/schema_analysis_report.txt 2>/dev/null | head -30 || \
    ls ${EXPORT_DIR}/reports/"

# ── Scene 5: Export data ──────────────────────────────────────────────────────

p ""
p "--- Step 4: Export Data ---"
p "Takes a consistent snapshot of all tables."

pe "yb-voyager export data --export-dir ${EXPORT_DIR} \
  --source-db-type ${SRC_DB_TYPE} \
  --source-db-host ${SRC_HOST:-mysql} \
  --source-db-user ${SRC_USER} \
  --source-db-password ${SRC_SECRET} \
  --source-db-name ${SRC_DB_ID}"

pe "yb-voyager export data status --export-dir ${EXPORT_DIR}"

# ── Scene 6: Import schema ────────────────────────────────────────────────────

p ""
p "--- Step 5: Import Schema ---"
p "Creates tables, sequences, and base constraints in YugabyteDB."

pe "yb-voyager import schema --export-dir ${EXPORT_DIR} \
  --target-db-host 127.0.0.1 \
  --target-db-user ${TARGET_USER} \
  --target-db-password ${TARGET_SECRET} \
  --target-db-name ${TARGET_DB_ID} \
  --target-db-schema ${SCHEMA}"

pe "ysqlsh -h 127.0.0.1 -c \"\dt\" | head -20"

# ── Scene 7: Import data ──────────────────────────────────────────────────────

p ""
p "--- Step 6: Import Data ---"
p "Loads the exported snapshot into YugabyteDB."

pe "yb-voyager import data --export-dir ${EXPORT_DIR} \
  --target-db-host 127.0.0.1 \
  --target-db-user ${TARGET_USER} \
  --target-db-password ${TARGET_SECRET} \
  --target-db-name ${TARGET_DB_ID} \
  --target-db-schema ${SCHEMA}"

pe "yb-voyager import data status --export-dir ${EXPORT_DIR}"

# ── Scene 8: Finalise schema ──────────────────────────────────────────────────

p ""
p "--- Step 7: Finalise Schema ---"
p "Creates indexes and triggers that were deferred until after data load."

pe "yb-voyager finalize-schema-post-data-import --export-dir ${EXPORT_DIR} \
  --target-db-host 127.0.0.1 \
  --target-db-user ${TARGET_USER} \
  --target-db-password ${TARGET_SECRET} \
  --target-db-name ${TARGET_DB_ID} \
  --target-db-schema ${SCHEMA}"

# ── Scene 9: Verify ───────────────────────────────────────────────────────────

p ""
p "--- Step 8: Verify row counts in YugabyteDB ---"

pe "ysqlsh -h 127.0.0.1 -c \"
SELECT table_name,
       (xpath('/row/c/text()', query_to_xml('SELECT COUNT(*) AS c FROM ' || quote_ident(table_name), false, true, '')))[1]::text::int AS rows
FROM information_schema.tables
WHERE table_schema = 'public' AND table_type = 'BASE TABLE'
ORDER BY rows DESC;\""

# ── Scene 10: End migration ───────────────────────────────────────────────────

p ""
p "--- Step 9: End Migration ---"
p "Archives logs and reports; cleans up the export directory."

pe "yb-voyager end migration --export-dir ${EXPORT_DIR} \
  --backup-log-files yes \
  --backup-data-files no \
  --backup-schema-files yes \
  --save-migration-reports yes \
  --backup-dir ${EXPORT_DIR}/backup"

p ""
p "✅ Migration complete — Chinook is now running on YugabyteDB."
p "   MySQL rows → YugabyteDB rows. Zero application changes required."

cmd
p ""
