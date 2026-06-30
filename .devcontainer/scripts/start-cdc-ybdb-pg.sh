#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# start-cdc.sh  --  CDC exercise service startup (postStartCommand)
#
# Network strategy:
#   --net container:DC_ID shares the devcontainer's network namespace so all
#   services bind to the devcontainer's loopback (127.0.0.1).  This is the
#   same pattern used by yb-voyager-wrapper.sh.
#
#   Root-cause note: Debezium's configure.sh calls 'hostname -i' to auto-detect
#   the Kafka listener IP.  With --net container:DC_ID, hostname -i resolves to
#   the devcontainer's bridge IP (172.17.0.x), so Kafka would bind only to
#   172.17.0.x:9092 -- making 127.0.0.1:9092 unreachable from BOOTSTRAP_SERVERS.
#   Fix: set KAFKA_LISTENERS=PLAINTEXT://0.0.0.0:9092 so Kafka binds to ALL
#   interfaces (including loopback), and KAFKA_ADVERTISED_HOST_NAME=127.0.0.1
#   so Connect gets 127.0.0.1 back in broker metadata instead of 172.17.0.x.
# -----------------------------------------------------------------------------
set -euo pipefail

sudo chmod 666 /var/run/docker.sock 2>/dev/null || true

KAFKA_CONNECT_PORT="${KAFKA_CONNECT_PORT:-8083}"
DEBEZIUM_VERSION="${DEBEZIUM_VERSION:-3.1.3.Final}"

# -- Find Docker CLI -----------------------------------------------------------
DOCKER=""
for _candidate in /usr/local/bin/docker /usr/bin/docker; do
    if [ -x "$_candidate" ] && "$_candidate" --version >/dev/null 2>&1; then
        DOCKER="$_candidate"; break
    fi
done
[ -z "$DOCKER" ] && { echo "ERROR: Docker CLI not found."; exit 1; }

# -- Detect devcontainer ID (same as yb-voyager-wrapper.sh) -------------------
DC_ID=$(grep -oE '/docker/[0-9a-f]+' /proc/1/cpuset 2>/dev/null \
        | head -1 | cut -d/ -f3 || hostname)
echo "Devcontainer ID: ${DC_ID:0:12}..."

# -- 1. YugabyteDB ------------------------------------------------------------
echo "Starting YugabyteDB with logical replication flags..."
bash .devcontainer/scripts/start-ybdb.sh 1 "${TSERVER_FLAGS:-ysql_yb_default_replica_identity=DEFAULT}"

# -- 2. Remove stale CDC containers -------------------------------------------
echo "Removing stale CDC containers..."
for _ctr in init-cdc-ybdb-pg-zookeeper-1 init-cdc-ybdb-pg-kafka-1 init-cdc-ybdb-pg-connect-1 postgres; do
    $DOCKER rm -f "$_ctr" 2>/dev/null || true
done

# -- 3. ZooKeeper -------------------------------------------------------------
echo "Starting ZooKeeper..."
$DOCKER run -d \
    --name init-cdc-ybdb-pg-zookeeper-1 \
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
    $DOCKER logs init-cdc-ybdb-pg-zookeeper-1 | tail -20
    exit 1
fi
echo "ZooKeeper is up."

# -- 4. Kafka -----------------------------------------------------------------
# KAFKA_LISTENERS=PLAINTEXT://0.0.0.0:9092 overrides Debezium's auto-detected
# listener (which would be 172.17.0.x:9092 -- the devcontainer's bridge IP).
# Without this, 127.0.0.1:9092 used by BOOTSTRAP_SERVERS is never reachable.
echo "Starting Kafka..."
$DOCKER run -d \
    --name init-cdc-ybdb-pg-kafka-1 \
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
    $DOCKER logs init-cdc-ybdb-pg-kafka-1 | tail -30
    exit 1
fi
echo "Kafka is up."

# -- 5. Verify connector JARs are in the plugin volume -----------------------
echo "Verifying connector plugin JARs in init-cdc-ybdb-pg_kafka-plugins..."
_jar_count=$($DOCKER run --rm -v init-cdc-ybdb-pg_kafka-plugins:/plugins \
    busybox sh -c 'ls /plugins/*.jar 2>/dev/null | wc -l')
if [ "${_jar_count:-0}" -eq 0 ]; then
    echo "ERROR: No JARs found in init-cdc-ybdb-pg_kafka-plugins volume."
    echo "  The connector JARs were not loaded during postCreateCommand."
    echo "  Fix: run 'bash .devcontainer/scripts/setup-cdc-ybdb-pg.sh' then re-run this script."
    exit 1
fi
echo "Plugin JARs ready: ${_jar_count} file(s) in volume."

# -- 6. Kafka Connect + PostgreSQL (start together after Kafka is ready) ------
echo "Starting Kafka Connect and PostgreSQL..."

$DOCKER run -d \
    --name init-cdc-ybdb-pg-connect-1 \
    --net "container:${DC_ID}" \
    --restart on-failure \
    --platform linux/amd64 \
    -e BOOTSTRAP_SERVERS=127.0.0.1:9092 \
    -e GROUP_ID=1 \
    -e CONFIG_STORAGE_TOPIC=cdc_connect_configs \
    -e OFFSET_STORAGE_TOPIC=cdc_connect_offsets \
    -e STATUS_STORAGE_TOPIC=cdc_connect_statuses \
    -v init-cdc-ybdb-pg_kafka-plugins:/kafka/connect/yugabytedb \
    quay.io/debezium/connect:${DEBEZIUM_VERSION}

$DOCKER volume create init-cdc-ybdb-pg_postgresql_data 2>/dev/null || true
$DOCKER run -d \
    --name init-cdc-ybdb-pg-postgres \
    --net "container:${DC_ID}" \
    --restart on-failure \
    --platform linux/amd64 \
    -e POSTGRES_PASSWORD=yugabyte \
    -e POSTGRES_DB=postgres \
    -v init-cdc-ybdb-pg_postgresql_data:/var/lib/postgresql/data \
    postgres:14

# -- 7. Wait for PostgreSQL ---------------------------------------------------
echo "Waiting for PostgreSQL on 127.0.0.1:5432 (up to 90s)..."
_pg_ready=0
for i in $(seq 1 30); do
    if (echo >/dev/tcp/127.0.0.1/5432) 2>/dev/null; then
        _pg_ready=1; break
    fi
    sleep 3
done
[ "$_pg_ready" -eq 0 ] && {
    echo "ERROR: PostgreSQL did not start."
    $DOCKER logs init-cdc-ybdb-pg-postgres | tail -20
    exit 1
}
echo "PostgreSQL is up."

# -- 8. Wait for Kafka Connect REST API ---------------------------------------
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
    $DOCKER logs init-cdc-ybdb-pg-connect-1 | tail -30
    exit 1
}
echo "Kafka Connect is ready."

# -- 9. Seed CDC source data --------------------------------------------------
echo "Loading Chinook dataset into YugabyteDB (CDC source)..."
ysqlsh -f init-cdc-ybdb-pg/chinook.sql
echo "Chinook data loaded."

echo ""
echo "Kafka Connect  ->  http://localhost:${KAFKA_CONNECT_PORT}/"
echo "PostgreSQL     ->  localhost:5432  (user: postgres / yugabyte)"
echo "YugabyteDB     ->  localhost:5433  (user: yugabyte / yugabyte)"
echo "YugabyteDB UI  ->  http://localhost:15433/"
