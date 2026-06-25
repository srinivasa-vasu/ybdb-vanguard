#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# YugabyteDB xCluster Replication demo  —  "The Active-Standby Setup"
#
# Automatic transactional xCluster with DDL replication (v2025.2.1+)
#
# In automatic mode:
#   • DDL (CREATE TABLE, ALTER TABLE, DROP TABLE …) runs ONLY on the primary
#   • The replication layer propagates schema changes to the standby
#   • No manual DDL on the standby ever required
#
# Two single-node clusters on this machine:
#   Primary  →  127.0.0.1    (active, accepts writes + DDL)
#   Standby  →  127.0.0.11   (replica, read-only consumer)
#
# Setup workflow (docs: async-transactional-setup-automatic):
#   1. create_xcluster_checkpoint  — mark WAL position, declare databases
#   2. Backup primary → restore to standby (skippable for empty databases)
#   3. Enable PITR on standby        — required for failover consistency
#   4. setup_xcluster_replication    — start replication
#
# NOTE: xCluster DR (one-click switchover orchestration) requires
#       YugabyteDB Anywhere. This demo shows the equivalent manual steps.
# ─────────────────────────────────────────────────────────────────────────────

. pscript

TYPE_SPEED=70
NO_WAIT=false
DEMO_PROMPT="${GREEN}➜ ${CYAN}\W ${COLOR_RESET}"

SRC="127.0.0.1"
TGT="127.0.0.11"
SRC_MASTERS="${SRC}:7100"
TGT_MASTERS="${TGT}:7100"
REPLICATION_ID="demo"
DB="yugabyte"
# ysql_dump lives in postgres/bin, which is not on the default PATH
export PATH="/usr/local/yugabyte/postgres/bin:${PATH}"

clear

# ── Quiet cleanup: tear down any prior run state ──────────────────────────────
# Drop replication (ignore errors if no group exists)
yb-admin --master_addresses "${SRC_MASTERS}" drop_xcluster_replication "${REPLICATION_ID}" "${TGT_MASTERS}" 2>/dev/null || true
rm -f /tmp/yugabyte_snapshot.json /tmp/${DB}_schema.sql
# Delete snapshot schedules on standby (leave PITR clean for next run)
for _sched_id in $(yb-admin --master_addresses "${TGT_MASTERS}" list_snapshot_schedules 2>/dev/null \
    | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'); do
  yb-admin --master_addresses "${TGT_MASTERS}" delete_snapshot_schedule "${_sched_id}" 2>/dev/null || true
done
# Drop tables and databases created by the demo
ysqlsh -h "${SRC}" -c "DROP TABLE IF EXISTS products, employees CASCADE;" 2>/dev/null || true
ysqlsh -h "${TGT}" -c "DROP TABLE IF EXISTS products, employees CASCADE;" 2>/dev/null || true
ysqlsh -h "${SRC}" -c "DROP DATABASE IF EXISTS new_db;" 2>/dev/null || true
ysqlsh -h "${TGT}" -c "DROP DATABASE IF EXISTS new_db;" 2>/dev/null || true

p "=== YugabyteDB xCluster: Automatic Transactional Replication ==="
p ""
p "Primary  (active): ${SRC}:5433   masters: ${SRC_MASTERS}"
p "Standby  (DR):     ${TGT}:5433   masters: ${TGT_MASTERS}"
p ""
p "Requires v2025.2.1+.  Both clusters in this devcontainer qualify."

# ─────────────────────────────────────────────────────────────────────────────
# PART 1: Create checkpoint on Primary
# ─────────────────────────────────────────────────────────────────────────────

p ""
p "━━━ Part 1: Create xCluster Checkpoint ━━━"
p ""
p "Pause DDL on primary, then create a checkpoint."
p "The checkpoint marks the WAL position replication will start from."
p "automatic_ddl_mode instructs the cluster to replicate DDL automatically."

pe "yb-admin --master_addresses ${SRC_MASTERS} \
  create_xcluster_checkpoint ${REPLICATION_ID} ${DB} automatic_ddl_mode"

p ""
p "--- yugabyted equivalent (same operation, simpler syntax) ---"
p "  yugabyted xcluster create_checkpoint"
p "    --replication_id ${REPLICATION_ID}"
p "    --databases ${DB}"
p "    --automatic_mode"

# ─────────────────────────────────────────────────────────────────────────────
# PART 2: Bootstrap standby with primary's data
# ─────────────────────────────────────────────────────────────────────────────

p ""
p "━━━ Part 2: Bootstrap Standby (Distributed Snapshot) ━━━"
p ""
p "Seed data on primary so the backup is meaningful."

pe "ysqlsh -h ${SRC} -c \"
  CREATE TABLE products (id SERIAL PRIMARY KEY, name TEXT, price NUMERIC(10,2));
  INSERT INTO products VALUES (1,'Widget',9.99),(2,'Gadget',24.99),(3,'Doohickey',4.99);\""

p ""
p "Create a distributed snapshot on the primary:"
pe "yb-admin --master_addresses ${SRC_MASTERS} create_database_snapshot ysql.${DB}"

# Wait for COMPLETE and capture snapshot ID
sleep 5
_SNAP_ID=$(yb-admin --master_addresses "${SRC_MASTERS}" list_snapshots 2>/dev/null | \
  awk '/COMPLETE/{print $1}' | grep -E '^[0-9a-f]{8}-' | head -1)

p ""
p "Confirm snapshot is COMPLETE:"
pe "yb-admin --master_addresses ${SRC_MASTERS} list_snapshots"

p ""
p "Export snapshot metadata:"
pe "yb-admin --master_addresses ${SRC_MASTERS} export_snapshot ${_SNAP_ID} /tmp/yugabyte_snapshot.json"

p ""
p "Back up schema from primary (includes ddl_queue and other xCluster system tables):"
pe "ysql_dump -h ${SRC} --include-yb-metadata --serializable-deferrable --schema-only --dbname ${DB} --file /tmp/${DB}_schema.sql"

p ""
p "Restore schema on standby (creates matching table structures for import):"
pe "ysqlsh -h ${TGT} -d ${DB} --file /tmp/${DB}_schema.sql"

p ""
p "Import snapshot on standby — maps source tablets → standby tablets:"
_IMPORT_OUT=$(yb-admin --master_addresses "${TGT_MASTERS}" import_snapshot /tmp/yugabyte_snapshot.json ${DB} 2>&1)
pe "yb-admin --master_addresses ${TGT_MASTERS} import_snapshot /tmp/yugabyte_snapshot.json ${DB}"

# import_snapshot output is columnar: "Object [name] OldID  NewID"
# Old and New IDs are always the last two whitespace-separated fields per row.
# Table/tablet IDs are 32-char hex (no dashes); snapshot IDs are UUID.
# Using awk $(NF-1)/$NF avoids the UUID regex that misses plain hex IDs.
_RESTORE_ID=$(echo "${_IMPORT_OUT}" | awk '/^Snapshot/{print $NF}')
_OLD_TABLE=$(echo "${_IMPORT_OUT}" | awk '/^Table /{print $(NF-1); exit}')
_NEW_TABLE=$(echo "${_IMPORT_OUT}" | awk '/^Table /{print $NF; exit}')

# Copy SST files from source tablet snapshots to standby tablet directories
_SRC_ROCKSDB="${PWD}/ybdb/source/data/yb-data/tserver/data/rocksdb"
_TGT_ROCKSDB="${PWD}/ybdb/target/data/yb-data/tserver/data/rocksdb"

while IFS= read -r _tline; do
  _OLD_TAB=$(echo "${_tline}" | awk '{print $(NF-1)}')
  _NEW_TAB=$(echo "${_tline}" | awk '{print $NF}')
  if [ -n "${_OLD_TAB}" ] && [ -n "${_NEW_TAB}" ]; then
    _src_snap="${_SRC_ROCKSDB}/table-${_OLD_TABLE}/tablet-${_OLD_TAB}.snapshots/${_SNAP_ID}"
    # Target uses _RESTORE_ID: restore_snapshot looks for files keyed by the new snapshot ID
    _tgt_snap="${_TGT_ROCKSDB}/table-${_NEW_TABLE}/tablet-${_NEW_TAB}.snapshots/${_RESTORE_ID}"
    mkdir -p "${_tgt_snap}"
    [ -d "${_src_snap}" ] && cp -r "${_src_snap}/." "${_tgt_snap}/"
  fi
done <<< "$(echo "${_IMPORT_OUT}" | grep -E '^Tablet ')"

p ""
p "SST files copied: source tablet snapshots → standby tablet directories."
p "(Production: transfer via S3/GCS. Devcontainer: local cp, shared filesystem.)"

p ""
p "Restore snapshot on standby:"
pe "yb-admin --master_addresses ${TGT_MASTERS} restore_snapshot ${_RESTORE_ID}"

sleep 3
p ""
p "Verify products data arrived on standby:"
pe "ysqlsh -h ${TGT} -c 'SELECT id, name, price FROM products ORDER BY id;'"

# ─────────────────────────────────────────────────────────────────────────────
# PART 3: Enable PITR on Standby (required for failover)
# ─────────────────────────────────────────────────────────────────────────────

p ""
p "━━━ Part 3: Enable PITR on Standby ━━━"
p ""
p "PITR on the standby provides a consistent recovery point during failover."
p "Retention must exceed expected primary downtime (use 60+ minutes in prod)."
p "For this demo: 2-minute snapshot interval, 30-minute retention."

pe "yb-admin --master_addresses ${TGT_MASTERS} \
  create_snapshot_schedule 2 30 ysql.${DB}"

p ""
p "--- yugabyted equivalent ---"
p "  yugabyted configure point_in_time_recovery"
p "    --enable --retention '30m' --database ${DB}"

p ""
p "Verify PITR schedule on standby:"
pe "yb-admin --master_addresses ${TGT_MASTERS} list_snapshot_schedules"

# ─────────────────────────────────────────────────────────────────────────────
# PART 4: Set up replication
# ─────────────────────────────────────────────────────────────────────────────

p ""
p "━━━ Part 4: Setup xCluster Replication ━━━"
p ""
p "Run on the PRIMARY: points it at the standby master addresses."
p "Unlike the old setup_universe_replication (table-level), this command"
p "operates at the DATABASE level."

pe "yb-admin --master_addresses ${SRC_MASTERS} \
  setup_xcluster_replication ${REPLICATION_ID} ${TGT_MASTERS}"

p ""
p "--- yugabyted equivalent ---"
p "  yugabyted xcluster set_up"
p "    --replication_id ${REPLICATION_ID}"
p "    --target_address ${TGT}"
p "    --bootstrap_done"

p ""
p "--- Verify replication is healthy ---"
pe "echo 'SELECT yb_xcluster_ddl_replication.get_replication_role();' | ysqlsh -h ${SRC}"
pe "echo 'SELECT yb_xcluster_ddl_replication.get_replication_role();' | ysqlsh -h ${TGT}"

# ─────────────────────────────────────────────────────────────────────────────
# PART 5: Check replication role on each cluster
# ─────────────────────────────────────────────────────────────────────────────

p ""
p "━━━ Part 5: Check Replication Role ━━━"
p ""
p "In automatic DDL mode, each cluster knows its role."
p "'source' = primary (writable), 'subscriber' = standby (read-only)."

pe "echo 'SELECT yb_xcluster_ddl_replication.get_replication_role();' | ysqlsh -h ${SRC}"

pe "echo 'SELECT yb_xcluster_ddl_replication.get_replication_role();' | ysqlsh -h ${TGT}"

# ─────────────────────────────────────────────────────────────────────────────
# PART 6: DDL on PRIMARY auto-replicates to Standby
# ─────────────────────────────────────────────────────────────────────────────

p ""
p "━━━ Part 6: Automatic DDL Replication ━━━"
p ""
p "Run CREATE TABLE ONLY on the primary."
p "The standby receives the schema change automatically — no manual DDL."

pe "ysqlsh -h ${SRC} -c \"
CREATE TABLE employees (
  id         SERIAL  PRIMARY KEY,
  name       TEXT    NOT NULL,
  department TEXT,
  salary     NUMERIC
);\""

p "Waiting 3s for DDL to propagate..."
sleep 3

p ""
p "--- Standby: did the table appear? ---"
pe "ysqlsh -h ${TGT} -c \"\dt public.*\""

p "The table exists on the standby — zero manual DDL needed."

# ─────────────────────────────────────────────────────────────────────────────
# PART 7: Data replication
# ─────────────────────────────────────────────────────────────────────────────

p ""
p "━━━ Part 7: Data Replication ━━━"

(set -f; pe "ysqlsh -h ${SRC} -c \"
INSERT INTO employees(name, department, salary) VALUES
  ('Alice', 'Engineering', 120000),
  ('Bob',   'Marketing',    95000),
  ('Carol', 'Engineering', 130000);\""
)

sleep 3

pe "ysqlsh -h ${TGT} -c \"SELECT id, name, department, salary FROM employees ORDER BY id;\""

p "All 3 rows replicated to standby."

# ─────────────────────────────────────────────────────────────────────────────
# PART 8: ALTER TABLE on primary — auto-replicates
# ─────────────────────────────────────────────────────────────────────────────

p ""
p "━━━ Part 8: Alter Table — DDL Propagation ━━━"
p ""
p "Add a column on the primary ONLY."

pe "ysqlsh -h ${SRC} -c \"ALTER TABLE employees ADD COLUMN email TEXT;\""

sleep 3

p ""
p "--- Check standby schema — was the ALTER replicated? ---"
pe "ysqlsh -h ${TGT} -c \"SELECT column_name, data_type FROM information_schema.columns WHERE table_name='employees' ORDER BY ordinal_position;\""

p "The 'email' column is on the standby — replicated automatically."

# ─────────────────────────────────────────────────────────────────────────────
# PART 9: Replication lag
# ─────────────────────────────────────────────────────────────────────────────

p ""
p "━━━ Part 9: Replication Lag ━━━"
p ""
p "Lag is reported from the SOURCE TServer metrics endpoint."

pe "curl -s 'http://${SRC}:9000/prometheus-metrics' 2>/dev/null \
  | grep -E 'async_replication_(sent|committed)_lag_micros' | head -6"

p ""
p "Near-zero = replication is caught up."
p "async_replication_committed_lag_micros is your RPO proxy."

# ─────────────────────────────────────────────────────────────────────────────
# PART 10: Add a second database to the replication group
# ─────────────────────────────────────────────────────────────────────────────

p ""
p "━━━ Part 10: Add a Database to Replication ━━━"
p ""
p "Replication groups can span multiple databases."
p "Add 'new_db' — DDL and data will replicate once it is added."

pe "ysqlsh -h ${SRC} -c \"CREATE DATABASE new_db;\""
pe "ysqlsh -h ${TGT} -c \"CREATE DATABASE new_db;\""

pe "yb-admin --master_addresses ${SRC_MASTERS} \
  add_namespace_to_xcluster_checkpoint ${REPLICATION_ID} new_db"

pe "yb-admin --master_addresses ${SRC_MASTERS} \
  add_namespace_to_xcluster_replication ${REPLICATION_ID} new_db ${TGT_MASTERS}"

pe "echo 'SELECT yb_xcluster_ddl_replication.get_replication_role();' | ysqlsh -h ${SRC}"

# ─────────────────────────────────────────────────────────────────────────────
# PART 11: Planned failover simulation (manual, without YBA)
# ─────────────────────────────────────────────────────────────────────────────

p ""
p "━━━ Part 11: Planned Failover (manual steps) ━━━"
p ""
p "With YugabyteDB Anywhere this is a single click."
p "Without YBA, the steps are:"
p "  1. Stop writes to primary"
p "  2. Confirm lag reaches zero"
p "  3. Drop replication"
p "  4. Direct application traffic to former standby"
p "  5. Set up reverse replication (optional, for fallback)"

p ""
p "--- Confirm lag is zero before cutting over ---"
pe "curl -s 'http://${SRC}:9000/prometheus-metrics' 2>/dev/null \
  | grep 'async_replication_committed_lag_micros' | head -3"

p ""
p "--- Drop replication ---"
pe "yb-admin --master_addresses ${SRC_MASTERS} \
  drop_xcluster_replication ${REPLICATION_ID} ${TGT_MASTERS}"

p ""
p "--- Both clusters are now independent (no replication) ---"
pe "ysqlsh -h ${TGT} -c \"INSERT INTO employees(name,department,salary,email) VALUES('Dave','Sales',80000,'dave@co.com');\""
pe "ysqlsh -h ${TGT} -c \"SELECT id, name, department FROM employees ORDER BY id;\""
pe "ysqlsh -h ${SRC} -c \"SELECT COUNT(*) AS source_count FROM employees;\""

p "Target has 4 rows (new write succeeded)."
p "Source still has 3 rows (no reverse replication — truly independent now)."

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────

p ""
p "━━━ Summary ━━━"
p ""
p "  yb-admin command                               What it does"
p "  ─────────────────────────────────────────────────────────────────────────"
p "  create_xcluster_checkpoint <id> <db> \\         Mark WAL + declare databases"
p "    automatic_ddl_mode"
p "  create_database_snapshot ysql.<db>             Distributed snapshot (bootstrap)"
p "  export_snapshot <id> <file>                    Export snapshot metadata"
p "  import_snapshot <file> <db>                    Import snapshot on standby"
p "  restore_snapshot <id>                          Restore snapshot on standby"
p "  create_snapshot_schedule <int> <ret> \\         Enable PITR on standby"
p "    ysql.<db>"
p "  setup_xcluster_replication <id> <tgt>          Start replication (DB-level)"
p "  add_namespace_to_xcluster_replication          Add a database"
p "  drop_xcluster_replication <id> <tgt>           Tear down"
p ""
p "  DDL role check:"
p "    SELECT yb_xcluster_ddl_replication.get_replication_role();"
p "    → source (primary)  |  subscriber (standby)"
p ""
p "  Lag:  curl http://PRIMARY:9000/prometheus-metrics"
p "      | grep async_replication_committed_lag_micros"
p ""
p "  Production notes:"
p "  • Backup primary → restore standby before setup_xcluster_replication"
p "  • Pause DDL during setup; resume only after replication is established"
p "  • PITR retention > expected primary downtime"
p "  • xCluster DR (automated switchover) requires YugabyteDB Anywhere"

cmd

p ""
