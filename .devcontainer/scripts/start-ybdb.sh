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
_tflags=""
[ -n "$TSERVER_FLAGS" ] && _tflags="--tserver_flags=${TSERVER_FLAGS}"

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
    ${join_flag} ${_tflags}
}

# ── start nodes ───────────────────────────────────────────────────────────────
if [ "$NODES" -eq 1 ]; then
  yugabyted start \
    --base_dir="${BASE_DIR}/ybd1" \
    --advertise_address=127.0.0.1 \
    --cloud_location=ybcloud.pandora.az1 \
    --background=true
else
  start_node 1 127.0.0.1 az1
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

echo "⏳ Waiting for YSQL to accept connections on :5433..."
for i in $(seq 1 30); do
  if nc -z 127.0.0.1 5433 2>/dev/null; then
    break
  fi
  sleep 2
done
nc -z 127.0.0.1 5433 2>/dev/null || { echo "❌ YSQL did not become ready in time."; exit 1; }

echo "✅ YugabyteDB ${NODES}-node cluster is ready."
echo "   YSQL  → localhost:5433   (psql-compatible)"
echo "   YCQL  → localhost:9042   (CQL-compatible)"
echo "   UI    → localhost:15433  (yugabyted dashboard)"
