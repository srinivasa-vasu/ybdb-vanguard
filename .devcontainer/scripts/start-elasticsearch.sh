#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# start-elasticsearch.sh  —  Elasticsearch + Beats observability exercise
#
# Architecture:
#   elasticsearch  Docker container  :9200  (index store)
#   kibana         Docker container  :5601  (visualization)
#   filebeat       Docker container         (log shipper: GLog + pgaudit)
#   metricbeat     Docker container         (metrics shipper: Prometheus)
#
# Pipeline:
#   filebeat   ← YB master/tserver GLog files  →  yb-logs   index (ES)
#              ← YB PostgreSQL / pgaudit logs
#   metricbeat ← YB Prometheus :7000/:9000/:13000/:12000  →  yb-metrics  index (ES)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

sudo chmod 666 /var/run/docker.sock 2>/dev/null || true

ELASTICSEARCH_VERSION="${ELASTICSEARCH_VERSION:-8.17.0}"
WORK_DIR="/tmp/elasticsearch-init"
WORKSPACE="${PWD}"
DATA_PATH="${DATA_PATH:-ybdb}"

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

# ── 2. Elasticsearch ──────────────────────────────────────────────────────────
ES_IMAGE="docker.elastic.co/elasticsearch/elasticsearch:${ELASTICSEARCH_VERSION}"
if ! $DOCKER image inspect "${ES_IMAGE}" --format '{{.Id}}' >/dev/null 2>&1; then
  echo "Pulling ${ES_IMAGE}..."
  $DOCKER pull "${ES_IMAGE}"
fi

# ES 8.x bootstrap check: requires vm.max_map_count >= 262144
sudo sysctl -w vm.max_map_count=262144 2>/dev/null || true

$DOCKER rm -f elasticsearch-ybdb 2>/dev/null || true
$DOCKER volume rm elasticsearch-ybdb-data 2>/dev/null || true
echo "Starting Elasticsearch ${ELASTICSEARCH_VERSION}..."
$DOCKER run -d \
  --name elasticsearch-ybdb \
  --net "container:${DC_ID}" \
  --restart on-failure \
  -v elasticsearch-ybdb-data:/usr/share/elasticsearch/data \
  -e "discovery.type=single-node" \
  -e "xpack.security.enabled=false" \
  -e "xpack.security.http.ssl.enabled=false" \
  -e "xpack.security.transport.ssl.enabled=false" \
  -e "ES_JAVA_OPTS=-Xms1g -Xmx1g" \
  --ulimit nofile=65536:65536 \
  "${ES_IMAGE}"

# ── 3. Kibana ─────────────────────────────────────────────────────────────────
KIBANA_IMAGE="docker.elastic.co/kibana/kibana:${ELASTICSEARCH_VERSION}"
if ! $DOCKER image inspect "${KIBANA_IMAGE}" --format '{{.Id}}' >/dev/null 2>&1; then
  echo "Pulling ${KIBANA_IMAGE}..."
  $DOCKER pull "${KIBANA_IMAGE}"
fi

$DOCKER rm -f kibana-ybdb 2>/dev/null || true
echo "Starting Kibana ${ELASTICSEARCH_VERSION}..."
$DOCKER run -d \
  --name kibana-ybdb \
  --net "container:${DC_ID}" \
  --restart on-failure \
  -e "ELASTICSEARCH_HOSTS=http://localhost:9200" \
  -e "XPACK_FLEET_ENABLED=false" \
  -e "XPACK_SECURITY_ENABLED=false" \
  -e "TELEMETRY_ENABLED=false" \
  "${KIBANA_IMAGE}"

# ── 4. Wait for Elasticsearch ─────────────────────────────────────────────────
echo "⏳ Waiting for Elasticsearch on :9200..."
_ready=0
for i in $(seq 1 40); do
  if curl -sf "http://127.0.0.1:9200/_cluster/health" >/dev/null 2>&1; then
    _ready=1; break
  fi
  sleep 5
done
[ "$_ready" -eq 0 ] && { echo "❌ Elasticsearch did not start in time"; exit 1; }
echo "✅ Elasticsearch ready"

# ── 5. Pre-create indices ─────────────────────────────────────────────────────
# Index template as safety net — applies settings to any yb-* auto-creation.
_tmpl_code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT "http://localhost:9200/_index_template/yb-template" \
  -H "Content-Type: application/json" \
  -d '{"index_patterns":["yb-*"],"template":{"settings":{"number_of_shards":1,"number_of_replicas":0,"index.mapping.total_fields.limit":5000}}}')
echo "  index template yb-* → HTTP ${_tmpl_code}"

for idx in yb-logs yb-metrics; do
  _idx_ready=0
  for _attempt in $(seq 1 10); do
    _code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT "http://localhost:9200/${idx}" \
      -H "Content-Type: application/json" \
      -d '{"settings":{"number_of_shards":1,"number_of_replicas":0,"index.mapping.total_fields.limit":5000}}')
    # 200=created, 400=already exists — both are fine
    if [ "${_code}" = "200" ] || [ "${_code}" = "400" ]; then
      _idx_ready=1; break
    fi
    echo "  attempt ${_attempt}: ${idx} → HTTP ${_code}, retrying..."
    sleep 3
  done
  if [ "${_idx_ready}" -eq 1 ]; then
    echo "✅ index ${idx} ready"
  else
    echo "❌ index ${idx} failed to create after 10 attempts — check ES logs"
    exit 1
  fi
done

# ── 5b. Log-enrichment ingest pipeline ───────────────────────────────────────
cat > "${WORK_DIR}/yb-logs-pipeline.json" << 'JSON'
{
  "description": "YugabyteDB log enrichment — GLog/PG headers, node/tablet/table/connection fields",
  "processors": [
    {
      "grok": {
        "tag": "log-header",
        "field": "message",
        "patterns": [
          "^(?<yb_log_level>[IWEF])\\d{4}\\s+\\d{2}:\\d{2}:\\d{2}\\.\\d+\\s+(?<process_pid>\\d+)\\s+(?<log_source>[^\\]]+)]\\s+(?<message>[\\s\\S]*)",
          "^\\d{4}-\\d{2}-\\d{2}\\s+\\d{2}:\\d{2}:\\d{2}\\.\\d+\\s+\\S+\\s+\\[(?<process_pid>\\d+)\\]\\s+(?<db_user>\\S+)@(?<db_name>\\S+)\\s+(?<pg_log_level>\\w+):\\s+(?<message>[\\s\\S]*)",
          "^\\d{4}-\\d{2}-\\d{2}\\s+\\d{2}:\\d{2}:\\d{2}\\.\\d+\\s+\\S+\\s+\\[(?<process_pid>\\d+)\\]\\s+(?<pg_log_level>\\w+):\\s+(?<message>[\\s\\S]*)"
        ],
        "ignore_failure": true
      }
    },
    {
      "grok": {
        "tag": "yb-tablet-context",
        "field": "message",
        "patterns": ["\\bT\\s+(?<yb_tablet_id>[0-9a-f]{32})(?:\\s+P\\s+(?<yb_peer_id>[0-9a-f]{32}))?"],
        "ignore_missing": true,
        "ignore_failure": true
      }
    },
    {
      "grok": {
        "tag": "yb-tablet-ref",
        "field": "message",
        "patterns": ["tablet[_ ](?:id[=: \"]+)?(?<yb_tablet_id>[0-9a-f]{32})"],
        "ignore_missing": true,
        "ignore_failure": true
      }
    },
    {
      "grok": {
        "tag": "yb-table-id",
        "field": "message",
        "patterns": ["\\btable(?:[_ ]id)?[=: \"]+(?<yb_table_id>[0-9a-f]{32})"],
        "ignore_missing": true,
        "ignore_failure": true
      }
    },
    {
      "grok": {
        "tag": "yb-table-name",
        "field": "message",
        "patterns": ["[Tt]able[_ ]?(?:name[=: ]*)?[\"'](?<yb_table_name>[^\"']+)[\"']"],
        "ignore_missing": true,
        "ignore_failure": true
      }
    },
    {
      "grok": {
        "tag": "pgaudit",
        "field": "message",
        "patterns": ["AUDIT:\\s+(?<pgaudit_type>SESSION|OBJECT),\\d+,\\d+,(?<pgaudit_class>[^,]+),(?<pgaudit_command>[^,]+),(?<pgaudit_obj_type>[^,]*),(?<pgaudit_object>[^,\"]*)"],
        "ignore_missing": true,
        "ignore_failure": true
      }
    },
    {
      "grok": {
        "tag": "pg-statement",
        "field": "message",
        "patterns": ["^(?:statement|execute [^:]+):\\s+(?<db_statement>[\\s\\S]+)"],
        "ignore_missing": true,
        "ignore_failure": true
      }
    },
    {
      "grok": {
        "tag": "pg-connection",
        "field": "message",
        "patterns": ["connection (?<conn_action>received|authorized).*?host=(?<conn_host>\\S+)"],
        "ignore_missing": true,
        "ignore_failure": true
      }
    },
    {
      "grok": {
        "tag": "yb-node-component",
        "field": "log.file.path",
        "patterns": ["ybd(?<yb_node>\\d+)/logs/(?<yb_component>master|tserver)"],
        "ignore_missing": true,
        "ignore_failure": true
      }
    },
    {
      "rename": {
        "tag": "yb-source",
        "field": "log.file.path",
        "target_field": "yb_source",
        "ignore_missing": true
      }
    }
  ]
}
JSON

_pipe_code=$(curl -s -o /dev/null -w "%{http_code}" -X PUT "http://localhost:9200/_ingest/pipeline/yb-logs-pipeline" \
  -H "Content-Type: application/json" \
  --data-binary "@${WORK_DIR}/yb-logs-pipeline.json")
echo "  ingest pipeline yb-logs-pipeline → HTTP ${_pipe_code}"

# ── 6. Download Filebeat + Metricbeat binaries ────────────────────────────────
# Run as binaries (not Docker containers) so they can read devcontainer
# log files and reach localhost ports without Docker volume mount issues.
BEATS_DIR="${WORK_DIR}/beats"
mkdir -p "${BEATS_DIR}"

case "$(uname -m)" in
  x86_64)          _BEATS_ARCH="linux-x86_64" ;;
  aarch64|arm64)   _BEATS_ARCH="linux-arm64" ;;
  *) echo "❌ Unsupported architecture: $(uname -m)"; exit 1 ;;
esac
echo "Beats architecture: ${_BEATS_ARCH}"

FILEBEAT_BIN="${BEATS_DIR}/filebeat"
if [ ! -x "${FILEBEAT_BIN}" ]; then
  echo "Downloading Filebeat ${ELASTICSEARCH_VERSION}..."
  curl -fsSL \
    "https://artifacts.elastic.co/downloads/beats/filebeat/filebeat-${ELASTICSEARCH_VERSION}-${_BEATS_ARCH}.tar.gz" \
    | tar -xzf - -C "${BEATS_DIR}" --strip-components=1 \
      "filebeat-${ELASTICSEARCH_VERSION}-${_BEATS_ARCH}/filebeat"
  chmod +x "${FILEBEAT_BIN}"
fi

METRICBEAT_BIN="${BEATS_DIR}/metricbeat"
if [ ! -x "${METRICBEAT_BIN}" ]; then
  echo "Downloading Metricbeat ${ELASTICSEARCH_VERSION}..."
  curl -fsSL \
    "https://artifacts.elastic.co/downloads/beats/metricbeat/metricbeat-${ELASTICSEARCH_VERSION}-${_BEATS_ARCH}.tar.gz" \
    | tar -xzf - -C "${BEATS_DIR}" --strip-components=1 \
      "metricbeat-${ELASTICSEARCH_VERSION}-${_BEATS_ARCH}/metricbeat"
  chmod +x "${METRICBEAT_BIN}"
fi

# ── 7. Filebeat config + start ────────────────────────────────────────────────
YB_LOG_PATH="${WORKSPACE}/${DATA_PATH}/ybd1/logs"

cat > "${WORK_DIR}/filebeat.yml" << YAML
filebeat.inputs:
  - type: filestream
    id: yb-glog
    enabled: true
    paths:
      - ${YB_LOG_PATH}/master/*.INFO
      - ${YB_LOG_PATH}/tserver/*.INFO
    parsers:
      - multiline:
          type: pattern
          pattern: '^[IWEF]'
          negate: true
          match: after
    fields:
      log.type: glog
    fields_under_root: true
    prospector.scanner.check_interval: 5s

  - type: filestream
    id: yb-pg
    enabled: true
    paths:
      - ${YB_LOG_PATH}/tserver/postgresql-*.log
    parsers:
      - multiline:
          type: pattern
          pattern: '^\d{4}-\d{2}-\d{2}'
          negate: true
          match: after
    fields:
      log.type: postgres
    fields_under_root: true
    prospector.scanner.check_interval: 5s

output.elasticsearch:
  hosts: ["http://localhost:9200"]
  index: "yb-logs"
  pipeline: "yb-logs-pipeline"

setup.ilm.enabled: false
setup.template.enabled: false

filebeat.config.modules:
  enabled: false

logging.level: warning
logging.to_files: false
YAML

if [ -f "${WORK_DIR}/filebeat.pid" ]; then
  kill "$(cat "${WORK_DIR}/filebeat.pid")" 2>/dev/null || true
fi
echo "Starting Filebeat ${ELASTICSEARCH_VERSION}..."
nohup "${FILEBEAT_BIN}" -e -c "${WORK_DIR}/filebeat.yml" \
  > "${WORK_DIR}/filebeat.log" 2>&1 &
echo $! > "${WORK_DIR}/filebeat.pid"

# ── 8. Metricbeat config + start ─────────────────────────────────────────────
cat > "${WORK_DIR}/metricbeat.yml" << YAML
metricbeat.modules:
  - module: prometheus
    metricsets: ["collector"]
    period: 15s
    hosts:
      - "localhost:7000"
      - "localhost:9000"
      - "localhost:13000"
      - "localhost:12000"
    metrics_path: /prometheus-metrics

output.elasticsearch:
  hosts: ["http://localhost:9200"]
  index: "yb-metrics"

setup.ilm.enabled: false
setup.template.enabled: false

logging.level: warning
logging.to_files: false
YAML

if [ -f "${WORK_DIR}/metricbeat.pid" ]; then
  kill "$(cat "${WORK_DIR}/metricbeat.pid")" 2>/dev/null || true
fi
echo "Starting Metricbeat ${ELASTICSEARCH_VERSION}..."
nohup "${METRICBEAT_BIN}" -e -c "${WORK_DIR}/metricbeat.yml" \
  > "${WORK_DIR}/metricbeat.log" 2>&1 &
echo $! > "${WORK_DIR}/metricbeat.pid"

# ── 10. Wait for Kibana ───────────────────────────────────────────────────────
echo "⏳ Waiting for Kibana on :5601..."
_ready=0
for i in $(seq 1 40); do
  if curl -sf "http://127.0.0.1:5601/api/status" >/dev/null 2>&1; then
    _ready=1; break
  fi
  sleep 5
done
[ "$_ready" -eq 0 ] && echo "⚠  Kibana not yet ready — it may still be starting"

echo ""
echo "✅ Elasticsearch ${ELASTICSEARCH_VERSION} is ready"
echo "   Elasticsearch:  http://localhost:9200"
echo "   Kibana:         http://localhost:5601"
echo "   Filebeat log:   ${WORK_DIR}/filebeat.log"
echo "   Metricbeat log: ${WORK_DIR}/metricbeat.log"
echo "   Index:          yb-logs    (YB GLog + pgaudit logs)"
echo "   Index:          yb-metrics (YB Prometheus metrics)"
