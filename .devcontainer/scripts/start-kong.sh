#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# start-kong.sh  —  Kong Gateway + YugabyteDB exercise startup
#
# Network strategy: --net container:DC_ID shares the devcontainer's network
# namespace so Kong binds on the devcontainer's 127.0.0.1 and can reach
# YugabyteDB's YSQL port on the same loopback.  Same pattern as start-keycloak.sh.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

sudo chmod 666 /var/run/docker.sock 2>/dev/null || true

KONG_VERSION="${KONG_VERSION:-3.9}"
KONG_DB_NAME="kong"
KONG_DB_USER="kong"
KONG_DB_PASS="kong"

# ── Docker CLI ────────────────────────────────────────────────────────────────
DOCKER=""
for _candidate in /usr/local/bin/docker /usr/bin/docker; do
  if [ -x "$_candidate" ] && "$_candidate" --version >/dev/null 2>&1; then
    DOCKER="$_candidate"; break
  fi
done
[ -z "$DOCKER" ] && { echo "❌ Docker CLI not found."; exit 1; }

# ── Devcontainer network ID ───────────────────────────────────────────────────
DC_ID=$(grep -oE '/docker/[0-9a-f]+' /proc/1/cpuset 2>/dev/null \
  | head -1 | cut -d/ -f3 || hostname)
echo "Devcontainer ID: ${DC_ID:0:12}..."

# ── 1. YugabyteDB ─────────────────────────────────────────────────────────────
bash .devcontainer/scripts/start-ybdb.sh 1

# ── 2. Kong database & role in YugabyteDB ─────────────────────────────────────
echo "Setting up Kong role and database in YugabyteDB..."
ysqlsh -h 127.0.0.1 <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${KONG_DB_USER}') THEN
    CREATE ROLE ${KONG_DB_USER} WITH LOGIN PASSWORD '${KONG_DB_PASS}' CREATEDB;
  END IF;
END
\$\$;
SQL
ysqlsh -h 127.0.0.1 -c "CREATE DATABASE ${KONG_DB_NAME} OWNER ${KONG_DB_USER};" 2>/dev/null || true
echo "✅ Kong database ready in YugabyteDB."

# ── 3. Remove stale Kong container ───────────────────────────────────────────
$DOCKER rm -f kong-gateway 2>/dev/null || true

KONG_ENV=(
  -e KONG_DATABASE=postgres
  -e KONG_PG_HOST=127.0.0.1
  -e KONG_PG_PORT=5433
  -e KONG_PG_USER="${KONG_DB_USER}"
  -e KONG_PG_PASSWORD="${KONG_DB_PASS}"
  -e KONG_PG_DATABASE="${KONG_DB_NAME}"
  # YugabyteDB distributed DDL can take longer than the 5 000 ms default.
  -e KONG_PG_TIMEOUT=60000
)

# ── 4. Run Kong migrations against YugabyteDB ─────────────────────────────────
echo "Running Kong migrations against YugabyteDB (one-time)..."
$DOCKER run --rm \
  --net "container:${DC_ID}" \
  "${KONG_ENV[@]}" \
  kong:"${KONG_VERSION}" kong migrations bootstrap

# ── 5. Start Kong Gateway ─────────────────────────────────────────────────────
echo "Starting Kong Gateway ${KONG_VERSION}..."
$DOCKER run -d \
  --name kong-gateway \
  --net "container:${DC_ID}" \
  --restart on-failure \
  "${KONG_ENV[@]}" \
  -e KONG_PROXY_LISTEN="0.0.0.0:8000" \
  -e KONG_ADMIN_LISTEN="0.0.0.0:8001" \
  -e KONG_PROXY_ACCESS_LOG=/dev/stdout \
  -e KONG_ADMIN_ACCESS_LOG=/dev/stdout \
  -e KONG_PROXY_ERROR_LOG=/dev/stderr \
  -e KONG_ADMIN_ERROR_LOG=/dev/stderr \
  kong:"${KONG_VERSION}"

# ── 6. Wait for Kong Admin API ────────────────────────────────────────────────
echo "⏳ Waiting for Kong Admin API on :8001 (up to 2 min)..."
_ready=0
for i in $(seq 1 40); do
  if curl -sf http://127.0.0.1:8001/ >/dev/null 2>&1; then
    _ready=1; break
  fi
  sleep 3
done

if [ "$_ready" -eq 0 ]; then
  echo "❌ Kong Gateway did not become ready in time."
  echo "   Check logs: docker logs kong-gateway"
  exit 1
fi

echo "✅ Kong Gateway ${KONG_VERSION} is ready"
echo "   Proxy:   http://localhost:8000"
echo "   Admin:   http://localhost:8001"
echo "   Backend: YugabyteDB (yugabyte DB: ${KONG_DB_NAME})"
