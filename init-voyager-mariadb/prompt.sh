#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# YugabyteDB Voyager demo  —  "The MariaDB Migration"
#
# Same offline workflow as MySQL: assess → export schema → analyse → export
# data → import schema → import data → finalise → end migration.
# ─────────────────────────────────────────────────────────────────────────────

. pscript

TYPE_SPEED=35
NO_WAIT=false
DEMO_PROMPT="${GREEN}➜ ${CYAN}\W ${COLOR_RESET}"

EXPORT_DIR="/workspaces/ybdb-vanguard/init-voyager-mariadb/voyager-data"
mkdir -p "${EXPORT_DIR}"

clear

p "=== 'The MariaDB Migration' — MariaDB → YugabyteDB via yb-voyager ==="
p ""
p "Source: MariaDB (Chinook music store database)"

pe "docker-compose -f init-voyager-mariadb/compose.yml exec mysql \
  mariadb -uroot -p${SRC_SECRET} -e \
  'SELECT table_name, table_rows FROM information_schema.tables WHERE table_schema=\"Chinook\" ORDER BY table_rows DESC;'"

p ""
p "--- Step 1: Assess Migration ---"

pe "yb-voyager assess-migration --export-dir ${EXPORT_DIR} \
  --source-db-type ${SRC_DB_TYPE} \
  --source-db-host ${SRC_HOST:-mariadb} \
  --source-db-user ${SRC_USER} \
  --source-db-password ${SRC_SECRET} \
  --source-db-name ${SRC_DB_ID}"

p ""
p "--- Step 2: Export Schema ---"

pe "yb-voyager export schema --export-dir ${EXPORT_DIR} \
  --source-db-type ${SRC_DB_TYPE} \
  --source-db-host ${SRC_HOST:-mariadb} \
  --source-db-user ${SRC_USER} \
  --source-db-password ${SRC_SECRET} \
  --source-db-name ${SRC_DB_ID}"

p ""
p "--- Step 3: Analyse Schema ---"

pe "yb-voyager analyze-schema --export-dir ${EXPORT_DIR} --output-format txt"

p ""
p "--- Step 4: Export Data ---"

pe "yb-voyager export data --export-dir ${EXPORT_DIR} \
  --source-db-type ${SRC_DB_TYPE} \
  --source-db-host ${SRC_HOST:-mariadb} \
  --source-db-user ${SRC_USER} \
  --source-db-password ${SRC_SECRET} \
  --source-db-name ${SRC_DB_ID}"

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

pe "ysqlsh -h 127.0.0.1 -c \"SELECT COUNT(*) AS tracks FROM public.\\\"Track\\\"; \
              SELECT COUNT(*) AS artists FROM public.\\\"Artist\\\";\""

p ""
p "--- Step 9: End Migration ---"

pe "yb-voyager end migration --export-dir ${EXPORT_DIR} \
  --backup-log-files yes \
  --backup-data-files no \
  --backup-schema-files yes \
  --save-migration-reports yes \
  --backup-dir ${EXPORT_DIR}/backup"

p ""
p "✅ MariaDB → YugabyteDB migration complete."

cmd
p ""
