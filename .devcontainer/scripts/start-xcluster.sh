#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# start-xcluster.sh  —  Start two single-node YugabyteDB clusters for the
#                        xCluster replication exercise.
#
#   Source cluster : 127.0.0.1   (the primary / active universe)
#   Target cluster : 127.0.0.11  (the standby / DR replica)
#
# Both nodes listen on the standard ports — no conflicts because they bind
# to different IPs. The loopback alias 127.0.0.11 is added here.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

BASE_DIR="${PWD}/${DATA_PATH:-ybdb}"
SOURCE_BASE="${BASE_DIR}/source"
TARGET_BASE="${BASE_DIR}/target"

# ── Sweep all known runtime artefacts from previous exercises ────────────────
echo "🧹 Sweeping stale runtime data from previous exercises..."
rm -rf \
  "${PWD}/ybdb" \
  "${PWD}/voyager-data" \
  "${PWD}/init-ear/keys" \
  "${PWD}/init-cdc-ybdb-pg/kafka-plugins" \
  "${PWD}/init-voyager-postgres/voyager-data" \
  "${PWD}/init-voyager-mysql/voyager-data" \
  "${PWD}/init-voyager-mariadb/voyager-data" \
  "${PWD}/init-voyager-oracle/voyager-data" 2>/dev/null || true
mkdir -p "${SOURCE_BASE}" "${TARGET_BASE}"

# ── Add loopback alias for target node ───────────────────────────────────────
sudo ip addr add 127.0.0.11/8 dev lo 2>/dev/null || true

# ── Helper: wait for a YSQL port to accept connections ───────────────────────
_wait_ysql() {
  local host="$1"
  for i in $(seq 1 40); do
    if (echo >/dev/tcp/"${host}"/5433) 2>/dev/null; then return 0; fi
    sleep 3
  done
  echo "ERROR: ${host}:5433 did not become ready" >&2
  return 1
}

# ── Start source cluster (127.0.0.1) ────────────────────────────────────────
echo "🚀 Starting Source cluster on 127.0.0.1 ..."
yugabyted start \
  --base_dir="${SOURCE_BASE}" \
  --advertise_address=127.0.0.1 \
  --tserver_flags="cdc_wal_retention_time_secs=86400" \
  --daemon=true

_wait_ysql 127.0.0.1
echo "   ✅ Source ready  (127.0.0.1:5433)"

# ── Start target cluster (127.0.0.11) ───────────────────────────────────────
echo "🚀 Starting Target cluster on 127.0.0.11 ..."
yugabyted start \
  --base_dir="${TARGET_BASE}" \
  --advertise_address=127.0.0.11 \
  --tserver_flags="cdc_wal_retention_time_secs=86400" \
  --daemon=true

_wait_ysql 127.0.0.11
echo "   ✅ Target ready  (127.0.0.11:5433)"

echo ""
echo "Source: ysqlsh -h 127.0.0.1   | Masters: 127.0.0.1:7100"
echo "Target: ysqlsh -h 127.0.0.11  | Masters: 127.0.0.11:7100"
