#!/usr/bin/env bash
# Pre-step — run from the psql shell
# Loads the Chinook dataset into PostgreSQL and verifies the source before migration.

. pscript
set -f  # disable filename expansion

TYPE_SPEED=40
NO_WAIT=false
DEMO_PROMPT="${GREEN}➜ ${CYAN}\W ${COLOR_RESET}"

# Ensure the full Chinook dataset is present (downloaded during postCreateCommand)
if [ ! -f "chinook_data.sql" ]; then
  echo "⚠  Downloading Chinook dataset from source (should have been done at setup)..."
  curl -fsSL "https://raw.githubusercontent.com/lerocha/chinook-database/master/ChinookDatabase/DataSources/Chinook_PostgreSql.sql" \
    -o chinook_data.sql || { echo "❌ Download failed. Re-open the devcontainer to retry."; exit 1; }
fi

# Drop existing chinook DB so the load is idempotent on re-runs
psql -h "${SRC_HOST:-postgres}" -c "DROP DATABASE IF EXISTS ${SRC_DB_ID:-chinook};" 2>/dev/null || true

clear

p "=== Pre-step: Load Chinook into PostgreSQL ==="
p ""
p "Full Chinook dataset: 3 500+ tracks, 412 invoices, 59 customers."

pe "psql -h ${SRC_HOST:-postgres} -f chinook_data.sql"

p ""
p "Source tables loaded:"

pe "psql -h ${SRC_HOST:-postgres} -d ${SRC_DB_ID} -c \"\dt public.*\""

pe "psql -h ${SRC_HOST:-postgres} -d ${SRC_DB_ID} -c \"
SELECT relname AS table_name, n_live_tup AS row_count
FROM pg_stat_user_tables
ORDER BY row_count DESC;\""

p ""
p "Verify WAL level is 'logical' (required for CDC-based live migration):"

pe "psql -h ${SRC_HOST:-postgres} -d ${SRC_DB_ID} -c \"SHOW wal_level;\""
pe "psql -h ${SRC_HOST:-postgres} -d ${SRC_DB_ID} -c \"SHOW max_replication_slots;\""
pe "psql -h ${SRC_HOST:-postgres} -d ${SRC_DB_ID} -c \"SHOW max_wal_senders;\""

p ""
p "✅ Source ready. Switch to yb-voyager-export shell and run: bash prompt.sh"

cmd
