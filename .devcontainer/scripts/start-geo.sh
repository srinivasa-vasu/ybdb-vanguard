#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# start-geo.sh  —  3-node multi-region cluster startup for the geo exercise
#
# Simulates three geographic regions on loopback IPs:
#   127.0.0.1  →  ybcloud.us-east.us-east-az1
#   127.0.0.2  →  ybcloud.eu-west.eu-west-az1
#   127.0.0.3  →  ybcloud.ap-south.ap-south-az1
#
# Runs `yugabyted configure data_placement --fault_tolerance=region` after
# all three nodes have joined to enable region-level placement policies and
# tablespace-based data pinning.
#
# Reads:  DATA_PATH env var (default: ybdb)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

BASE_DIR="${PWD}/${DATA_PATH:-ybdb}"

# Remove stale data from previous runs (same reason as start-ybdb.sh).
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
mkdir -p "$BASE_DIR"
mkdir -p "$BASE_DIR"

echo "🌍 Starting 3-node multi-region cluster..."
echo "   127.0.0.1  us-east    (US East)"
echo "   127.0.0.2  eu-west    (EU West)"
echo "   127.0.0.3  ap-south   (AP South)"

# ── loopback aliases ──────────────────────────────────────────────────────────
for i in 2 3; do
  sudo ip addr add "127.0.0.${i}/8" dev lo 2>/dev/null || true
done

# ── start node 1 (the join target) ───────────────────────────────────────────
yugabyted start \
  --base_dir="${BASE_DIR}/ybd1" \
  --advertise_address=127.0.0.1 \
  --cloud_location=ybcloud.us-east.us-east-az1 \
  --fault_tolerance=region \
  --background=true

# Wait for node 1's master RPC port before starting join nodes.
# Without this, nodes 2 and 3 fail with "Node at join ip not reachable."
echo "⏳ Waiting for node 1 master RPC on :7100..."
for i in $(seq 1 30); do
  if (echo >/dev/tcp/127.0.0.1/7100) 2>/dev/null; then
    echo "   Node 1 master is up."
    break
  fi
  sleep 2
done

# ── start join nodes ──────────────────────────────────────────────────────────
yugabyted start \
  --base_dir="${BASE_DIR}/ybd2" \
  --advertise_address=127.0.0.2 \
  --cloud_location=ybcloud.eu-west.eu-west-az1 \
  --fault_tolerance=region \
  --join=127.0.0.1 \
  --background=true

yugabyted start \
  --base_dir="${BASE_DIR}/ybd3" \
  --advertise_address=127.0.0.3 \
  --cloud_location=ybcloud.ap-south.ap-south-az1 \
  --fault_tolerance=region \
  --join=127.0.0.1 \
  --background=true

# ── YSQL readiness wait ───────────────────────────────────────────────────────
_ysql_ready() { (echo >/dev/tcp/127.0.0.1/5433) 2>/dev/null; }

echo "⏳ Waiting for YSQL on :5433 (up to 3 min)..."
_ready=0
for i in $(seq 1 60); do
  if _ysql_ready; then _ready=1; break; fi
  sleep 3
done
if [ "$_ready" -eq 0 ]; then
  echo "❌ YSQL did not become ready. Check: yugabyted status"
  exit 1
fi

# ── configure region-level data placement ─────────────────────────────────────
# This enables tablespace-based geo-pinning and region-fault-tolerance quorum.
echo "⚙️  Configuring region-level data placement..."
yugabyted configure data_placement \
  --base_dir="${BASE_DIR}/ybd1" \
  --fault_tolerance=region

echo "✅ Multi-region cluster ready."
echo "   YSQL  → localhost:5433"
echo "   UI    → localhost:15433"
