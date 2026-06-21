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

TYPE_SPEED=70
NO_WAIT=false
DEMO_PROMPT="${GREEN}➜ ${CYAN}\W ${COLOR_RESET}"

EXPORT_DIR="/workspaces/ybdb-vanguard/init-voyager-oracle/voyager-data"
mkdir -p "${EXPORT_DIR}"

# Ensure the full Chinook dataset is present (downloaded during postCreateCommand)
if [ ! -f "chinook_data.sql" ]; then
  echo "⚠  Downloading Chinook dataset from source (should have been done at setup)..."
  curl -fsSL "https://raw.githubusercontent.com/lerocha/chinook-database/master/ChinookDatabase/DataSources/Chinook_Oracle.sql" \
    -o chinook_data.sql || { echo "❌ Download failed. Re-open the devcontainer to retry."; exit 1; }
fi

clear

p "=== 'The Oracle Migration' — Oracle → YugabyteDB via yb-voyager ==="
p ""
p "Waiting for Oracle Free to be ready on :1521 (may take 2–3 min)..."

# Wait for Oracle DB to finish initialising — poll the container log for the
# ready signal rather than a TCP check (devcontainer can't reach 127.0.0.1:1521;
# Oracle is on the shared Docker network, reachable only by container name).
_ora_ready=0
for i in $(seq 1 60); do
  if docker logs oracle 2>/dev/null | grep -q 'DATABASE IS READY TO USE'; then
    _ora_ready=1; break
  fi
  printf "\r   %ds elapsed..." "$(( i * 5 ))"
  sleep 5
done
echo ""
if [ "$_ora_ready" -eq 0 ]; then
  echo "❌ Oracle did not become ready. Check: docker-compose -f init-voyager-oracle/compose.yml logs oracle"
  exit 1
fi

p "Oracle is up. Loading the Chinook schema..."

p ""
p "--- Pre-step: Load Chinook into Oracle (chinook schema) ---"
p "Step 1: create the chinook user. Step 2: load the full Chinook dataset."

pe "docker cp chinook.sql oracle:/tmp/chinook_setup.sql"
pe "docker cp chinook_data.sql oracle:/tmp/chinook_data.sql"
pe "docker cp list_tables.sql oracle:/tmp/list_tables.sql"

pe "docker exec oracle sqlplus -S system/${ORACLE_PASSWORD:-YbVanguard1}@//localhost:1521/${ORACLE_PDB} @/tmp/chinook_setup.sql"
pe "docker exec oracle sqlplus -S system/${ORACLE_PASSWORD:-YbVanguard1}@//localhost:1521/${ORACLE_PDB} @/tmp/chinook_data.sql"

p ""
p "Verify source tables in Oracle (chinook schema):"

pe "docker exec oracle sqlplus -S ${SRC_USER}/${SRC_SECRET}@//localhost:1521/${ORACLE_PDB} @/tmp/list_tables.sql"

p ""
p "--- Step 1: Assess Migration ---"

pe "yb-voyager assess-migration --export-dir ${EXPORT_DIR} \
  --source-db-type ${SRC_DB_TYPE} \
  --source-db-host ${SRC_HOST:-oracle} \
  --source-db-user ${SRC_USER} \
  --source-db-password ${SRC_SECRET} \
  --source-db-name ${ORACLE_PDB} \
  --source-db-schema ${SCHEMA}"

p ""
p "--- Step 2: Export Schema ---"

pe "yb-voyager export schema --export-dir ${EXPORT_DIR} \
  --source-db-type ${SRC_DB_TYPE} \
  --source-db-host ${SRC_HOST:-oracle} \
  --source-db-user ${SRC_USER} \
  --source-db-password ${SRC_SECRET} \
  --source-db-name ${ORACLE_PDB} \
  --source-db-schema ${SCHEMA}"

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
  --source-db-name ${ORACLE_PDB} \
  --source-db-schema ${SCHEMA}"

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
p "--- Step 8: End Migration ---"

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
