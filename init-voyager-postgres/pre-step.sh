#!/usr/bin/env bash
# Pre-step — run from the psql shell
# Verifies the PostgreSQL source and shows the Chinook dataset before migration.

. pscript

TYPE_SPEED=40
NO_WAIT=false
DEMO_PROMPT="${GREEN}➜ ${CYAN}\W ${COLOR_RESET}"

clear

p "=== Pre-step: Verify PostgreSQL Source ==="
p ""
p "Source: PostgreSQL (Chinook music store — 11 tables)"

pe "psql -h ${SRC_HOST:-postgres} -c \"\dt public.*\""

pe "psql -h ${SRC_HOST:-postgres} -c \"
SELECT relname AS table_name, n_live_tup AS row_count
FROM pg_stat_user_tables
ORDER BY row_count DESC;\""

p ""
p "Verify WAL level is 'logical' (required for CDC-based live migration):"

pe "psql -h ${SRC_HOST:-postgres} -c \"SHOW wal_level;\""
pe "psql -h ${SRC_HOST:-postgres} -c \"SHOW max_replication_slots;\""
pe "psql -h ${SRC_HOST:-postgres} -c \"SHOW max_wal_senders;\""

p ""
p "✅ Source ready. Switch to yb-voyager-export shell and run: bash prompt.sh"

cmd
