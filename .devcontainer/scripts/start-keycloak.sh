#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# start-keycloak.sh  —  Keycloak + YugabyteDB exercise startup
#
# Network strategy: --net container:DC_ID shares the devcontainer's network
# namespace so Keycloak binds on the devcontainer's 127.0.0.1 and can reach
# YugabyteDB's YSQL port on the same loopback.  Same pattern as start-cdc.sh.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

sudo chmod 666 /var/run/docker.sock 2>/dev/null || true

KC_VERSION="${KC_VERSION:-26.2.4}"
KC_PORT="${KC_PORT:-8080}"
KC_DB_NAME="keycloak"
KC_DB_USER="keycloak"
KC_DB_PASS="keycloak123"
KC_ADMIN_USER="admin"
KC_ADMIN_PASS="admin"
YB_JDBC_VERSION="${YB_JDBC_VERSION:-42.7.3-yb-4}"
YB_JDBC_JAR="/tmp/jdbc-yugabytedb-${YB_JDBC_VERSION}.jar"

# ── Docker CLI ────────────────────────────────────────────────────────────────
DOCKER=""
for _candidate in /usr/local/bin/docker /usr/bin/docker; do
  if [ -x "$_candidate" ] && "$_candidate" --version >/dev/null 2>&1; then
    DOCKER="$_candidate"; break
  fi
done
[ -z "$DOCKER" ] && { echo "❌ Docker CLI not found."; exit 1; }

# ── Devcontainer network ID  ──────────────────────────────────────────────────
DC_ID=$(grep -oE '/docker/[0-9a-f]+' /proc/1/cpuset 2>/dev/null \
  | head -1 | cut -d/ -f3 || hostname)
echo "Devcontainer ID: ${DC_ID:0:12}..."

# ── 1. YugabyteDB ─────────────────────────────────────────────────────────────
bash .devcontainer/scripts/start-ybdb.sh 1

# ── 2. Keycloak database & role ───────────────────────────────────────────────
echo "Setting up Keycloak role and database in YugabyteDB..."
ysqlsh -h 127.0.0.1 <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${KC_DB_USER}') THEN
    CREATE ROLE ${KC_DB_USER} WITH LOGIN PASSWORD '${KC_DB_PASS}' CREATEDB;
  END IF;
END
\$\$;
SQL
ysqlsh -h 127.0.0.1 -c "CREATE DATABASE ${KC_DB_NAME} OWNER ${KC_DB_USER};" 2>/dev/null || true
echo "✅ Keycloak database ready in YugabyteDB."

# ── 3. Remove stale Keycloak container ───────────────────────────────────────
$DOCKER rm -f keycloak-ybdb 2>/dev/null || true

# ── 4. Download YugabyteDB JDBC driver ────────────────────────────────────────
if [ ! -f "${YB_JDBC_JAR}" ]; then
  echo "Downloading YugabyteDB JDBC driver ${YB_JDBC_VERSION}..."
  curl -fsSL \
    "https://repo1.maven.org/maven2/com/yugabyte/jdbc-yugabytedb/${YB_JDBC_VERSION}/jdbc-yugabytedb-${YB_JDBC_VERSION}.jar" \
    -o "${YB_JDBC_JAR}"
fi

# ── 5. Build custom Keycloak image with YugabyteDB JDBC driver ─────────────────
# kc.sh build must run at image-build time so the Quarkus augmentation artifacts
# include the driver class — a bind mount at container start is too late.
KC_IMAGE="keycloak-yugabyte:${KC_VERSION}"
if ! $DOCKER image inspect "${KC_IMAGE}" >/dev/null 2>&1; then
  echo "Building Keycloak + YugabyteDB JDBC image (one-time, ~2 min)..."
  TEMP_CTX=$(mktemp -d)
  cp "${YB_JDBC_JAR}" "${TEMP_CTX}/jdbc-yugabytedb.jar"
  cat > "${TEMP_CTX}/Dockerfile" << DOCKERFILE
FROM quay.io/keycloak/keycloak:${KC_VERSION}
COPY jdbc-yugabytedb.jar /opt/keycloak/providers/
ENV KC_DB=postgres
ENV KC_DB_DRIVER=com.yugabyte.Driver
RUN /opt/keycloak/bin/kc.sh build
DOCKERFILE
  $DOCKER build -t "${KC_IMAGE}" "${TEMP_CTX}"
  rm -rf "${TEMP_CTX}"
fi

# ── 6. Start Keycloak ─────────────────────────────────────────────────────────
echo "Starting Keycloak ${KC_VERSION} with YugabyteDB smart JDBC driver..."
$DOCKER run -d \
  --name keycloak-ybdb \
  --net "container:${DC_ID}" \
  --restart on-failure \
  -e KEYCLOAK_ADMIN="${KC_ADMIN_USER}" \
  -e KEYCLOAK_ADMIN_PASSWORD="${KC_ADMIN_PASS}" \
  -e KC_DB_URL="jdbc:yugabytedb://127.0.0.1:5433/${KC_DB_NAME}" \
  -e KC_DB_USERNAME="${KC_DB_USER}" \
  -e KC_DB_PASSWORD="${KC_DB_PASS}" \
  -e KC_HOSTNAME_STRICT=false \
  -e KC_HTTP_ENABLED=true \
  "${KC_IMAGE}" start-dev

# ── 7. Wait for Keycloak ──────────────────────────────────────────────────────
echo "⏳ Waiting for Keycloak on :${KC_PORT} (up to 3 min)..."
_ready=0
for i in $(seq 1 60); do
  if (echo >/dev/tcp/127.0.0.1/${KC_PORT}) 2>/dev/null; then
    _ready=1; break
  fi
  sleep 3
done

if [ "$_ready" -eq 0 ]; then
  echo "❌ Keycloak did not become ready in time."
  echo "   Check logs: docker logs keycloak-ybdb"
  exit 1
fi

echo "✅ Keycloak is ready on http://localhost:${KC_PORT}"
echo "   Admin console: http://localhost:${KC_PORT}/admin"
echo "   Credentials:   ${KC_ADMIN_USER} / ${KC_ADMIN_PASS}"
