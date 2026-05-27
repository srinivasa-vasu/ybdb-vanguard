#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# start-cdc.sh  —  CDC exercise service startup (postStartCommand)
#
# Starts:
#   1. YugabyteDB single-node cluster
#   2. PostgreSQL container (CDC sink) via Docker Compose
#   3. Confluent Platform local services (Zookeeper, Kafka, Schema Registry,
#      Kafka Connect, KSQL, Control Center) — in background
#
# Useful environment variables (set in devcontainer.json containerEnv):
#   CONFLUENT_HOME, DATA_PATH, ART_PATH
#
# After startup, seed the source data:
#   ysqlsh -f init-cdc/chinook.sql
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

CONFLUENT_HOME="${CONFLUENT_HOME:-${PWD}/confluent}"
LOG_FILE="${PWD}/confluent-start.log"

# 1. YugabyteDB
echo "🚀 Starting YugabyteDB..."
bash .devcontainer/scripts/start-ybdb.sh 1

# 2. PostgreSQL (CDC sink)
echo "🐘 Starting PostgreSQL CDC sink..."
docker compose -f init-cdc/compose.yml up -d

# 3. Confluent Platform (background — takes ~2 min to be fully ready)
if [ ! -f "${CONFLUENT_HOME}/bin/confluent" ]; then
  echo "❌ Confluent not found at ${CONFLUENT_HOME}/bin/confluent"
  echo "   Run: bash .devcontainer/scripts/setup-cdc.sh"
  exit 1
fi

echo "📡 Starting Confluent Platform services (background)..."
export CONFLUENT_HOME
nohup "${CONFLUENT_HOME}/bin/confluent" local services start \
  > "${LOG_FILE}" 2>&1 &
CONFLUENT_PID=$!

# Brief pause to catch an immediate crash
sleep 2
if ! kill -0 "${CONFLUENT_PID}" 2>/dev/null; then
  echo "❌ Confluent process exited immediately. Check the log:"
  tail -20 "${LOG_FILE}"
  exit 1
fi
echo "   PID ${CONFLUENT_PID} | log: ${LOG_FILE}"

echo ""
echo "⏳ Waiting for PostgreSQL sink on :5432 (up to 90s)..."
_pg_ready=0
for i in $(seq 1 30); do
  if (echo >/dev/tcp/127.0.0.1/5432) 2>/dev/null; then
    _pg_ready=1
    break
  fi
  sleep 3
done
if [ "$_pg_ready" -eq 0 ]; then
  echo "❌ PostgreSQL did not become ready in time. Check: docker compose -f init-cdc/compose.yml logs"
  exit 1
fi
echo "✅ PostgreSQL is up."

echo "📥 Loading Chinook dataset into YugabyteDB (CDC source)..."
ysqlsh -f init-cdc/chinook.sql
echo "✅ Chinook data loaded into YugabyteDB."

echo ""
echo "✅ Startup complete."
echo "   Confluent is starting in the background (~2 min to be fully ready)."
echo "   Monitor:  tail -f ${LOG_FILE}"
echo "   Status:   ${CONFLUENT_HOME}/bin/confluent local services status"
echo ""
echo "Kafka Connect UI  →  localhost:8083"
echo "Control Center    →  localhost:9021"
echo "Schema Registry   →  localhost:8081"
echo ""
echo "Next: apply connector config — env vars are pre-set:"
echo "   MASTERS=${MASTERS}  TOPIC_PREFIX=${TOPIC_PREFIX}  SCHEMA=${SCHEMA}"
