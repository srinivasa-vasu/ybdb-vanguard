#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# start-pubsub-ybdb.sh  --  pub/sub exercise service startup (postStartCommand)
#
# Brings up two single-node YugabyteDB clusters on separate loopback addresses:
#
#   Publisher  (source) : 127.0.0.1   -- CDC source, holds the seeded data
#   Subscriber (target) : 127.0.0.11  -- CDC sink, same schema, zero rows
#
# Both listen on the standard ports; there is no conflict because they bind to
# different addresses. Nothing runs in Docker here -- the applier is started
# later, by the demo or by hand, so that the snapshot can be watched happening.
#
# The publisher runs with ysql_yb_default_replica_identity=FULL so every table
# gets FULL replica identity at creation time. That matters because YugabyteDB
# fixes a table's effective replica identity when the replication slot is
# created: altering it afterwards has no effect on that slot.
# -----------------------------------------------------------------------------
set -euo pipefail

BASE_DIR="${PWD}/${DATA_PATH:-ybdb}"
SOURCE_BASE="${BASE_DIR}/source"
TARGET_BASE="${BASE_DIR}/target"

SRC_HOST="${SRC_HOST:-127.0.0.1}"
TAR_HOST="${TAR_HOST:-127.0.0.11}"
ART_PATH="${ART_PATH:-init-pubsub-ybdb}"

APPLIER_LOG="${APPLIER_LOG:-/tmp/cdc-applier.log}"
APPLIER_PID="${APPLIER_PID:-/tmp/cdc-applier.pid}"

# -- 0. Stop a stale applier from a previous container start ------------------
# It would hold the replication slot and quietly re-apply into the clusters
# this script is about to rebuild.
if [ -f "${APPLIER_PID}" ]; then
    _old=$(cat "${APPLIER_PID}" 2>/dev/null || true)
    [ -n "${_old}" ] && kill "${_old}" 2>/dev/null || true
    rm -f "${APPLIER_PID}"
fi
rm -f "${APPLIER_LOG}"

# -- 1. Sweep stale runtime data from previous exercises ----------------------
echo "🧹 Sweeping stale runtime data from previous exercises..."
rm -rf \
  "${PWD}/ybdb" \
  "${PWD}/voyager-data" \
  "${PWD}/init-ear/keys" \
  "${PWD}/init-cdc-ybdb-pg/kafka-plugins" \
  "${PWD}/init-cdc-sqlserver-ybdb/kafka-plugins" \
  "${PWD}/init-voyager-postgres/voyager-data" \
  "${PWD}/init-voyager-mysql/voyager-data" \
  "${PWD}/init-voyager-mariadb/voyager-data" \
  "${PWD}/init-voyager-oracle/voyager-data" 2>/dev/null || true
mkdir -p "${SOURCE_BASE}" "${TARGET_BASE}"

# -- 2. Loopback alias for the subscriber -------------------------------------
# Linux routes all of 127.0.0.0/8 to lo, but yugabyted needs the address bound
# explicitly before it will listen on it.
sudo ip addr add "${TAR_HOST}/8" dev lo 2>/dev/null || true

_wait_ysql() {
  local host="$1" label="$2"
  for _i in $(seq 1 40); do
    if (echo >/dev/tcp/"${host}"/5433) 2>/dev/null; then
      echo "   ✅ ${label} ready  (${host}:5433)"
      return 0
    fi
    sleep 3
  done
  echo "❌ ${label} (${host}:5433) did not become ready in time." >&2
  return 1
}

# cdc_wal_retention_time_secs keeps WAL around long enough that a slot left
# idle over a coffee break can still resume.
_PUB_TFLAGS="ysql_yb_default_replica_identity=${REPLICA_IDENTITY:-FULL},cdc_wal_retention_time_secs=86400,yb_enable_read_committed_isolation=true"
_SUB_TFLAGS="yb_enable_read_committed_isolation=true"

# -- 3. Publisher -------------------------------------------------------------
echo "🚀 Starting the PUBLISHER cluster on ${SRC_HOST} ..."
echo "   TServer flags: ${_PUB_TFLAGS}"
yugabyted start \
  --base_dir="${SOURCE_BASE}" \
  --advertise_address="${SRC_HOST}" \
  --cloud_location=ybcloud.pandora.az1 \
  --tserver_flags="${_PUB_TFLAGS}" \
  --background=true
_wait_ysql "${SRC_HOST}" "Publisher"

# -- 4. Subscriber ------------------------------------------------------------
echo "🚀 Starting the SUBSCRIBER cluster on ${TAR_HOST} ..."
yugabyted start \
  --base_dir="${TARGET_BASE}" \
  --advertise_address="${TAR_HOST}" \
  --cloud_location=ybcloud.pandora.az2 \
  --tserver_flags="${_SUB_TFLAGS}" \
  --background=true
_wait_ysql "${TAR_HOST}" "Subscriber"

# -- 5. Schema on BOTH sides, data on the publisher only ----------------------
# The applier replicates data and issues no DDL, so the subscriber's schema is
# created here, out of band. Loading the same file on both sides is what makes
# the shapes identical.
echo "📦 Creating the schema on the publisher..."
ysqlsh -h "${SRC_HOST}" -q -f "${ART_PATH}/schema.sql"

echo "📦 Creating the same schema on the subscriber (no rows)..."
ysqlsh -h "${TAR_HOST}" -q -f "${ART_PATH}/schema.sql"

echo "📥 Seeding the publisher (this is what the initial snapshot will copy)..."
ysqlsh -h "${SRC_HOST}" -q -f "${ART_PATH}/seed.sql"

# -- 6. Clear CDC state so a rebuilt container starts from a clean slate -------
ysqlsh -h "${SRC_HOST}" -q -c \
  "SELECT pg_drop_replication_slot(slot_name) FROM pg_replication_slots WHERE slot_name = '${REPL_SLOT:-pubsub_slot}';" \
  2>/dev/null || true
ysqlsh -h "${SRC_HOST}" -q -c "DROP PUBLICATION IF EXISTS ${PUBLICATION:-pubsub_pub};" 2>/dev/null || true
ysqlsh -h "${SRC_HOST}" -q -c "DROP TABLE IF EXISTS public.${OFFSET_TABLE:-cdc_offset};" 2>/dev/null || true
ysqlsh -h "${TAR_HOST}" -q -c "DROP TABLE IF EXISTS public.${APPLY_STATE_TABLE:-cdc_apply_state};" 2>/dev/null || true

echo ""
echo "Publisher  ->  ysqlsh -h ${SRC_HOST}    ($(ysqlsh -h "${SRC_HOST}" -tAc 'SELECT COUNT(*) FROM public.orders;' 2>/dev/null | tr -d '[:space:]') orders seeded)"
echo "Subscriber ->  ysqlsh -h ${TAR_HOST}   ($(ysqlsh -h "${TAR_HOST}" -tAc 'SELECT COUNT(*) FROM public.orders;' 2>/dev/null | tr -d '[:space:]') orders — empty until the applier runs)"
echo "Publisher UI  ->  http://localhost:15433/"
echo ""
echo "The applier is NOT started automatically — starting it is the first step"
echo "of the walkthrough:  cd ${ART_PATH} && bash applier.sh start"
