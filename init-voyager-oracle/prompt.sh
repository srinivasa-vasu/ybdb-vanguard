#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# YugabyteDB Voyager demo  —  "The Oracle Migration"
#
# Scenario: The Chinook music store runs on Oracle Free. The team migrates it
# to YugabyteDB using yb-voyager's offline migration workflow.
#
# Note: Oracle Free takes 2–3 minutes to be fully ready after container start.
#       This script waits for it before proceeding.
# ─────────────────────────────────────────────────────────────────────────────

. pscript
set -f  # disable filename expansion — prevents SELECT * glob-expanding in eval $@

TYPE_SPEED=35
NO_WAIT=false
DEMO_PROMPT="${GREEN}➜ ${CYAN}\W ${COLOR_RESET}"

EXPORT_DIR="/workspaces/ybdb-vanguard/init-voyager-oracle/voyager-data"
mkdir -p "${EXPORT_DIR}"

clear

p "=== 'The Oracle Migration' — Oracle → YugabyteDB via yb-voyager ==="
p ""
p "Waiting for Oracle Free to be ready on :1521 (may take 2–3 min)..."

# Pure-bash wait for Oracle
_ora_ready=0
for i in $(seq 1 60); do
  if (echo >/dev/tcp/127.0.0.1/1521) 2>/dev/null; then
    _ora_ready=1; break
  fi
  printf "\r   %ds elapsed..." "$(( i * 3 ))"
  sleep 3
done
echo ""
if [ "$_ora_ready" -eq 0 ]; then
  echo "❌ Oracle did not become ready. Check: docker-compose -f init-voyager-oracle/compose.yml logs oracle"
  exit 1
fi

# Extra wait for the DB to finish initialising (port open ≠ DB ready)
sleep 15

p "Oracle is up. Loading the Chinook schema..."

p ""
p "--- Pre-step: Load Chinook into Oracle ---"
p "Copy the schema to the oracle-client container and run it via SQLPlus."

pe "docker cp init-voyager-oracle/chinook.sql oracle-client:/tmp/chinook.sql"

p "Run from the oracle shell: @/tmp/chinook.sql"
p "(For this demo, assuming Chinook was loaded via the oracle terminal.)"

p ""
p "Verify source tables in Oracle:"

pe "docker exec oracle-client sqlplus -S ${SRC_USER}/${SRC_SECRET}@//oracle:1521/${ORACLE_PDB} <<'EOF'
SELECT table_name FROM all_tables WHERE owner = UPPER('${SRC_USER}') ORDER BY table_name;
EXIT;
EOF"

p ""
p "--- Step 1: Assess Migration ---"

pe "yb-voyager assess-migration --export-dir ${EXPORT_DIR} \
  --source-db-type ${SRC_DB_TYPE} \
  --source-db-host ${SRC_HOST:-oracle} \
  --source-db-user ${SRC_USER} \
  --source-db-password ${SRC_SECRET} \
  --source-db-name ${ORACLE_PDB}"

p ""
p "--- Step 2: Export Schema ---"

pe "yb-voyager export schema --export-dir ${EXPORT_DIR} \
  --source-db-type ${SRC_DB_TYPE} \
  --source-db-host ${SRC_HOST:-oracle} \
  --source-db-user ${SRC_USER} \
  --source-db-password ${SRC_SECRET} \
  --source-db-name ${ORACLE_PDB}"

p ""
p "--- Step 3: Analyse Schema ---"

pe "yb-voyager analyze-schema --export-dir ${EXPORT_DIR} --output-format txt"

p ""
p "--- Step 4: Export Data ---"

pe "yb-voyager export data --export-dir ${EXPORT_DIR} \
  --source-db-type ${SRC_DB_TYPE} \
  --source-db-host ${SRC_HOST:-oracle} \
  --source-db-user ${SRC_USER} \
  --source-db-password ${SRC_SECRET} \
  --source-db-name ${ORACLE_PDB}"

pe "yb-voyager export data status --export-dir ${EXPORT_DIR}"

p ""
p "--- Step 5: Import Schema ---"

pe "yb-voyager import schema --export-dir ${EXPORT_DIR} \
  --target-db-host 127.0.0.1 \
  --target-db-user ${TARGET_USER} \
  --target-db-password ${TARGET_SECRET} \
  --target-db-name ${TARGET_DB_ID} \
  --target-db-schema ${SCHEMA}"

p ""
p "--- Step 6: Import Data ---"

pe "yb-voyager import data --export-dir ${EXPORT_DIR} \
  --target-db-host 127.0.0.1 \
  --target-db-user ${TARGET_USER} \
  --target-db-password ${TARGET_SECRET} \
  --target-db-name ${TARGET_DB_ID} \
  --target-db-schema ${SCHEMA}"

pe "yb-voyager import data status --export-dir ${EXPORT_DIR}"

p ""
p "--- Step 7: Finalise Schema ---"

pe "yb-voyager finalize-schema-post-data-import --export-dir ${EXPORT_DIR} \
  --target-db-host 127.0.0.1 \
  --target-db-user ${TARGET_USER} \
  --target-db-password ${TARGET_SECRET} \
  --target-db-name ${TARGET_DB_ID} \
  --target-db-schema ${SCHEMA}"

p ""
p "--- Step 8: Verify ---"

pe "ysqlsh -h 127.0.0.1 -c \"SELECT schemaname, tablename, n_live_tup AS rows
FROM pg_stat_user_tables
ORDER BY rows DESC LIMIT 10;\""

p ""
p "--- Step 9: End Migration ---"

pe "yb-voyager end migration --export-dir ${EXPORT_DIR} \
  --backup-log-files yes \
  --backup-data-files no \
  --backup-schema-files yes \
  --save-migration-reports yes \
  --backup-dir ${EXPORT_DIR}/backup"

p ""
p "✅ Oracle → YugabyteDB migration complete."

cmd
p ""
