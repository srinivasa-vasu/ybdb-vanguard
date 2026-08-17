#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# start-pubsub-bidir-ybdb.sh  --  two-way pub/sub startup (postStartCommand)
#
# Brings up two single-node YugabyteDB clusters, each of which is BOTH a
# publisher and a subscriber:
#
#   Site A : 127.0.0.1
#   Site B : 127.0.0.11
#
# Both get the same schema and the same seed rows, because both lanes run with
# snapshot-mode: never. In a two-way topology that is the correct bootstrap:
# a snapshot reads table state rather than WAL, so its rows carry no
# replication origin, the peer lane cannot recognise them as replicated, and
# each site would echo the other's snapshot back.
#
# ── The ordering constraint this script exists to satisfy ────────────────────
# YugabyteDB requires a replication origin to EXIST BEFORE a slot starts
# streaming, or that slot will never report the origin on incoming changes
# (yugabyte-db issue 30068). Each lane creates its own origin on its SINK at
# startup — but the origin a lane needs to SEE is the peer's, created by the
# other lane on the other cluster. Starting the lanes one after another would
# therefore create the second origin after the first lane's slot already
# existed, and the first lane's loop filter would silently never match.
#
# So both origins are created here, up front, before either lane runs:
#
#   on site A : btoa_<b2a-slot>_1   (tags what the B→A lane writes into A)
#   on site B : atob_<a2b-slot>_1   (tags what the A→B lane writes into B)
#
# The appliers check pg_replication_origin before creating, so this is
# idempotent and they simply find them already present.
# -----------------------------------------------------------------------------
set -euo pipefail

BASE_DIR="${PWD}/${DATA_PATH:-ybdb}"
A_BASE="${BASE_DIR}/site-a"
B_BASE="${BASE_DIR}/site-b"

A_HOST="${A_HOST:-127.0.0.1}"
B_HOST="${B_HOST:-127.0.0.11}"
SCHEMA="${SCHEMA:-public}"
ART_PATH="${ART_PATH:-init-pubsub-bidir-ybdb}"

A2B_SLOT="${A2B_SLOT:-a2b_slot}"
B2A_SLOT="${B2A_SLOT:-b2a_slot}"
A2B_PUB="${A2B_PUB:-a2b_pub}"
B2A_PUB="${B2A_PUB:-b2a_pub}"
A2B_ORIGIN="${A2B_ORIGIN:-atob}"
B2A_ORIGIN="${B2A_ORIGIN:-btoa}"
A2B_OFFSET_TABLE="${A2B_OFFSET_TABLE:-cdc_offset_a2b}"
B2A_OFFSET_TABLE="${B2A_OFFSET_TABLE:-cdc_offset_b2a}"
A2B_APPLY_STATE="${A2B_APPLY_STATE:-cdc_apply_state_a2b}"
B2A_APPLY_STATE="${B2A_APPLY_STATE:-cdc_apply_state_b2a}"
A2B_CONFLICT_LOG="${A2B_CONFLICT_LOG:-cdc_conflict_log_a2b}"
B2A_CONFLICT_LOG="${B2A_CONFLICT_LOG:-cdc_conflict_log_b2a}"

# Origin names, composed exactly as OriginNames.lane() does: <prefix>_<slot>_1.
A2B_ORIGIN_FULL="${A2B_ORIGIN}_${A2B_SLOT}_1"
B2A_ORIGIN_FULL="${B2A_ORIGIN}_${B2A_SLOT}_1"

# -- 0. Stop stale lanes from a previous container start -----------------------
for _lane in a2b b2a; do
    _f="/tmp/cdc-applier-${_lane}.pid"
    if [ -f "${_f}" ]; then
        _old=$(cat "${_f}" 2>/dev/null || true)
        [ -n "${_old}" ] && kill "${_old}" 2>/dev/null || true
        rm -f "${_f}"
    fi
done
rm -f "${A2B_LOG:-/tmp/cdc-applier-a2b.log}" "${B2A_LOG:-/tmp/cdc-applier-b2a.log}"

# -- 1. Sweep stale runtime data from previous exercises -----------------------
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
mkdir -p "${A_BASE}" "${B_BASE}"

# -- 2. Loopback alias for site B ---------------------------------------------
sudo ip addr add "${B_HOST}/8" dev lo 2>/dev/null || true

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

# Both sites are publishers, so both need FULL replica identity at table
# creation time — YugabyteDB fixes a table's effective replica identity when
# the slot is created, so a later ALTER would not help.
_TFLAGS="ysql_yb_default_replica_identity=${REPLICA_IDENTITY:-FULL},cdc_wal_retention_time_secs=86400,yb_enable_read_committed_isolation=true"

# -- 3. Site A ----------------------------------------------------------------
echo "🚀 Starting SITE A on ${A_HOST} ..."
echo "   TServer flags: ${_TFLAGS}"
yugabyted start \
  --base_dir="${A_BASE}" \
  --advertise_address="${A_HOST}" \
  --cloud_location=ybcloud.pandora.az1 \
  --tserver_flags="${_TFLAGS}" \
  --background=true
_wait_ysql "${A_HOST}" "Site A"

# -- 4. Site B ----------------------------------------------------------------
echo "🚀 Starting SITE B on ${B_HOST} ..."
yugabyted start \
  --base_dir="${B_BASE}" \
  --advertise_address="${B_HOST}" \
  --cloud_location=ybcloud.pandora.az2 \
  --tserver_flags="${_TFLAGS}" \
  --background=true
_wait_ysql "${B_HOST}" "Site B"

# -- 5. Identical schema and seed on BOTH sites -------------------------------
for _spec in "A:${A_HOST}" "B:${B_HOST}"; do
    _label="${_spec%%:*}"; _host="${_spec#*:}"
    echo "📦 Site ${_label}: creating schema and seeding..."
    ysqlsh -h "${_host}" -q -f "${ART_PATH}/schema.sql"
    ysqlsh -h "${_host}" -q -f "${ART_PATH}/seed.sql"
done

# -- 6. Clear CDC state so a rebuilt container starts clean --------------------
ysqlsh -h "${A_HOST}" -q -c "SELECT pg_drop_replication_slot(slot_name) FROM pg_replication_slots WHERE slot_name = '${A2B_SLOT}';" 2>/dev/null || true
ysqlsh -h "${B_HOST}" -q -c "SELECT pg_drop_replication_slot(slot_name) FROM pg_replication_slots WHERE slot_name = '${B2A_SLOT}';" 2>/dev/null || true
ysqlsh -h "${A_HOST}" -q -c "DROP PUBLICATION IF EXISTS ${A2B_PUB};"                 2>/dev/null || true
ysqlsh -h "${B_HOST}" -q -c "DROP PUBLICATION IF EXISTS ${B2A_PUB};"                 2>/dev/null || true
ysqlsh -h "${A_HOST}" -q -c "DROP TABLE IF EXISTS ${SCHEMA}.${A2B_OFFSET_TABLE};"    2>/dev/null || true
ysqlsh -h "${B_HOST}" -q -c "DROP TABLE IF EXISTS ${SCHEMA}.${B2A_OFFSET_TABLE};"    2>/dev/null || true
ysqlsh -h "${B_HOST}" -q -c "DROP TABLE IF EXISTS ${SCHEMA}.${A2B_APPLY_STATE};"     2>/dev/null || true
ysqlsh -h "${A_HOST}" -q -c "DROP TABLE IF EXISTS ${SCHEMA}.${B2A_APPLY_STATE};"     2>/dev/null || true
# Conflict logs live on each lane's SINK, alongside that lane's apply state.
ysqlsh -h "${B_HOST}" -q -c "DROP TABLE IF EXISTS ${SCHEMA}.${A2B_CONFLICT_LOG};"    2>/dev/null || true
ysqlsh -h "${A_HOST}" -q -c "DROP TABLE IF EXISTS ${SCHEMA}.${B2A_CONFLICT_LOG};"    2>/dev/null || true

# -- 7. Pre-create BOTH replication origins, before any slot exists -----------
# See the header. Idempotent: the WHERE NOT EXISTS means re-running is a no-op,
# and the appliers check the catalog before creating their own.
_ensure_origin() {  # _ensure_origin <host> <origin-name> <label>
    ysqlsh -h "$1" -q -c \
      "SELECT pg_replication_origin_create('$2') WHERE NOT EXISTS (SELECT 1 FROM pg_replication_origin WHERE roname = '$2');" \
      >/dev/null 2>&1 || true
    if [ "$(ysqlsh -h "$1" -tAc "SELECT COUNT(*) FROM pg_replication_origin WHERE roname = '$2';" 2>/dev/null | tr -d '[:space:]')" = "1" ]; then
        echo "   ✅ $3: origin '$2' present on $1"
    else
        echo "   ⚠  $3: could not create origin '$2' on $1."
        echo "      Replication origins are Early Access (YugabyteDB 2025.2.1+)."
        echo "      Without them the loop filter cannot work; see the README."
    fi
}
echo "🔁 Pre-creating replication origins (must exist BEFORE the slots stream)..."
_ensure_origin "${A_HOST}" "${B2A_ORIGIN_FULL}" "B→A writes into A"
_ensure_origin "${B_HOST}" "${A2B_ORIGIN_FULL}" "A→B writes into B"

echo ""
echo "Site A  ->  ysqlsh -h ${A_HOST}    ($(ysqlsh -h "${A_HOST}" -tAc 'SELECT COUNT(*) FROM public.orders;' 2>/dev/null | tr -d '[:space:]') orders)"
echo "Site B  ->  ysqlsh -h ${B_HOST}   ($(ysqlsh -h "${B_HOST}" -tAc 'SELECT COUNT(*) FROM public.orders;' 2>/dev/null | tr -d '[:space:]') orders)"
echo "Both sites start identical — replication streams changes only, never a snapshot."
echo ""
echo "The lanes are NOT started automatically — that is step one of the walkthrough:"
echo "  cd ${ART_PATH} && bash applier.sh start"
