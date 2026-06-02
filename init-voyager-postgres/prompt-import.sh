#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# yb-voyager-import shell  —  Step 3 then Step 5
#
#   Step 3  Import schema into YugabyteDB (run once, after Step 2)
#
#   ⚠  Before Step 5: return to yb-voyager-export shell and start Step 4.
#      Step 5 runs in PARALLEL with Step 4.
#
#   Step 5  Import data to target — applies snapshot + CDC changes
#           Runs in the FOREGROUND alongside Step 4.
#           Proceed to yb-voyager-wa shell when both are streaming.
# ─────────────────────────────────────────────────────────────────────────────

. pscript

TYPE_SPEED=35
NO_WAIT=false
DEMO_PROMPT="${GREEN}➜ ${CYAN}\W ${COLOR_RESET}"

EXPORT_DIR="/workspaces/ybdb-vanguard/voyager-data"
mkdir -p "${EXPORT_DIR}"

clear

p "=== yb-voyager-import: Step 3 + Step 5 ==="

# ── Step 3: Import schema ─────────────────────────────────────────────────────

p ""
p "--- Step 3: Import Schema to YugabyteDB ---"
p "Creates tables, sequences, and base constraints (no indexes yet)."

pe "yb-voyager import schema \
  --export-dir ${EXPORT_DIR} \
  --target-db-host 127.0.0.1 \
  --target-db-user ${TARGET_USER:-yugabyte} \
  --target-db-password ${TARGET_SECRET:-yugabyte} \
  --target-db-name ${TARGET_DB_ID:-yugabyte} \
  --target-db-schema ${SCHEMA:-public}"

pe "ysqlsh -h 127.0.0.1 -c \"\dt public.*\" | head -20"

# ── Step 4 reminder ───────────────────────────────────────────────────────────

p ""
p "─────────────────────────────────────────────────────────────"
p "  ⚠  Return to yb-voyager-export shell and press ENTER to"
p "     start Step 4 (export data from source)."
p "  Once export is streaming, come back here and press ENTER."
p "─────────────────────────────────────────────────────────────"

cmd

# ── Step 5: Import data to target (streaming, foreground) ────────────────────

p ""
p "--- Step 5: Import Data to Target ---"
p "Applies snapshot rows and ongoing CDC changes to YugabyteDB."
p "Runs alongside Step 4. Proceed to yb-voyager-wa when both are streaming."

pe "yb-voyager import data to target \
  --export-dir ${EXPORT_DIR} \
  --target-db-host 127.0.0.1 \
  --target-db-user ${TARGET_USER:-yugabyte} \
  --target-db-password ${TARGET_SECRET:-yugabyte} \
  --target-db-name ${TARGET_DB_ID:-yugabyte} \
  --target-db-schema ${SCHEMA:-public}"

p ""
p "Import complete or cutover initiated."
