#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# setup-cdc.sh  —  one-time CDC environment setup (postCreateCommand)
#
# Downloads Confluent Platform, installs Kafka connectors, and pre-pulls
# the PostgreSQL Docker image used as the CDC sink.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

KAFKA_VERSION="${KAFKA_VERSION:-7.5.0}"
CONFLUENT_HOME="${CONFLUENT_HOME:-${PWD}/confluent}"
JDBC_VERSION="${JDBC_VERSION:-10.7.4}"
POSTGRES_CONNECTOR_VERSION="${POSTGRES_CONNECTOR_VERSION:-2.2.1}"
YBDB_CONNECTOR_VERSION="${YBDB_CONNECTOR_VERSION:-1.9.5.y.220.1}"

# ── Confluent Platform ────────────────────────────────────────────────────────
echo "📦 Downloading Confluent Platform ${KAFKA_VERSION} (~350 MB)..."
mkdir -p "${CONFLUENT_HOME}"
curl -# -o /tmp/confluent.tar.gz \
  "https://packages.confluent.io/archive/7.5/confluent-${KAFKA_VERSION}.tar.gz"
tar -xzf /tmp/confluent.tar.gz -C "${CONFLUENT_HOME}" --strip-components=1
rm /tmp/confluent.tar.gz
echo "✅ Confluent Platform extracted to ${CONFLUENT_HOME}"

# ── Kafka connectors ──────────────────────────────────────────────────────────
echo "🔌 Installing Kafka Connect plugins..."
mkdir -p "${CONFLUENT_HOME}/share/confluent-hub-components"

"${CONFLUENT_HOME}/bin/confluent-hub" install --no-prompt \
  --component-dir "${CONFLUENT_HOME}/share/confluent-hub-components" \
  "confluentinc/kafka-connect-jdbc:${JDBC_VERSION}"

"${CONFLUENT_HOME}/bin/confluent-hub" install --no-prompt \
  --component-dir "${CONFLUENT_HOME}/share/confluent-hub-components" \
  "debezium/debezium-connector-postgresql:${POSTGRES_CONNECTOR_VERSION}"

echo "📥 Downloading YugabyteDB Debezium connector jar..."
wget -q "https://github.com/yugabyte/debezium-connector-yugabytedb/releases/download/v${YBDB_CONNECTOR_VERSION}/debezium-connector-yugabytedb-${YBDB_CONNECTOR_VERSION}.jar" \
  -O "/tmp/ybdb-connector.jar"
mv /tmp/ybdb-connector.jar \
  "${CONFLUENT_HOME}/share/java/confluent-hub-client/debezium-connector-yugabytedb-${YBDB_CONNECTOR_VERSION}.jar"
echo "✅ All Kafka connectors installed"

# ── PostgreSQL Docker image (CDC sink) ────────────────────────────────────────
echo "🐘 Pre-pulling PostgreSQL image..."
docker compose -f init-cdc/compose.yml pull
echo "✅ CDC setup complete. Run 'bash .devcontainer/scripts/start-cdc.sh' to start all services."
