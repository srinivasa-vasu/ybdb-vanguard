#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# setup-cdc-mysql-ybdb.sh  --  one-time environment setup (postCreateCommand)
#
# Downloads the YugabyteDB JDBC driver JAR into the 'kafka-plugins' Docker
# named volume so Kafka Connect can find it at runtime for the JDBC sink.
# -----------------------------------------------------------------------------
set -euo pipefail

# -- Fix Docker socket permissions --------------------------------------------
[ -S /var/run/docker.sock ] && sudo chmod 666 /var/run/docker.sock 2>/dev/null || true

# -- Find Docker CLI (verify it actually runs, fall back to static binary) ----
DOCKER=""
for _candidate in /usr/local/bin/docker /usr/bin/docker; do
    if [ -x "$_candidate" ] && "$_candidate" --version >/dev/null 2>&1; then
        DOCKER="$_candidate"; break
    fi
done
if [ -z "$DOCKER" ]; then
    echo "Docker CLI not found -- downloading static binary..."
    ARCH=$(uname -m)
    sudo curl -fsSL \
        "https://download.docker.com/linux/static/stable/${ARCH}/docker-24.0.7.tgz" \
        | sudo tar xz -C /usr/local/bin --strip-components=1 docker/docker
    DOCKER=/usr/local/bin/docker
fi
echo "Using $($DOCKER --version)"

STAGING="/tmp/cdc-mysql-plugins"
mkdir -p "${STAGING}"

# -- Download YugabyteDB JDBC driver ------------------------------------------
# Placed alongside the connectors so Kafka Connect can load it.
YB_JDBC_JAR="jdbc-yugabytedb-42.7.3-yb-4.jar"
echo "Downloading YugabyteDB JDBC driver..."
curl -# -L --fail \
    -o "${STAGING}/${YB_JDBC_JAR}" \
    "https://github.com/yugabyte/pgjdbc/releases/download/v42.7.3-yb-4/${YB_JDBC_JAR}"
python3 -c "import sys; d=open('${STAGING}/${YB_JDBC_JAR}','rb').read(4); sys.exit(0 if d[:2]==b'PK' else 1)" 2>/dev/null \
    || { echo "ERROR: Downloaded file is not a valid JAR (no PK header)."; exit 1; }
echo "  OK: $(ls -lh "${STAGING}/${YB_JDBC_JAR}" | awk '{print $5}') — valid JAR"

echo "Downloaded JARs:"
ls -lh "${STAGING}/"

# -- Load JARs into the named volume via docker cp ----------------------------
echo "Populating init-cdc-mysql-ybdb_kafka-plugins volume..."
$DOCKER volume create init-cdc-mysql-ybdb_kafka-plugins 2>/dev/null || true

_tmp_ctr="cdc-mysql-jar-copy-$$"
$DOCKER create --name "${_tmp_ctr}" \
    -v init-cdc-mysql-ybdb_kafka-plugins:/plugins \
    busybox true
$DOCKER cp "${STAGING}/." "${_tmp_ctr}:/plugins/"
$DOCKER rm "${_tmp_ctr}" >/dev/null

echo "Volume contents:"
$DOCKER run --rm -v init-cdc-mysql-ybdb_kafka-plugins:/plugins busybox ls -lh /plugins/

# -- Pre-pull Debezium and MySQL images ---------------------------------------
echo "Pulling Debezium and MySQL Docker images..."
$DOCKER pull mysql:8.4
$DOCKER pull quay.io/debezium/zookeeper:3.1.3.Final
$DOCKER pull quay.io/debezium/kafka:3.1.3.Final
$DOCKER pull quay.io/debezium/connect:3.1.3.Final
echo "Docker images ready."

echo ""
echo "CDC MySQL setup complete."
echo "  JARs loaded into Docker volume 'init-cdc-mysql-ybdb_kafka-plugins'"
