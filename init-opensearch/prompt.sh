#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# OpenSearch — Log Observability with YugabyteDB
#
# YugabyteDB writes structured GLog files (master, tserver) and PostgreSQL-
# compatible YSQL logs. The OTel Collector contrib binary reads those files
# via a filelog receiver and ships them into OpenSearch for search and visualization.
# ─────────────────────────────────────────────────────────────────────────────

. pscript

TYPE_SPEED=70
HOST="127.0.0.1"
OS_URL="http://localhost:9200"
DASH_URL="http://localhost:5601"

# ── Wait for OpenSearch and Dashboards before starting the demo ──────────────
bash ../.devcontainer/scripts/wait-for-svc.sh \
  'http://localhost:9200/_cluster/health' 'OpenSearch :9200' \
  'http://localhost:5601/api/status'      'OpenSearch Dashboards :5601'

clear

pe "# OpenSearch — Log Observability with YugabyteDB"
pe "# ─────────────────────────────────────────────────────────"
p  ""
pe "# Three components are running:"
pe "#   opensearch               :9200  — index store"
pe "#   opensearch-dashboards    :5601  — visualization"
pe "#   otel-collector-contrib          — log pipeline (binary)"
p  ""

pe "# ── Confirm OpenSearch is healthy ────────────────────────────────────────"
pe "curl -s '${OS_URL}/_cluster/health?pretty' | grep -E '\"status\"|\"number_of_nodes\"'"
p  ""

pe "# ── Generate some YugabyteDB activity ────────────────────────────────────"
pe "ysqlsh -h ${HOST} -c \"CREATE TABLE IF NOT EXISTS orders (id SERIAL PRIMARY KEY, item TEXT NOT NULL, qty INT NOT NULL, placed TIMESTAMPTZ DEFAULT now()) SPLIT INTO 3 TABLETS;\""
p  ""
pe "ysqlsh -h ${HOST} -c \"INSERT INTO orders (item, qty) SELECT md5(i::text), (random()*10+1)::int FROM generate_series(1,500) i;\""
p  ""
pe "ysqlsh -h ${HOST} -c \"SELECT count(*), sum(qty) FROM orders;\""
p  ""

pe "# ── Wait for OTel to flush logs into OpenSearch ─────────────────────────"
pe "until curl -sf '${OS_URL}/yb-logs/_count' >/dev/null 2>&1; do echo 'waiting...'; sleep 5; done && echo 'yb-logs index ready'"
pe "curl -s '${OS_URL}/yb-logs/_count?pretty'"
p  ""

pe "# ── Sample a log entry ───────────────────────────────────────────────────"
pe "curl -s '${OS_URL}/yb-logs/_search?pretty' -H 'Content-Type: application/json' -d '{\"size\":1,\"sort\":[{\"@timestamp\":{\"order\":\"desc\"}}]}' | python3 -c 'import sys,json; r=json.load(sys.stdin); h=r.get(\"hits\",{}).get(\"hits\",[]); print(json.dumps(h[0][\"_source\"],indent=2)) if h else print(\"no docs yet\")'"
p  ""

pe "# ── Open OpenSearch Dashboards ───────────────────────────────────────────"
pe "# Navigate to ${DASH_URL}"
pe "# Discover → create index pattern  yb-logs*"
pe "# Then explore the YugabyteDB log stream in real time"
p  ""
pe "echo 'Dashboards: ${DASH_URL}'"
p  ""

pe "# ── Tail OTel collector output (Ctrl-C to stop) ──────────────────────────"
pe "tail -f /tmp/opensearch-init/otelcol.log"
