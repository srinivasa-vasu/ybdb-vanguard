#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# start-ybdb.sh  —  shared YugabyteDB cluster startup for Codespaces
#
# Usage:
#   bash .devcontainer/scripts/start-ybdb.sh <nodes> [tserver_flags]
#
#   nodes        1 | 3 | 6  (default: 1)
#   tserver_flags  optional comma-separated flag=value pairs, e.g.
#                  ysql_num_shards_per_tserver=2,yb_num_shards_per_tserver=2
#
# Reads:  DATA_PATH env var (default: ybdb)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

NODES="${1:-1}"
TSERVER_FLAGS="${2:-}"
BASE_DIR="${PWD}/${DATA_PATH:-ybdb}"

echo "🚀 Starting YugabyteDB ${NODES}-node cluster..."

# ── Sweep all known runtime artefacts from previous exercises ────────────────
# Data dirs from other exercises accumulate on the bind-mounted workspace
# (visible on the host machine). Clean them all at startup so the project
# folder stays tidy regardless of which exercise was run before.
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
mkdir -p "$BASE_DIR"

# ── loopback aliases ──────────────────────────────────────────────────────────
# Linux routes the entire 127.0.0.0/8 range to lo, but yugabyted needs the
# addresses explicitly bound so it can listen on them.
if [ "$NODES" -gt 1 ]; then
  for i in 2 3 4 5 6; do
    sudo ip addr add "127.0.0.${i}/8" dev lo 2>/dev/null || true
  done
fi

# ── helper: start a single yugabyted node ────────────────────────────────────
BASE_TFLAGS="yb_enable_read_committed_isolation=true"
if [ -n "$TSERVER_FLAGS" ]; then
  _tflags="--tserver_flags=${BASE_TFLAGS},${TSERVER_FLAGS}"
else
  _tflags="--tserver_flags=${BASE_TFLAGS}"
fi

echo "   TServer flags: ${_tflags#--tserver_flags=}"

# Optional master flags — set MASTER_FLAGS env var in the devcontainer to pass
# extra flags to every yugabyted node (e.g. MASTER_FLAGS=enable_db_clone=true).
_mflags=""
[ -n "${MASTER_FLAGS:-}" ] && _mflags="--master_flags=${MASTER_FLAGS}"

echo "   Master flags: ${_mflags#--master_flags=}"


start_node() {
  local n="$1" addr="$2" az="$3"
  local join_flag=""
  [ "$n" -gt 1 ] && join_flag="--join=127.0.0.1"

  # shellcheck disable=SC2086
  yugabyted start \
    --base_dir="${BASE_DIR}/ybd${n}" \
    --advertise_address="${addr}" \
    --cloud_location="ybcloud.pandora.${az}" \
    --fault_tolerance=zone \
    --background=true \
    ${join_flag} "${_tflags}" ${_mflags}
}

# ── wait for node 1's master RPC port before joining ─────────────────────────
# Nodes 2+ use --join=127.0.0.1 which contacts the master on :7100.
# If node 1 hasn't finished initialising its master process, the join fails
# with "Node at the join ip provided is not reachable."
_master_ready() { (echo >/dev/tcp/127.0.0.1/7100) 2>/dev/null; }

_wait_for_master() {
  echo "⏳ Waiting for node 1 master RPC on :7100..."
  for i in $(seq 1 30); do
    if _master_ready; then
      echo "   Node 1 master is up."
      return 0
    fi
    sleep 2
  done
  echo "❌ Node 1 master did not come up in time."
  return 1
}

# ── start nodes ───────────────────────────────────────────────────────────────
if [ "$NODES" -eq 1 ]; then
  # shellcheck disable=SC2086
  yugabyted start \
    --base_dir="${BASE_DIR}/ybd1" \
    --advertise_address=127.0.0.1 \
    --cloud_location=ybcloud.pandora.az1 \
    --background=true \
    "${_tflags}" ${_mflags}
else
  start_node 1 127.0.0.1 az1

  # Wait for node 1's master to be reachable before starting join nodes
  _wait_for_master

  start_node 2 127.0.0.2 az2
  start_node 3 127.0.0.3 az3

  if [ "$NODES" -ge 6 ]; then
    start_node 4 127.0.0.4 az1
    start_node 5 127.0.0.5 az2
    start_node 6 127.0.0.6 az3
  fi

  yugabyted configure data_placement \
    --fault_tolerance=zone \
    --base_dir="${BASE_DIR}/ybd1"
fi

# ── YSQL readiness wait ───────────────────────────────────────────────────────
# Use pure-bash /dev/tcp so we don't depend on nc (not installed in all images).
# Multi-node clusters take longer to elect a leader and init YSQL; allow 3 min.
_ysql_ready() { (echo >/dev/tcp/127.0.0.1/5433) 2>/dev/null; }

if [ "$NODES" -gt 1 ]; then
  _max_attempts=60  # 60 × 3 s = 3 min
  _interval=3
else
  _max_attempts=30  # 30 × 3 s = 90 s
  _interval=3
fi

echo "⏳ Waiting for YSQL to accept connections on :5433 (up to $(( _max_attempts * _interval ))s)..."
_ready=0
for i in $(seq 1 "$_max_attempts"); do
  if _ysql_ready; then
    _ready=1
    break
  fi
  sleep "$_interval"
done

if [ "$_ready" -eq 0 ]; then
  echo "❌ YSQL did not become ready in time."
  echo "   Check cluster status with: yugabyted status"
  exit 1
fi

echo "✅ YugabyteDB ${NODES}-node cluster is ready."
echo "   YSQL  → localhost:5433   (psql-compatible)"
echo "   YCQL  → localhost:9042   (CQL-compatible)"
echo "   UI    → localhost:15433  (yugabyted dashboard)"
