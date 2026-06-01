#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# start-cdc.sh  —  CDC exercise service startup (postStartCommand)
#
# Starts:
#   1. YugabyteDB single-node cluster with logical replication tserver flag
#   2. Debezium stack + PostgreSQL sink via Docker Compose
#      (Zookeeper, Kafka, Kafka Connect with ybdb-debezium image, PostgreSQL)
#
# After startup, seeds the Chinook dataset into YugabyteDB as the CDC source.
#
# Useful environment variables (set in devcontainer.json containerEnv):
#   YBDB_CONNECTOR_VERSION, TSERVER_FLAGS, KAFKA_CONNECT_PORT
#   HOST, SRC_USER, SRC_SECRET, TOPIC_PREFIX, SCHEMA
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# Open the Docker socket so the vscode user can run docker-compose commands.
# The socket is mounted from the host but owned by root:docker on the host;
# the container's docker group GID may differ, so chmod is the reliable fix.
sudo chmod 666 /var/run/docker.sock 2>/dev/null || true

KAFKA_CONNECT_PORT="${KAFKA_CONNECT_PORT:-8083}"

# ── 1. YugabyteDB with logical replication tserver flag ──────────────────────
# ysql_yb_default_replica_identity=DEFAULT ensures every new table gets DEFAULT
# replica identity so the yboutput plugin can capture UPDATE/DELETE before-images
# without requiring per-table ALTER TABLE ... REPLICA IDENTITY commands.
echo "Starting YugabyteDB with logical replication flags..."
bash .devcontainer/scripts/start-ybdb.sh 1 "${TSERVER_FLAGS:-ysql_yb_default_replica_identity=DEFAULT}"

# ── 2. Debezium stack + PostgreSQL (Docker Compose) ──────────────────────────
echo "Starting Debezium stack (Zookeeper, Kafka, Connect) and PostgreSQL..."
docker-compose -f init-cdc/compose.yml up -d

# ── 3. Wait for PostgreSQL ────────────────────────────────────────────────────
echo "Waiting for PostgreSQL on :5432 (up to 90s)..."
_pg_ready=0
for i in $(seq 1 30); do
  if (echo >/dev/tcp/127.0.0.1/5432) 2>/dev/null; then
    _pg_ready=1; break
  fi
  sleep 3
done
if [ "$_pg_ready" -eq 0 ]; then
  echo "❌ PostgreSQL did not become ready in time."
  echo "   Check: docker-compose -f init-cdc/compose.yml logs postgresql"
  exit 1
fi
echo "✅ PostgreSQL is up."

# ── 4. Wait for Kafka Connect REST API ───────────────────────────────────────
# Kafka Connect starts after Zookeeper and Kafka, and then loads all connector
# plugins — this typically takes 60–90 s on first start.
echo "Waiting for Kafka Connect on :${KAFKA_CONNECT_PORT} (up to 2 min)..."
_kc_ready=0
for i in $(seq 1 60); do
  if curl -sf "http://127.0.0.1:${KAFKA_CONNECT_PORT}/" >/dev/null 2>&1; then
    _kc_ready=1; break
  fi
  sleep 2
done
if [ "$_kc_ready" -eq 0 ]; then
  echo "❌ Kafka Connect did not become ready in time."
  echo "   Check: docker-compose -f init-cdc/compose.yml logs connect"
  exit 1
fi
echo "✅ Kafka Connect is ready."

# ── 5. Seed the CDC source data ───────────────────────────────────────────────
echo "Loading Chinook dataset into YugabyteDB (CDC source)..."
ysqlsh -f init-cdc/chinook.sql
echo "✅ Chinook data loaded."

echo ""
echo "Kafka Connect  →  http://localhost:${KAFKA_CONNECT_PORT}/"
echo "PostgreSQL     →  localhost:5432  (user: postgres / yugabyte)"
echo "YugabyteDB     →  localhost:5433  (user: yugabyte / yugabyte)"
echo "YugabyteDB UI  →  http://localhost:15433/"
echo ""
echo "Env vars pre-set for the connector-config shell:"
echo "  HOST=${HOST:-127.0.0.1}  TOPIC_PREFIX=${TOPIC_PREFIX:-sample}  SCHEMA=${SCHEMA:-public}"
