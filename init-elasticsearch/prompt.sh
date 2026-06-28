#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Elasticsearch — Logs & Metrics Observability with YugabyteDB
#
# Filebeat reads YugabyteDB GLog files (master, tserver) and PostgreSQL/
# pgaudit logs → ships to the yb-logs index in Elasticsearch.
# Metricbeat scrapes four YB Prometheus endpoints → ships to yb-metrics.
# Kibana visualizes both indices.
# ─────────────────────────────────────────────────────────────────────────────

. pscript

TYPE_SPEED=70
HOST="127.0.0.1"
ES_URL="http://localhost:9200"
KIBANA_URL="http://localhost:5601"

# ── Wait for Elasticsearch and Kibana before starting the demo ───────────────
bash ../.devcontainer/scripts/wait-for-svc.sh \
  'http://localhost:9200/_cluster/health' 'Elasticsearch :9200' \
  'http://localhost:5601/api/status'      'Kibana :5601'

clear

pe "# Elasticsearch — Logs & Metrics Observability with YugabyteDB"
pe "# ─────────────────────────────────────────────────────────────"
p  ""
pe "# Four components are running:"
pe "#   elasticsearch  :9200  — index store"
pe "#   kibana         :5601  — visualization"
pe "#   filebeat              — GLog + pgaudit log shipper → yb-logs"
pe "#   metricbeat            — Prometheus metrics shipper → yb-metrics"
p  ""

pe "# ── Confirm Elasticsearch is healthy ─────────────────────────────────────"
pe "curl -s '${ES_URL}/_cluster/health?pretty' | grep -E '\"status\"|\"number_of_nodes\"'"
p  ""

pe "# ── Generate some YugabyteDB activity ────────────────────────────────────"
pe "ysqlsh -h ${HOST} -c \"CREATE TABLE IF NOT EXISTS orders (id SERIAL PRIMARY KEY, item TEXT NOT NULL, qty INT NOT NULL, placed TIMESTAMPTZ DEFAULT now()) SPLIT INTO 3 TABLETS;\""
p  ""
pe "ysqlsh -h ${HOST} -c \"INSERT INTO orders (item, qty) SELECT md5(i::text), (random()*10+1)::int FROM generate_series(1,500) i;\""
p  ""
pe "ysqlsh -h ${HOST} -c \"SELECT count(*), sum(qty) FROM orders;\""
p  ""

pe "# ── Wait for Filebeat to flush logs into Elasticsearch ─────────────────────"
pe "until curl -sf '${ES_URL}/yb-logs/_count' >/dev/null 2>&1; do echo 'waiting for Filebeat...'; sleep 5; done && echo 'yb-logs index ready'"
pe "curl -s '${ES_URL}/yb-logs/_count?pretty'"
p  ""

pe "# ── Wait for Metricbeat to flush metrics into Elasticsearch ─────────────────"
pe "until curl -sf '${ES_URL}/yb-metrics/_count' >/dev/null 2>&1; do echo 'waiting for Metricbeat...'; sleep 5; done && echo 'yb-metrics index ready'"
pe "curl -s '${ES_URL}/yb-metrics/_count?pretty'"
p  ""

pe "# ── Sample a log entry ───────────────────────────────────────────────────"
pe "curl -s '${ES_URL}/yb-logs/_search?pretty' -H 'Content-Type: application/json' -d '{\"size\":1,\"sort\":[{\"@timestamp\":{\"order\":\"desc\"}}]}' | python3 -c 'import sys,json; r=json.load(sys.stdin); h=r.get(\"hits\",{}).get(\"hits\",[]); print(json.dumps(h[0][\"_source\"],indent=2)) if h else print(\"no docs yet\")'"
p  ""

pe "# ── Open Kibana ──────────────────────────────────────────────────────────"
pe "# Navigate to ${KIBANA_URL}"
pe "# Discover → Create data view: yb-logs    (GLog + pgaudit logs)"
pe "# Discover → Create data view: yb-metrics (Prometheus metrics)"
p  ""
pe "echo 'Kibana: ${KIBANA_URL}'"
p  ""

pe "# ── Check Filebeat and Metricbeat status ─────────────────────────────────"
pe "tail -5 /tmp/elasticsearch-init/filebeat.log"
pe "tail -5 /tmp/elasticsearch-init/metricbeat.log"
