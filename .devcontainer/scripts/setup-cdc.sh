#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# setup-cdc.sh  —  one-time CDC environment setup (postCreateCommand)
#
# Downloads connector JARs and loads them into the 'kafka-plugins' Docker
# named volume so Kafka Connect can find them at runtime. Using a named volume
# (rather than a bind mount) avoids host-path issues with docker-outside-of-docker
# on macOS Dev Containers.
#
# Bump YBDB_CONNECTOR_VERSION in devcontainer.json when a new release is out.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

sudo chmod 666 /var/run/docker.sock 2>/dev/null || true

YBDB_CONNECTOR_VERSION="${YBDB_CONNECTOR_VERSION:-dz.2.5.2.yb.2025.2.3}"
JDBC_VERSION="${JDBC_VERSION:-10.7.4}"

# Download JARs to a local staging dir first
STAGING="/tmp/cdc-plugins"
mkdir -p "${STAGING}"

# ── YugabyteDB source connector ──────────────────────────────────────────────
YB_JAR="yugabytedb-source-connector-${YBDB_CONNECTOR_VERSION}-jar-with-dependencies.jar"
echo "Downloading YugabyteDB source connector ${YBDB_CONNECTOR_VERSION}..."
curl -# -L -o "${STAGING}/${YB_JAR}" \
  "https://github.com/yugabyte/debezium/releases/download/${YBDB_CONNECTOR_VERSION}/${YB_JAR}"

# ── Confluent JDBC sink connector ────────────────────────────────────────────
echo "Downloading Confluent JDBC sink connector ${JDBC_VERSION}..."
curl -# -L \
  -o "${STAGING}/kafka-connect-jdbc-${JDBC_VERSION}.jar" \
  "https://packages.confluent.io/maven/io/confluent/kafka-connect-jdbc/${JDBC_VERSION}/kafka-connect-jdbc-${JDBC_VERSION}.jar"

# ── Populate the named volume via a temporary container ──────────────────────
# The 'kafka-plugins' named volume is declared in compose.yml and used by the
# Kafka Connect service. We copy JARs into it using a throwaway container so
# no bind mount is needed (bind mounts from devcontainer paths fail on macOS).
echo "Populating kafka-plugins Docker volume..."
docker volume create cdc_kafka-plugins 2>/dev/null || true
docker run --rm \
  -v cdc_kafka-plugins:/plugins \
  -v "${STAGING}:/staging:ro" \
  busybox sh -c "cp /staging/*.jar /plugins/ && ls -lh /plugins/"

# ── Pull Debezium stack + PostgreSQL Docker images ────────────────────────────
echo "Pulling Debezium and PostgreSQL Docker images..."
docker-compose -f init-cdc/compose.yml pull
echo "Docker images ready."

echo ""
echo "✅ CDC setup complete."
echo "   JARs loaded into Docker volume 'cdc_kafka-plugins'"
