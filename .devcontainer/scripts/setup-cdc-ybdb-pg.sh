#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# setup-cdc-ybdb-pg.sh  --  one-time CDC environment setup (postCreateCommand)
#
# Downloads the YugabyteDB source connector JAR into the 'kafka-plugins' Docker
# named volume so Kafka Connect can find it at runtime.
# The Debezium JDBC sink connector is already bundled in debezium/connect.
#
# Why docker cp instead of -v bind mount:
#   In DooD (Docker-outside-of-Docker) the Docker daemon runs on the HOST
#   machine (e.g. the Lima VM), not inside the devcontainer. A bind mount
#   like -v /tmp/foo:/bar resolves /tmp/foo on the DAEMON HOST, not the
#   devcontainer -- so the staging directory would be missing.
#   docker cp reads the source path from the CLIENT's (devcontainer's)
#   filesystem over the API socket, which is always correct.
#
# Bump YBDB_CONNECTOR_VERSION in devcontainer.json when a new release is out.
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

YBDB_CONNECTOR_VERSION="${YBDB_CONNECTOR_VERSION:-dz.2.5.2.yb.2025.2.3}"

STAGING="/tmp/cdc-plugins"
mkdir -p "${STAGING}"

# -- Download YugabyteDB source connector -------------------------------------
# The jar-with-dependencies (~8 MB) bundles the PG connector code but NOT
# Debezium core (provided by the Connect image). Compiled for Java 17, so the
# Connect image must also run Java 17 — use quay.io/debezium/connect:3.1.3.Final.
YB_JAR="yugabytedb-source-connector-${YBDB_CONNECTOR_VERSION}-jar-with-dependencies.jar"
echo "Downloading YugabyteDB source connector ${YBDB_CONNECTOR_VERSION}..."
curl -# -L --fail \
    -o "${STAGING}/${YB_JAR}" \
    "https://github.com/yugabyte/debezium/releases/download/${YBDB_CONNECTOR_VERSION}/${YB_JAR}"
python3 -c "import sys; d=open('${STAGING}/${YB_JAR}','rb').read(4); sys.exit(0 if d[:2]==b'PK' else 1)" 2>/dev/null \
    || { echo "ERROR: Downloaded file is not a valid JAR (no PK header)."; exit 1; }
echo "  OK: $(ls -lh "${STAGING}/${YB_JAR}" | awk '{print $5}') — valid JAR"

# -- Download YugabyteDB JDBC driver ------------------------------------------
# Placed alongside the source connector so its classloader can find it.
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
# docker cp reads SOURCE from the client's (devcontainer's) filesystem over
# the API socket -- it does NOT suffer from the DooD bind-mount path issue.
echo "Populating init-cdc-ybdb-pg_kafka-plugins volume..."
$DOCKER volume create init-cdc-ybdb-pg_kafka-plugins 2>/dev/null || true

_tmp_ctr="cdc-jar-copy-$$"
$DOCKER create --name "${_tmp_ctr}" \
    -v init-cdc-ybdb-pg_kafka-plugins:/plugins \
    busybox true
$DOCKER cp "${STAGING}/." "${_tmp_ctr}:/plugins/"
$DOCKER rm "${_tmp_ctr}" >/dev/null

echo "Volume contents:"
$DOCKER run --rm -v init-cdc-ybdb-pg_kafka-plugins:/plugins busybox ls -lh /plugins/

# -- Pre-pull Debezium stack images -------------------------------------------
echo "Pulling Debezium and PostgreSQL Docker images..."
docker-compose -f init-cdc-ybdb-pg/compose.yml pull
echo "Docker images ready."

echo ""
echo "CDC setup complete."
echo "  JARs loaded into Docker volume 'init-cdc-ybdb-pg_kafka-plugins'"
