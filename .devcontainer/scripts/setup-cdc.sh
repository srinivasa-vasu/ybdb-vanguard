#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# setup-cdc.sh  —  one-time CDC environment setup (postCreateCommand)
#
# Downloads connector JARs into init-cdc/kafka-plugins/:
#   - YugabyteDB source connector  (github.com/yugabyte/debezium/releases)
#   - Confluent JDBC sink connector (packages.confluent.io)
#
# Pulls Docker images for the Debezium stack:
#   - debezium/zookeeper, debezium/kafka, debezium/connect
#   - postgres:14 (CDC sink)
#
# Bump YBDB_CONNECTOR_VERSION in devcontainer.json when a new release is out.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

YBDB_CONNECTOR_VERSION="${YBDB_CONNECTOR_VERSION:-dz.2.5.2.yb.2025.2.3}"
JDBC_VERSION="${JDBC_VERSION:-10.7.4}"
PLUGINS_DIR="${PWD}/init-cdc/kafka-plugins"

mkdir -p "${PLUGINS_DIR}"

# ── YugabyteDB source connector (jar-with-dependencies) ──────────────────────
YB_JAR="yugabytedb-source-connector-${YBDB_CONNECTOR_VERSION}-jar-with-dependencies.jar"
YB_JAR_URL="https://github.com/yugabyte/debezium/releases/download/${YBDB_CONNECTOR_VERSION}/${YB_JAR}"

echo "Downloading YugabyteDB source connector ${YBDB_CONNECTOR_VERSION}..."
curl -# -L -o "${PLUGINS_DIR}/${YB_JAR}" "${YB_JAR_URL}"
echo "YugabyteDB connector saved to ${PLUGINS_DIR}/${YB_JAR}"

# ── Confluent JDBC sink connector JAR ────────────────────────────────────────
echo "Downloading Confluent JDBC sink connector ${JDBC_VERSION}..."
curl -# -L \
  -o "${PLUGINS_DIR}/kafka-connect-jdbc-${JDBC_VERSION}.jar" \
  "https://packages.confluent.io/maven/io/confluent/kafka-connect-jdbc/${JDBC_VERSION}/kafka-connect-jdbc-${JDBC_VERSION}.jar"
echo "JDBC sink connector saved to ${PLUGINS_DIR}/kafka-connect-jdbc-${JDBC_VERSION}.jar"

# ── Pull Debezium stack + PostgreSQL Docker images ────────────────────────────
echo "Pulling Debezium and PostgreSQL Docker images..."
docker compose -f init-cdc/compose.yml pull
echo "Docker images ready."

echo ""
echo "✅ CDC setup complete. $(ls "${PLUGINS_DIR}"/*.jar 2>/dev/null | wc -l) connector JARs in ${PLUGINS_DIR}/"
echo "   Run 'bash .devcontainer/scripts/start-cdc.sh' to start all services."
