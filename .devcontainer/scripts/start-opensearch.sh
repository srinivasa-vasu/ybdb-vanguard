#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# start-opensearch.sh  —  OpenSearch observability + YugabyteDB exercise startup
#
# Architecture:
#   opensearch              Docker container  :9200  (index store)
#   opensearch-dashboards   Docker container  :5601  (visualization)
#   otel-collector-contrib  Binary process           (log pipeline)
#
# OTel pipeline:
#   filelog/glog  receiver  ← YB master/tserver GLog files (multiline, structured)
#   filelog/pg    receiver  ← YB PostgreSQL / pgaudit log files
#   opensearch    exporter  → yb-logs  index
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

sudo chmod 666 /var/run/docker.sock 2>/dev/null || true

OPENSEARCH_VERSION="${OPENSEARCH_VERSION:-3.7.0}"
OTEL_VERSION="${OTEL_VERSION:-0.155.0}"
WORK_DIR="/tmp/opensearch-init"
OTEL_DIR="${WORK_DIR}/otel"
WORKSPACE="${PWD}"
DATA_PATH="${DATA_PATH:-ybdb}"

mkdir -p "${WORK_DIR}" "${OTEL_DIR}"

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

# ── 1. YugabyteDB ────────────────────────────────────────────────────────────
# ysql_pg_conf_csv value contains commas — write to flagfile so gflags reads it
# as a single flag line; pass flagfile= inline alongside any other tserver flags.
# PGCONF_FILE="${WORK_DIR}/yb-tserver.conf"
# cat > "${PGCONF_FILE}" << 'EOF'
# --ysql_pg_conf_csv="pgaudit.log='DDL, ROLE, WRITE, READ'",suppress_nonpg_logs=on,pgaudit.log_parameter=on,log_connections=on,log_disconnections=on,log_error_verbosity=default
# --ysql_log_statement=all
# EOF
# bash .devcontainer/scripts/start-ybdb.sh 1 "flagfile=${PGCONF_FILE}"
bash .devcontainer/scripts/start-ybdb.sh 1 "ysql_log_statement=all"

# ── 2. OpenSearch ─────────────────────────────────────────────────────────────
OPENSEARCH_IMAGE="opensearchproject/opensearch:${OPENSEARCH_VERSION}"
if ! $DOCKER image inspect "${OPENSEARCH_IMAGE}" --format '{{.Id}}' >/dev/null 2>&1; then
  echo "Pulling ${OPENSEARCH_IMAGE}..."
  $DOCKER pull "${OPENSEARCH_IMAGE}"
fi

$DOCKER rm -f opensearch-ybdb 2>/dev/null || true
echo "Starting OpenSearch ${OPENSEARCH_VERSION}..."
$DOCKER run -d \
  --name opensearch-ybdb \
  --net "container:${DC_ID}" \
  --restart on-failure \
  -e "discovery.type=single-node" \
  -e "DISABLE_SECURITY_PLUGIN=true" \
  -e "OPENSEARCH_JAVA_OPTS=-Xms512m -Xmx512m" \
  "${OPENSEARCH_IMAGE}"

# ── 3. OpenSearch Dashboards ──────────────────────────────────────────────────
DASHBOARDS_IMAGE="opensearchproject/opensearch-dashboards:${OPENSEARCH_VERSION}"
if ! $DOCKER image inspect "${DASHBOARDS_IMAGE}" --format '{{.Id}}' >/dev/null 2>&1; then
  echo "Pulling ${DASHBOARDS_IMAGE}..."
  $DOCKER pull "${DASHBOARDS_IMAGE}"
fi

$DOCKER rm -f opensearch-dashboards-ybdb 2>/dev/null || true
echo "Starting OpenSearch Dashboards ${OPENSEARCH_VERSION}..."
$DOCKER run -d \
  --name opensearch-dashboards-ybdb \
  --net "container:${DC_ID}" \
  --restart on-failure \
  -e "OPENSEARCH_HOSTS=http://localhost:9200" \
  -e "DISABLE_SECURITY_DASHBOARDS_PLUGIN=true" \
  "${DASHBOARDS_IMAGE}"

# ── 4. OTel Collector contrib binary ─────────────────────────────────────────
# Runs as a binary (not a Docker container) so it can read YB log files directly
# from the devcontainer filesystem without bind-mount portability issues.
OTEL_BIN="${OTEL_DIR}/otelcol-contrib"
if [ ! -x "${OTEL_BIN}" ]; then
  echo "Downloading OTel Collector contrib ${OTEL_VERSION}..."
  curl -fsSL \
    "https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${OTEL_VERSION}/otelcol-contrib_${OTEL_VERSION}_linux_amd64.tar.gz" \
    | tar -xzf - -C "${OTEL_DIR}" otelcol-contrib
  chmod +x "${OTEL_BIN}"
fi

# ── 5. Write OTel config ──────────────────────────────────────────────────────
# Paths are resolved to absolute here so the config is portable across restarts.
YB_BASE="${WORKSPACE}/${DATA_PATH}/ybd1"

cat > "${WORK_DIR}/otel-config.yaml" << YAML
receivers:
  filelog/glog:
    include:
      - ${YB_BASE}/logs/master/*.INFO
      - ${YB_BASE}/logs/tserver/*.INFO
    multiline:
      line_start_pattern: '^[IWEF]'
    start_at: beginning
    operators:
      # ── Parse GLog header: SEVERITY MMDD HH:MM:SS.us TID FILE:LINE] MSG ──
      - type: regex_parser
        regex: '^(?P<sev>[IWEF])(?P<mmdd>\d{4}) (?P<hms>\d{2}:\d{2}:\d{2}\.\d+)\s+(?P<tid>\d+)\s+(?P<src_file>[^:]+):(?P<src_line>\d+)\]\s*(?P<msg>[\s\S]*)'
        on_error: send_quiet
      - type: severity_parser
        parse_from: attributes.sev
        mapping:
          info: I
          warn: W
          error: E
          fatal: F
        on_error: send_quiet
      - type: move
        from: attributes.tid
        to: attributes["log.thread_id"]
        on_error: send_quiet
      - type: move
        from: attributes.src_file
        to: attributes["log.source.file"]
        on_error: send_quiet
      - type: move
        from: attributes.src_line
        to: attributes["log.source.line"]
        on_error: send_quiet
      - type: move
        from: attributes.msg
        to: body
        on_error: send_quiet
      - type: remove
        field: attributes.sev
        on_error: send_quiet
      - type: remove
        field: attributes.mmdd
        on_error: send_quiet
      - type: remove
        field: attributes.hms
        on_error: send_quiet
      # ── Best-effort YugabyteDB field extraction from message body ──────────
      - type: regex_parser
        regex: '\bT\s+(?P<yb_tablet_id>[0-9a-f]{32})(?:\s+P\s+(?P<yb_peer_id>[0-9a-f]{32}))?'
        parse_from: body
        on_error: send_quiet
      - type: regex_parser
        regex: '(?:tablet[_ ](?:id[=: ]+)?)(?P<yb_tablet_id>[0-9a-f]{32})'
        parse_from: body
        on_error: send_quiet
      - type: regex_parser
        regex: '\btable(?:[_ ]id)?[=: "]+(?P<yb_table_id>[0-9a-f]{32})'
        parse_from: body
        on_error: send_quiet
      - type: regex_parser
        regex: "[Tt]able[_ ]?(?:name[=: ]*)?[\"'](?P<yb_table_name>[^\"']+)[\"']"
        parse_from: body
        on_error: send_quiet
      # ── Node identity from log file path (multi-node aware) ────────────────
      # Path: .../ybdb/ybd<N>/logs/<component>/...  →  yb.node=N, yb.component=master|tserver
      - type: regex_parser
        regex: 'ybd(?P<yb_node>\d+)/logs/(?P<yb_component>master|tserver)'
        parse_from: attributes["log.file.path"]
        on_error: send_quiet
      - type: move
        from: attributes.yb_node
        to: resource["yb.node"]
        on_error: send_quiet
      - type: move
        from: attributes.yb_component
        to: resource["yb.component"]
        on_error: send_quiet
      - type: move
        from: attributes["log.file.path"]
        to: resource["yb.source"]

  filelog/pg:
    include:
      - ${YB_BASE}/logs/tserver/postgresql-*.log
    multiline:
      line_start_pattern: '^\d{4}-\d{2}-\d{2}'
    start_at: beginning
    operators:
      # ── Parse PG log header: TIMESTAMP [PID] user@db LEVEL:  MSG ──────────
      - type: regex_parser
        regex: '^(?P<pg_ts>\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+ \w+) \[(?P<pg_pid>\d+)\](?:\s+(?P<pg_user>[^@\s]+)@(?P<pg_db>\S+))?\s+(?P<pg_level>\w+):\s+(?P<pg_msg>[\s\S]*)'
        on_error: send_quiet
      - type: time_parser
        parse_from: attributes.pg_ts
        layout: '%Y-%m-%d %H:%M:%S.%f %Z'
        on_error: send_quiet
      - type: severity_parser
        parse_from: attributes.pg_level
        mapping:
          debug: DEBUG
          info: INFO
          notice: INFO
          log: INFO
          warning: WARN
          error: ERROR
          fatal: FATAL
          panic: FATAL
        on_error: send_quiet
      - type: move
        from: attributes.pg_pid
        to: attributes["db.session.id"]
        on_error: send_quiet
      - type: move
        from: attributes.pg_user
        to: attributes["db.user"]
        on_error: send_quiet
      - type: move
        from: attributes.pg_db
        to: attributes["db.name"]
        on_error: send_quiet
      - type: move
        from: attributes.pg_msg
        to: body
        on_error: send_quiet
      - type: remove
        field: attributes.pg_ts
        on_error: send_quiet
      - type: remove
        field: attributes.pg_level
        on_error: send_quiet
      # ── Best-effort: pgaudit, statement, connection extraction ────────────
      - type: regex_parser
        regex: 'AUDIT:\s+(?P<audit_type>SESSION|OBJECT),\d+,\d+,(?P<audit_class>[^,]+),(?P<audit_cmd>[^,]+),(?P<audit_obj_type>[^,]*),(?P<audit_obj>[^,"]*)'
        parse_from: body
        on_error: send_quiet
      - type: regex_parser
        regex: '^(?:statement|execute [^:]+):\s+(?P<db_statement>.{1,500})'
        parse_from: body
        on_error: send_quiet
      - type: regex_parser
        regex: 'connection (?P<conn_action>received|authorized).*?host=(?P<conn_host>\S+)'
        parse_from: body
        on_error: send_quiet
      # ── Node identity from log file path (multi-node aware) ────────────────
      - type: regex_parser
        regex: 'ybd(?P<yb_node>\d+)/logs/'
        parse_from: attributes["log.file.path"]
        on_error: send_quiet
      - type: move
        from: attributes.yb_node
        to: resource["yb.node"]
        on_error: send_quiet
      - type: add
        field: resource["yb.component"]
        value: "tserver"
      - type: move
        from: attributes["log.file.path"]
        to: resource["yb.source"]

processors:
  batch/logs:
    timeout: 10s

exporters:
  opensearch:
    http:
      endpoint: http://localhost:9200
    logs_index: yb-logs

service:
  pipelines:
    logs:
      receivers: [filelog/glog, filelog/pg]
      processors: [batch/logs]
      exporters: [opensearch]
YAML

# ── 6. Kill any previous OTel collector ───────────────────────────────────────
if [ -f "${WORK_DIR}/otelcol.pid" ]; then
  old_pid=$(cat "${WORK_DIR}/otelcol.pid" 2>/dev/null || true)
  [ -n "${old_pid}" ] && kill "${old_pid}" 2>/dev/null || true
fi

# ── 7. Wait for OpenSearch ────────────────────────────────────────────────────
echo "⏳ Waiting for OpenSearch on :9200..."
_ready=0
for i in $(seq 1 40); do
  if curl -sf "http://127.0.0.1:9200/_cluster/health" >/dev/null 2>&1; then
    _ready=1; break
  fi
  sleep 5
done
[ "$_ready" -eq 0 ] && { echo "❌ OpenSearch did not start in time"; exit 1; }
echo "✅ OpenSearch ready"

# ── 8. Start OTel Collector ───────────────────────────────────────────────────
echo "Starting OTel Collector contrib ${OTEL_VERSION}..."
nohup "${OTEL_BIN}" --config "${WORK_DIR}/otel-config.yaml" \
  > "${WORK_DIR}/otelcol.log" 2>&1 &
echo $! > "${WORK_DIR}/otelcol.pid"
sleep 2
if ! kill -0 "$(cat "${WORK_DIR}/otelcol.pid")" 2>/dev/null; then
  echo "❌ OTel Collector failed to start. Last lines:"
  tail -10 "${WORK_DIR}/otelcol.log"
  exit 1
fi
echo "✅ OTel Collector running (pid $(cat "${WORK_DIR}/otelcol.pid"))"

# ── 9. Wait for Dashboards ────────────────────────────────────────────────────
echo "⏳ Waiting for OpenSearch Dashboards on :5601..."
_ready=0
for i in $(seq 1 40); do
  if curl -sf "http://127.0.0.1:5601/api/status" >/dev/null 2>&1; then
    _ready=1; break
  fi
  sleep 5
done
[ "$_ready" -eq 0 ] && echo "⚠  Dashboards not yet ready — it may still be starting"

echo ""
echo "✅ OpenSearch ${OPENSEARCH_VERSION} is ready"
echo "   OpenSearch API:     http://localhost:9200"
echo "   OpenSearch Dashboards: http://localhost:5601"
echo "   OTel log:           ${WORK_DIR}/otelcol.log"
echo "   Index:              yb-logs  (logs)"
