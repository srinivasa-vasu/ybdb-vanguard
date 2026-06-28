#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# start-wso2.sh  —  WSO2 API Manager + YugabyteDB exercise startup
#
# Two databases:
#   wso2_shareddb  —  Carbon/Identity tables (UM_*, REG_*, IDN_*)
#   wso2_amdb      —  API Manager tables (AM_*)
#
# YugabyteDB driver swap:  standard PostgreSQL JDBC  →  com.yugabyte.Driver
#   - YB JAR bind-mounted into  repository/components/lib/
#   - deployment.toml patched to use YugabyteDB URL + driver class
#
# Schema bootstrap:  SQL scripts piped directly from the image via
# docker run --entrypoint cat,  run once against YugabyteDB on first boot.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

sudo chmod 666 /var/run/docker.sock 2>/dev/null || true

WSO2_VERSION="${WSO2_VERSION:-4.7.0}"
WSO2_IMAGE="wso2/wso2am:${WSO2_VERSION}"
WSO2_HOME="/home/wso2carbon/wso2am-${WSO2_VERSION}"
WSO2_DB_USER="wso2"
WSO2_DB_PASS="wso2"
WORK_DIR="/tmp/wso2-init"
YB_JAR="jdbc-yugabytedb-42.7.3-yb-4.jar"
YB_JAR_URL="https://github.com/yugabyte/pgjdbc/releases/download/v42.7.3-yb-4/${YB_JAR}"

mkdir -p "${WORK_DIR}"

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
# Preview flags required for WSO2's concurrent DDL: object-level table locks and
# DDL transaction blocks prevent mid-schema aborts (YB001) on large SQL scripts.
WSO2_TFLAGS="allowed_preview_flags_csv={ysql_yb_ddl_transaction_block_enabled,enable_object_locking_for_table_locks},ysql_yb_ddl_transaction_block_enabled=true,enable_object_locking_for_table_locks=true"
bash .devcontainer/scripts/start-ybdb.sh 1 "${WSO2_TFLAGS}"

# ── 2. WSO2 role + databases ──────────────────────────────────────────────────
echo "Setting up WSO2 role and databases in YugabyteDB..."
ysqlsh -h 127.0.0.1 << SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${WSO2_DB_USER}') THEN
    CREATE ROLE ${WSO2_DB_USER} WITH LOGIN PASSWORD '${WSO2_DB_PASS}' CREATEDB;
  END IF;
END
\$\$;
SQL
ysqlsh -h 127.0.0.1 -c "CREATE DATABASE wso2_amdb     OWNER ${WSO2_DB_USER};" 2>/dev/null || true
ysqlsh -h 127.0.0.1 -c "CREATE DATABASE wso2_shareddb OWNER ${WSO2_DB_USER};" 2>/dev/null || true
echo "✅ WSO2 databases ready in YugabyteDB."

# ── 3. Pull image + extract default deployment.toml ───────────────────────────
echo "Pulling WSO2 APIM ${WSO2_VERSION} image (~1.5 GB on first run)..."
$DOCKER pull "${WSO2_IMAGE}"

# Scripts live inside the image — no need to copy them out.
# Extract only deployment.toml (needed to patch and bake into the custom image).
# Cache is version-stamped; re-extracts automatically when WSO2_VERSION changes.
if [ "$(cat "${WORK_DIR}/.toml-version" 2>/dev/null)" != "${WSO2_VERSION}" ]; then
  echo "Extracting deployment.toml from image..."
  $DOCKER run --rm --entrypoint cat "${WSO2_IMAGE}" \
    "${WSO2_HOME}/repository/conf/deployment.toml" > "${WORK_DIR}/deployment.toml.orig"
  echo "${WSO2_VERSION}" > "${WORK_DIR}/.toml-version"
fi

# ── 4. Bootstrap schemas ──────────────────────────────────────────────────────
# Pipe scripts directly from the image into ysqlsh — no local copies required.
# sed strips \set ON_ERROR_STOP so a YugabyteDB-incompatible statement does not
# abort ysqlsh before all tables are created.
_run_sql() {
  local script="$1" db="$2"
  $DOCKER run --rm --entrypoint cat "${WSO2_IMAGE}" "${script}" 2>/dev/null \
    | sed '/ON_ERROR_STOP/Id' \
    | ysqlsh -h 127.0.0.1 -U "${WSO2_DB_USER}" -d "${db}" 2>/dev/null || true
}

SENTINEL=$(ysqlsh -h 127.0.0.1 -U "${WSO2_DB_USER}" -d wso2_amdb -t \
  -c "SELECT COUNT(*) FROM information_schema.tables
      WHERE table_schema='public' AND table_name='am_system_configs'" \
  2>/dev/null | xargs || echo "0")

if [ "${SENTINEL:-0}" -eq 0 ]; then
  echo "Running WSO2 schema scripts against YugabyteDB..."
  _run_sql "${WSO2_HOME}/dbscripts/postgresql.sql"              wso2_shareddb
  _run_sql "${WSO2_HOME}/dbscripts/identity/postgresql.sql"     wso2_shareddb
  _run_sql "${WSO2_HOME}/dbscripts/consent/postgresql.sql"      wso2_shareddb
  _run_sql "${WSO2_HOME}/dbscripts/identity/uma/postgresql.sql" wso2_shareddb
  _run_sql "${WSO2_HOME}/dbscripts/apimgt/postgresql.sql"       wso2_amdb
  echo "✅ WSO2 schemas bootstrapped."
else
  echo "✅ WSO2 schemas already complete (am_system_configs present)."
fi

# ── 5. Patch deployment.toml: H2 → YugabyteDB ────────────────────────────────
python3 << 'PYEOF'
import sys

src  = '/tmp/wso2-init/deployment.toml.orig'
dest = '/tmp/wso2-init/deployment.toml'

with open(src) as f:
    lines = f.readlines()

CONN_PARAMS = 'sslmode=disable&amp;connectTimeout=10'
YB_AMDB   = f'jdbc:yugabytedb://127.0.0.1:5433/wso2_amdb?{CONN_PARAMS}'
YB_SHARED = f'jdbc:yugabytedb://127.0.0.1:5433/wso2_shareddb?{CONN_PARAMS}'
YB_DRIVER = 'com.yugabyte.Driver'
YB_USER   = 'wso2'
YB_PASS   = 'wso2'

SECTIONS = {
    '[database.apim_db]':   (YB_AMDB,   YB_USER, YB_PASS),
    '[database.shared_db]': (YB_SHARED, YB_USER, YB_PASS),
}

def pool_opts(section_key):
    return (
        f'[{section_key}.pool_options]\n'
        'defaultAutoCommit = "false"\n'
        'commitOnReturn = "true"\n'
        'rollbackOnReturn = "true"\n'
        'testOnBorrow = true\n'
        'validationQuery = "SELECT 1"\n'
        'validationInterval = "30000"\n'
        'maxWait = "30000"\n'
    )

result         = []
skip_section   = False
current_parent = None

for line in lines:
    stripped = line.rstrip()

    if stripped in SECTIONS:
        url, user, pwd = SECTIONS[stripped]
        section_key = stripped[1:-1]
        result.append(f'[{section_key}]\n')
        result.append(f'type = "postgre"\n')
        result.append(f'url = "{url}"\n')
        result.append(f'username = "{user}"\n')
        result.append(f'password = "{pwd}"\n')
        result.append(f'driver = "{YB_DRIVER}"\n')
        result.append('\n')
        result.append(pool_opts(section_key))
        skip_section   = True
        current_parent = section_key
        continue

    if skip_section:
        if stripped.startswith('['):
            # Still inside a sub-section of the replaced block — skip it
            if current_parent and stripped.startswith(f'[{current_parent}.'):
                continue
            skip_section   = False
            current_parent = None
            result.append(line)
        continue

    result.append(line)

with open(dest, 'w') as f:
    f.writelines(result)
print('deployment.toml patched for YugabyteDB.')
PYEOF

# ── 6. YugabyteDB JDBC JAR ────────────────────────────────────────────────────
if [ ! -f "${WORK_DIR}/${YB_JAR}" ]; then
  echo "Downloading YugabyteDB JDBC driver..."
  curl -sfL "${YB_JAR_URL}" -o "${WORK_DIR}/${YB_JAR}" || {
    echo "❌ Failed to download YB JDBC JAR from ${YB_JAR_URL}"; exit 1; }
fi
echo "✅ YugabyteDB JDBC driver ready."

# ── 7. Build patched WSO2 image (bakes deployment.toml + YB JAR in) ───────────
# We cannot bind-mount files from the devcontainer's /tmp into sibling Docker
# containers because the Docker daemon resolves host paths on the Mac host, not
# inside the devcontainer.  Instead we build a thin wrapper image — docker build
# sends the build context via the socket as a tar stream, so paths are resolved
# client-side (devcontainer) without any host-path dependency.
WSO2_PATCHED_IMAGE="wso2am-ybdb:${WSO2_VERSION}"

if ! $DOCKER image inspect "${WSO2_PATCHED_IMAGE}" >/dev/null 2>&1; then
  echo "Building patched WSO2 image with YugabyteDB driver (one-time, ~1 min)..."
  cat > "${WORK_DIR}/Dockerfile" << DOCKERFILE
FROM ${WSO2_IMAGE}
COPY deployment.toml ${WSO2_HOME}/repository/conf/deployment.toml
COPY ${YB_JAR}       ${WSO2_HOME}/repository/components/lib/${YB_JAR}
DOCKERFILE
  $DOCKER build --no-cache -t "${WSO2_PATCHED_IMAGE}" "${WORK_DIR}"
  echo "✅ Patched WSO2 image built: ${WSO2_PATCHED_IMAGE}"
else
  echo "✅ Patched WSO2 image already exists: ${WSO2_PATCHED_IMAGE}"
fi

# ── 8. Start WSO2 API Manager ─────────────────────────────────────────────────
$DOCKER rm -f wso2-apim 2>/dev/null || true

echo "Starting WSO2 API Manager ${WSO2_VERSION} (first boot takes 3–5 min)..."
$DOCKER run -d \
  --name wso2-apim \
  --net "container:${DC_ID}" \
  --restart on-failure \
  "${WSO2_PATCHED_IMAGE}"

# ── 9. Wait for WSO2 ─────────────────────────────────────────────────────────
echo "⏳ Waiting for WSO2 APIM on :9443 (up to 10 min)..."
_ready=0
for i in $(seq 1 120); do
  if (echo >/dev/tcp/127.0.0.1/9443) 2>/dev/null; then
    _ready=1; break
  fi
  sleep 5
done

if [ "$_ready" -eq 0 ]; then
  echo "❌ WSO2 APIM did not become ready in time."
  echo "   Check logs: docker logs wso2-apim"
  exit 1
fi

echo "✅ WSO2 API Manager ${WSO2_VERSION} is ready"
echo "   Publisher:     https://localhost:9443/publisher  (admin / admin)"
echo "   Dev Portal:    https://localhost:9443/devportal"
echo "   Admin Console: https://localhost:9443/carbon"
echo "   Gateway HTTP:  http://localhost:8280"
echo "   Shared DB:     wso2_shareddb  (UM_*, REG_*, IDN_* tables)"
echo "   API Mgr DB:    wso2_amdb      (AM_* tables)"
