#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# yb-voyager-export shell  —  Steps 0–2 then Step 4
#
#   Step 0  Assess migration compatibility
#   Step 1  Export schema from PostgreSQL
#   Step 2  Analyze schema for YugabyteDB compatibility
#
#   ⚠  Before Step 4: switch to yb-voyager-import shell and run Step 3
#      (import schema) first, then return here for Step 4.
#
#   Step 4  Export data from source — streams snapshot + CDC changes
#           This process runs in the FOREGROUND until cutover.
#           While it streams, start Step 5 in the yb-voyager-import shell.
# ─────────────────────────────────────────────────────────────────────────────

. pscript
set -f  # disable filename expansion — prevents SELECT * glob-expanding in eval $@

TYPE_SPEED=70
NO_WAIT=false
DEMO_PROMPT="${GREEN}➜ ${CYAN}\W ${COLOR_RESET}"

# Use the absolute path set in devcontainer containerEnv.
# The hardcoded fallback ensures this works even without a rebuild.
EXPORT_DIR="${VOYAGER_EXPORT_DIR:-/workspaces/ybdb-vanguard/voyager-data}"
mkdir -p "${EXPORT_DIR}"

clear

p "=== yb-voyager-export: Steps 0–2 + Step 4 ==="
p ""
p "Target: YugabyteDB on 127.0.0.1:5433"
p "Source: PostgreSQL at ${SRC_HOST:-postgres}:5432"

# ── Step 0: Assess ────────────────────────────────────────────────────────────

p ""
p "--- Step 0: Assess Migration ---"
p "yb-voyager inspects the source schema and flags incompatibilities."

pe "yb-voyager assess-migration \
  --export-dir ${EXPORT_DIR} \
  --source-db-type ${SRC_DB_TYPE:-postgresql} \
  --source-db-host ${SRC_HOST:-postgres} \
  --source-db-user ${SRC_USER:-postgres} \
  --source-db-password ${SRC_SECRET:-yugabyte} \
  --source-db-name ${SRC_DB_ID:-Chinook} \
  --source-db-schema ${SOURCE_DB_SCHEMA:-public}"

pe "ls ${EXPORT_DIR}/reports/ 2>/dev/null || echo '(report generated above)'"

# ── Step 1: Export schema ─────────────────────────────────────────────────────

p ""
p "--- Step 1: Export Schema ---"

pe "yb-voyager export schema \
  --export-dir ${EXPORT_DIR} \
  --source-db-type ${SRC_DB_TYPE:-postgresql} \
  --source-db-host ${SRC_HOST:-postgres} \
  --source-db-user ${SRC_USER:-postgres} \
  --source-db-password ${SRC_SECRET:-yugabyte} \
  --source-db-name ${SRC_DB_ID:-Chinook} \
  --source-db-schema ${SOURCE_DB_SCHEMA:-public}"

pe "ls ${EXPORT_DIR}/schema/"

# ── Step 2: Analyze schema ────────────────────────────────────────────────────

p ""
p "--- Step 2: Analyze Schema ---"
p "yb-voyager rewrites DDL for YugabyteDB compatibility."

pe "yb-voyager analyze-schema \
  --export-dir ${EXPORT_DIR} \
  --output-format txt"

pe "cat ${EXPORT_DIR}/reports/schema_analysis_report.txt 2>/dev/null | head -40 \
    || ls ${EXPORT_DIR}/reports/"

# ── Step 3 reminder ───────────────────────────────────────────────────────────

p ""
p "─────────────────────────────────────────────────────────────"
p "  ⚠  Switch to yb-voyager-import shell and run Step 3 now:"
p "       bash prompt-import.sh"
p "  Then return here and press ENTER to start Step 4."
p "─────────────────────────────────────────────────────────────"

cmd

# ── Step 4: Export data from source (streaming, foreground) ──────────────────

p ""
p "--- Step 4: Export Data from Source ---"
p "Streams a consistent snapshot then continuously ships WAL changes."
p "This process runs until cutover. Keep this terminal visible."

pe "yb-voyager export data from source \
  --export-dir ${EXPORT_DIR} \
  --source-db-type ${SRC_DB_TYPE:-postgresql} \
  --source-db-host ${SRC_HOST:-postgres} \
  --source-db-user ${SRC_USER:-postgres} \
  --source-db-password ${SRC_SECRET:-yugabyte} \
  --source-db-name ${SRC_DB_ID:-Chinook} \
  --source-db-schema ${SOURCE_DB_SCHEMA:-public} \
  --export-type snapshot-and-changes"

p ""
p "Export complete or cutover initiated."
