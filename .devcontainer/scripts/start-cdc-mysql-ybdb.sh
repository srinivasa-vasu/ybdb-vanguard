#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# start-cdc-mysql-ybdb.sh  --  CDC MySQL service startup (postStartCommand)
# -----------------------------------------------------------------------------
set -euo pipefail

sudo chmod 666 /var/run/docker.sock 2>/dev/null || true

KAFKA_CONNECT_PORT="${KAFKA_CONNECT_PORT:-8083}"
# Versions come from containerEnv in .devcontainer/init-cdc-mysql-ybdb/override.json
: "${DEBEZIUM_VERSION:?DEBEZIUM_VERSION not set (see override.json)}"
: "${MYSQL_VERSION:?MYSQL_VERSION not set (see override.json)}"
MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-yugabyte}"
WORKDIR="init-cdc-mysql-ybdb"

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
for _ctr in init-cdc-mysql-ybdb-zookeeper-1 init-cdc-mysql-ybdb-kafka-1 init-cdc-mysql-ybdb-connect-1 mysql-cdc; do
    $DOCKER rm -f "$_ctr" 2>/dev/null || true
done

# -- 3. ZooKeeper -------------------------------------------------------------
echo "Starting ZooKeeper..."
$DOCKER run -d \
    --name init-cdc-mysql-ybdb-zookeeper-1 \
    --net "container:${DC_ID}" \
    --restart on-failure \
    quay.io/debezium/zookeeper:${DEBEZIUM_VERSION}

echo "Waiting for ZooKeeper on 127.0.0.1:2181 (up to 60s)..."
for i in $(seq 1 30); do
    (echo >/dev/tcp/127.0.0.1/2181) 2>/dev/null && break
    sleep 2
done
if ! (echo >/dev/tcp/127.0.0.1/2181) 2>/dev/null; then
    echo "ERROR: ZooKeeper did not start."
    $DOCKER logs init-cdc-mysql-ybdb-zookeeper-1 | tail -20
    exit 1
fi
echo "ZooKeeper is up."

# -- 4. Kafka -----------------------------------------------------------------
echo "Starting Kafka..."
$DOCKER run -d \
    --name init-cdc-mysql-ybdb-kafka-1 \
    --net "container:${DC_ID}" \
    --restart on-failure \
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
    $DOCKER logs init-cdc-mysql-ybdb-kafka-1 | tail -30
    exit 1
fi
echo "Kafka is up."

# -- 5. Verify connector JARs in the plugin volume ----------------------------
echo "Verifying connector plugin JARs in init-cdc-mysql-ybdb_kafka-plugins..."
_jar_count=$($DOCKER run --rm -v init-cdc-mysql-ybdb_kafka-plugins:/plugins \
    busybox sh -c 'ls /plugins/*.jar 2>/dev/null | wc -l')
if [ "${_jar_count:-0}" -eq 0 ]; then
    echo "ERROR: No JARs found in init-cdc-mysql-ybdb_kafka-plugins volume."
    echo "  The JDBC driver JAR was not loaded during postCreateCommand."
    echo "  Fix: run 'bash .devcontainer/scripts/setup-cdc-mysql-ybdb.sh' then re-run this script."
    exit 1
fi
echo "Plugin JARs ready: ${_jar_count} file(s) in volume."

# -- 6. Kafka Connect & MySQL --------------------------------------------------
echo "Starting Kafka Connect and MySQL..."

$DOCKER run -d \
    --name init-cdc-mysql-ybdb-connect-1 \
    --net "container:${DC_ID}" \
    --restart on-failure \
    -e BOOTSTRAP_SERVERS=127.0.0.1:9092 \
    -e GROUP_ID=1 \
    -e CONFIG_STORAGE_TOPIC=cdc_connect_configs \
    -e OFFSET_STORAGE_TOPIC=cdc_connect_offsets \
    -e STATUS_STORAGE_TOPIC=cdc_connect_statuses \
    -e OFFSET_FLUSH_INTERVAL_MS=5000 \
    -v init-cdc-mysql-ybdb_kafka-plugins:/kafka/connect/yugabytedb \
    quay.io/debezium/connect:${DEBEZIUM_VERSION}

# Binlog settings Debezium relies on. log-bin, ROW format and FULL row image are
# already the MySQL 8.x defaults; they are spelled out here for clarity. GTIDs
# let the connector resume from a position-independent offset.
$DOCKER run -d \
    --name mysql-cdc \
    --net "container:${DC_ID}" \
    --restart on-failure \
    -e MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD}" \
    mysql:${MYSQL_VERSION} \
    --server-id=1 \
    --log-bin=mysql-bin \
    --binlog-row-image=FULL \
    --gtid-mode=ON \
    --enforce-gtid-consistency=ON

# -- 7. Wait for MySQL ---------------------------------------------------------
# First boot runs a temporary --skip-networking server to initialise the data
# directory, then restarts. Query over TCP so we only succeed against the final
# server, not the temporary one.
echo "Waiting for MySQL on 127.0.0.1:3306 (up to 120s)..."
_mysql_ready=0
for i in $(seq 1 60); do
    if (echo >/dev/tcp/127.0.0.1/3306) 2>/dev/null; then
        if $DOCKER exec -e MYSQL_PWD="${MYSQL_ROOT_PASSWORD}" mysql-cdc \
            mysql -h127.0.0.1 -uroot -e "SELECT 1" >/dev/null 2>&1; then
            _mysql_ready=1; break
        fi
    fi
    sleep 2
done
[ "$_mysql_ready" -eq 0 ] && {
    echo "ERROR: MySQL did not start or authenticate."
    $DOCKER logs mysql-cdc | tail -20
    exit 1
}
echo "MySQL is up and accepting commands."

# -- 8. Load Chinook dataset into MySQL (CDC source) ---------------------------
echo "Creating database, seeding Chinook dataset and the debezium user..."
$DOCKER exec -i -e MYSQL_PWD="${MYSQL_ROOT_PASSWORD}" mysql-cdc \
    mysql -h127.0.0.1 -uroot < ${WORKDIR}/chinook.sql
echo "Chinook dataset and Debezium user successfully loaded on MySQL."

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
    $DOCKER logs init-cdc-mysql-ybdb-connect-1 | tail -30
    exit 1
}
echo "Kafka Connect is ready."

echo ""
echo "Kafka Connect  ->  http://localhost:${KAFKA_CONNECT_PORT}/"
echo "MySQL          ->  localhost:3306  (user: root / ${MYSQL_ROOT_PASSWORD}, connector: debezium / dbz)"
echo "YugabyteDB     ->  localhost:5433  (user: yugabyte / yugabyte)"
echo "YugabyteDB UI  ->  http://localhost:15433/"
