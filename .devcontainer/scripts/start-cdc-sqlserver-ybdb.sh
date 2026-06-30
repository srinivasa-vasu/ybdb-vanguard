#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# start-cdc-sqlserver-ybdb.sh  --  CDC SQL Server service startup (postStartCommand)
# -----------------------------------------------------------------------------
set -euo pipefail

sudo chmod 666 /var/run/docker.sock 2>/dev/null || true

KAFKA_CONNECT_PORT="${KAFKA_CONNECT_PORT:-8083}"
DEBEZIUM_VERSION="${DEBEZIUM_VERSION:-3.1.3.Final}"
MSSQL_SA_PASSWORD="${MSSQL_SA_PASSWORD:-Yugabyte@123}"
WORKDIR="init-cdc-sqlserver-ybdb"

# -- Find Docker CLI -----------------------------------------------------------
DOCKER=""
for _candidate in /usr/local/bin/docker /usr/bin/docker; do
    if [ -x "$_candidate" ] && "$_candidate" --version >/dev/null 2>&1; then
        DOCKER="$_candidate"; break
    fi
done
[ -z "$DOCKER" ] && { echo "ERROR: Docker CLI not found."; exit 1; }

# -- Detect devcontainer ID -----------------------------------
DC_ID=$(grep -oE '/docker/[0-9a-f]+' /proc/1/cpuset 2>/dev/null \
        | head -1 | cut -d/ -f3 || hostname)
echo "Devcontainer ID: ${DC_ID:0:12}..."

# -- 1. YugabyteDB ------------------------------------------------------------
echo "Starting YugabyteDB..."
bash .devcontainer/scripts/start-ybdb.sh 1 ""

# -- 2. Remove stale CDC containers -------------------------------------------
echo "Removing stale CDC containers..."
for _ctr in init-cdc-sqlserver-ybdb-zookeeper-1 init-cdc-sqlserver-ybdb-kafka-1 init-cdc-sqlserver-ybdb-connect-1 sqlserver; do
    $DOCKER rm -f "$_ctr" 2>/dev/null || true
done

# -- 3. ZooKeeper -------------------------------------------------------------
echo "Starting ZooKeeper..."
$DOCKER run -d \
    --name init-cdc-sqlserver-ybdb-zookeeper-1 \
    --net "container:${DC_ID}" \
    --restart on-failure \
    --platform linux/amd64 \
    quay.io/debezium/zookeeper:${DEBEZIUM_VERSION}

echo "Waiting for ZooKeeper on 127.0.0.1:2181 (up to 60s)..."
for i in $(seq 1 30); do
    (echo >/dev/tcp/127.0.0.1/2181) 2>/dev/null && break
    sleep 2
done
if ! (echo >/dev/tcp/127.0.0.1/2181) 2>/dev/null; then
    echo "ERROR: ZooKeeper did not start."
    $DOCKER logs init-cdc-sqlserver-ybdb-zookeeper-1 | tail -20
    exit 1
fi
echo "ZooKeeper is up."

# -- 4. Kafka -----------------------------------------------------------------
echo "Starting Kafka..."
$DOCKER run -d \
    --name init-cdc-sqlserver-ybdb-kafka-1 \
    --net "container:${DC_ID}" \
    --restart on-failure \
    --platform linux/amd64 \
    -e ZOOKEEPER_CONNECT=127.0.0.1:2181 \
    -e KAFKA_LISTENERS=PLAINTEXT://0.0.0.0:9092 \
    -e KAFKA_ADVERTISED_HOST_NAME=127.0.0.1 \
    quay.io/debezium/kafka:${DEBEZIUM_VERSION}

echo "Waiting for Kafka on 127.0.0.1:9092 (up to 90s)..."
_kafka_up=0
for i in $(seq 1 45); do
    if (echo >/dev/tcp/127.0.0.1/9092) 2>/dev/null; then
        _kafka_up=1; break
    fi
    sleep 2
done
if [ "$_kafka_up" -eq 0 ]; then
    echo "ERROR: Kafka did not start."
    $DOCKER logs init-cdc-sqlserver-ybdb-kafka-1 | tail -30
    exit 1
fi
echo "Kafka is up."

# -- 5. Verify connector JARs in the plugin volume ----------------------------
echo "Verifying connector plugin JARs in init-cdc-sqlserver-ybdb_kafka-plugins..."
_jar_count=$($DOCKER run --rm -v init-cdc-sqlserver-ybdb_kafka-plugins:/plugins \
    busybox sh -c 'ls /plugins/*.jar 2>/dev/null | wc -l')
if [ "${_jar_count:-0}" -eq 0 ]; then
    echo "ERROR: No JARs found in init-cdc-sqlserver-ybdb_kafka-plugins volume."
    echo "  The JDBC driver JAR was not loaded during postCreateCommand."
    echo "  Fix: run 'bash .devcontainer/scripts/setup-cdc-sqlserver-ybdb.sh' then re-run this script."
    exit 1
fi
echo "Plugin JARs ready: ${_jar_count} file(s) in volume."

# -- 6. Kafka Connect & SQL Server ---------------------------------------------
echo "Starting Kafka Connect and SQL Server..."

$DOCKER run -d \
    --name init-cdc-sqlserver-ybdb-connect-1 \
    --net "container:${DC_ID}" \
    --restart on-failure \
    --platform linux/amd64 \
    -e BOOTSTRAP_SERVERS=127.0.0.1:9092 \
    -e GROUP_ID=1 \
    -e CONFIG_STORAGE_TOPIC=cdc_connect_configs \
    -e OFFSET_STORAGE_TOPIC=cdc_connect_offsets \
    -e STATUS_STORAGE_TOPIC=cdc_connect_statuses \
    -v init-cdc-sqlserver-ybdb_kafka-plugins:/kafka/connect/yugabytedb \
    quay.io/debezium/connect:${DEBEZIUM_VERSION}

$DOCKER run -d \
    --name sqlserver \
    --net "container:${DC_ID}" \
    --restart on-failure \
    --platform linux/amd64 \
    -e ACCEPT_EULA=Y \
    -e MSSQL_SA_PASSWORD="${MSSQL_SA_PASSWORD}" \
    -e MSSQL_PID=Developer \
    -e MSSQL_AGENT_ENABLED=true \
    mcr.microsoft.com/mssql/server:2022-latest

# -- 7. Wait for SQL Server ----------------------------------------------------
echo "Waiting for SQL Server on 127.0.0.1:1433 (up to 120s)..."
_mssql_ready=0
for i in $(seq 1 60); do
    if (echo >/dev/tcp/127.0.0.1/1433) 2>/dev/null; then
        # Let's double check if we can run a query
        if $DOCKER exec sqlserver /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "${MSSQL_SA_PASSWORD}" -C -Q "SELECT 1" >/dev/null 2>&1; then
            _mssql_ready=1; break
        fi
    fi
    sleep 2
done
[ "$_mssql_ready" -eq 0 ] && {
    echo "ERROR: SQL Server did not start or authenticate."
    $DOCKER logs sqlserver | tail -20
    exit 1
}
echo "SQL Server is up and accepting commands."

# -- 8. Load Chinook dataset into SQL Server (CDC source) ----------------------
echo "Creating database and seeding Chinook dataset..."
$DOCKER exec sqlserver /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "${MSSQL_SA_PASSWORD}" -C -Q "CREATE DATABASE chinook;"
$DOCKER exec -i sqlserver /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "${MSSQL_SA_PASSWORD}" -C < ${WORKDIR}/chinook.sql
echo "Chinook dataset and CDC configurations successfully loaded on SQL Server."

# -- 9. Wait for Kafka Connect REST API ----------------------------------------
echo "Waiting for Kafka Connect on 127.0.0.1:${KAFKA_CONNECT_PORT} (up to 3 min)..."
_kc_ready=0
for i in $(seq 1 90); do
    if curl -sf "http://127.0.0.1:${KAFKA_CONNECT_PORT}/" >/dev/null 2>&1; then
        _kc_ready=1; break
    fi
    sleep 2
done
[ "$_kc_ready" -eq 0 ] && {
    echo "ERROR: Kafka Connect did not become ready."
    $DOCKER logs init-cdc-sqlserver-ybdb-connect-1 | tail -30
    exit 1
}
echo "Kafka Connect is ready."

echo ""
echo "Kafka Connect  ->  http://localhost:${KAFKA_CONNECT_PORT}/"
echo "SQL Server     ->  localhost:1433  (user: sa / Yugabyte@123)"
echo "YugabyteDB     ->  localhost:5433  (user: yugabyte / yugabyte)"
echo "YugabyteDB UI  ->  http://localhost:15433/"
