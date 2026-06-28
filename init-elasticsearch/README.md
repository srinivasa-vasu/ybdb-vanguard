# Elasticsearch — Logs & Metrics Observability with YugabyteDB

YugabyteDB emits structured GLog files from each master and tserver process, plus a PostgreSQL-compatible YSQL activity log and Prometheus metrics from four HTTP endpoints. This exercise ships those logs **and** metrics into **Elasticsearch** using the **OpenTelemetry Collector contrib** binary as the single pipeline, then visualises everything in **Kibana** — without modifying YugabyteDB or writing a single line of custom exporter code.

---

## What you'll learn

- How YugabyteDB structured logs (GLog multiline format) are captured with the OTel `filelog` receiver
- How the OTel `prometheus` receiver scrapes YugabyteDB metrics endpoints and ships them as OTLP metrics
- How the `elasticsearch` exporter sends logs to a regular index
- How the `elasticsearch/metrics` exporter stores Prometheus metrics in a plain `yb-metrics` index via `mapping.mode: none`
- How to explore logs and metrics side-by-side in Kibana using data views
- Why `mapping.mode: otel` requires Elastic's OTel integration package and why `mode: none` is the practical choice for a bare ES install

---

## Setup overview

```
┌──────────────────────────────────────────────────────────────────────────┐
│  devcontainer                                                            │
│                                                                          │
│  ┌─────────────────┐   GLog + PG logs (filelog receivers)                │
│  │  YugabyteDB     │ ──────────────────────────────────────►             │
│  │                 │   Prometheus metrics (prometheus receiver)          │
│  │  master  :7000  │ ──────────────────────────────────────►             │
│  │  tserver :9000  │   ┌───────────────────────────────────────┐         │
│  │  ysql    :13000 │   │  OTel Collector contrib (binary)      │         │
│  │  ycql    :12000 │   │  filelog/glog  → elasticsearch        │         │
│  │  ysql    :5433  │   │  filelog/pg    → elasticsearch        │         │
│  └─────────────────┘   │  prometheus    → elasticsearch/metrics│         │
│                        └──────────────┬────────────────────────┘         │
│                                       │ HTTP :9200                       │
│  ┌────────────────────────────────────▼─────────────────────────────┐    │
│  │  Elasticsearch 8.17 (Docker, --net container:DC)  :9200          │    │
│  │    index:       yb-logs       (structured log records)           │    │
│  │    index:       yb-metrics    (Prometheus metrics, plain index)  │    │
│  └──────────────────────────────────────────────────────────────────┘    │
│                                                                          │
│  ┌───────────────────────────────────────────────────────────────────┐   │
│  │  Kibana 8.17 (Docker)                             :5601           │   │
│  └───────────────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────────────┘
```

| Component | Address | Notes |
|-----------|---------|-------|
| Elasticsearch API | http://localhost:9200 | Security disabled for dev |
| Kibana | http://localhost:5601 | XPACK Fleet and telemetry disabled |
| YugabyteDB YSQL | `127.0.0.1:5433` | `yugabyte` / (no password) |
| YugabyteDB Master UI | http://localhost:7000 | Admin UI, tablet map |
| YugabyteDB TServer UI | http://localhost:9000 | Admin UI, tablet details |
| YB log dir | `/workspaces/<repo>/ybdb/ybd1/logs/` | `master/` and `tserver/` subdirs |
| OTel log | `/tmp/elasticsearch-init/otelcol.log` | Config at `/tmp/elasticsearch-init/otel-config.yaml` |

The startup script (`start-elasticsearch.sh`) handles:
1. Starting a single-node YugabyteDB cluster
2. Starting the Elasticsearch container with `--net container:<dc-id>`
3. Starting the Kibana container with the same network namespace
4. Downloading the OTel Collector contrib binary (cached in `/tmp/elasticsearch-init/otel/`)
5. Writing the OTel config with resolved absolute log paths and all four Prometheus targets
6. Killing any stale OTel process; waiting for Elasticsearch on `:9200`
7. Pre-creating `yb-logs` and `yb-metrics` indices with a 5000-field mapping limit
8. Starting the OTel Collector as a background process
9. Waiting for Kibana on `:5601`

---

## Workshop

> **Note:** The `elasticsearch-demo` terminal auto-runs the guided demo script. Use `elasticsearch-ws` for all manual workshop steps below. Both terminals open in `init-elasticsearch/`.

### Step 1: Verify Elasticsearch is healthy

In the `elasticsearch-ws` terminal:

```bash
# Cluster health — status should be "green" or "yellow" (single node)
curl -s 'http://localhost:9200/_cluster/health?pretty' \
  | grep -E '"status"|"number_of_nodes"'

# List all indices and data streams
curl -s 'http://localhost:9200/_cat/indices?v'
curl -s 'http://localhost:9200/_data_stream?pretty'
```

### Step 2: Generate YugabyteDB activity

```bash
# Create a table with 3 tablets and insert rows
ysqlsh -h 127.0.0.1 -c "
  CREATE TABLE IF NOT EXISTS orders (
    id     SERIAL PRIMARY KEY,
    item   TEXT NOT NULL,
    qty    INT  NOT NULL,
    placed TIMESTAMPTZ DEFAULT now()
  ) SPLIT INTO 3 TABLETS;"

ysqlsh -h 127.0.0.1 -c "
  INSERT INTO orders (item, qty)
  SELECT md5(i::text), (random()*10+1)::int
  FROM generate_series(1,500) i;"

ysqlsh -h 127.0.0.1 -c "SELECT count(*), sum(qty) FROM orders;"
```

### Step 3: Check that logs are flowing

The OTel `filelog` receiver reads YB log files and batches them every 10 s. Poll until the index is created:

```bash
until curl -sf 'http://localhost:9200/yb-logs/_count' >/dev/null 2>&1; do echo 'waiting...'; sleep 5; done && echo 'yb-logs index ready'
curl -s 'http://localhost:9200/yb-logs/_count?pretty'
```

Fetch the most recent log entry:

```bash
curl -s 'http://localhost:9200/yb-logs/_search?pretty' \
  -H 'Content-Type: application/json' \
  -d '{
    "size": 1,
    "sort": [{"@timestamp": {"order": "desc"}}]
  }' \
  | python3 -c \
  'import sys,json; r=json.load(sys.stdin); h=r.get("hits",{}).get("hits",[]); print(json.dumps(h[0]["_source"],indent=2)) if h else print("no docs yet")'
```

### Step 4: Check that metrics are flowing

Metrics land in the `yb-metrics` index. The prometheus receiver scrapes every 15 s; the batch processor flushes every 15 s, so allow up to 30 s after startup:

```bash
until curl -sf 'http://localhost:9200/yb-metrics/_count' >/dev/null 2>&1; do echo 'waiting for metrics...'; sleep 5; done && echo 'metrics ready'
curl -s 'http://localhost:9200/yb-metrics/_count?pretty'
```

Fetch a sample metric document:

```bash
curl -s 'http://localhost:9200/yb-metrics/_search?pretty' \
  -H 'Content-Type: application/json' \
  -d '{
    "size": 1,
    "sort": [{"@timestamp": {"order": "desc"}}]
  }' \
  | python3 -c \
  'import sys,json; r=json.load(sys.stdin); h=r.get("hits",{}).get("hits",[]); print(json.dumps(h[0]["_source"],indent=2)) if h else print("no docs yet")'
```

### Step 5: Search logs by severity

GLog severity is captured in the `log.level` field (mapped from the first character: `I`→INFO, `W`→WARNING, `E`→ERROR, `F`→FATAL):

```bash
# Count log entries by level
curl -s 'http://localhost:9200/yb-logs/_search?pretty' \
  -H 'Content-Type: application/json' \
  -d '{
    "size": 0,
    "aggs": {
      "by_level": {
        "terms": { "field": "log.level", "size": 10 }
      }
    }
  }' | python3 -c \
  'import sys,json; [print(b["key"],b["doc_count"]) for b in json.load(sys.stdin)["aggregations"]["by_level"]["buckets"]]'
```

```bash
# Find recent WARNING entries
curl -s 'http://localhost:9200/yb-logs/_search?pretty' \
  -H 'Content-Type: application/json' \
  -d '{
    "size": 5,
    "query": { "term": { "log.level": "warn" } },
    "sort": [{"@timestamp": {"order": "desc"}}],
    "_source": ["@timestamp","log.level","body","resource.yb.source"]
  }'
```

### Step 6: Explore in Kibana

1. Open **http://localhost:5601** in your browser (or use the port-forwarded URL from the Ports panel)
2. Go to **Discover** (hamburger menu → Analytics → Discover)
3. Click **Create data view** → name `YB Logs`, index pattern `yb-logs*`, time field `@timestamp` → **Save**
4. Browse the log stream; use the search bar to filter (e.g. `log.level: warn`, `resource.yb.component: master`)
5. Create a second data view: name `YB Metrics`, index pattern `yb-metrics`, time field `@timestamp`
6. Switch to the metrics data view to explore Prometheus metric time series

### Step 7: Inspect the OTel pipeline

```bash
# Live OTel collector output — Ctrl-C to stop
tail -f /tmp/elasticsearch-init/otelcol.log

# Review the generated config (paths resolved at startup)
cat /tmp/elasticsearch-init/otel-config.yaml

# Collector process info
ps aux | grep otelcol-contrib | grep -v grep
```

### Step 8: Trigger more activity

```bash
# Run an EXPLAIN ANALYZE to generate query planning logs
ysqlsh -h 127.0.0.1 -c "
  EXPLAIN ANALYZE SELECT count(*), avg(qty)
  FROM orders
  WHERE placed > now() - interval '1 hour';"

# DDL changes produce tserver + master log entries
ysqlsh -h 127.0.0.1 -c "
  ALTER TABLE orders ADD COLUMN shipped BOOL DEFAULT false;
  CREATE INDEX CONCURRENTLY ON orders (placed);"

# After ~15s flush cycle, counts should increase
sleep 20
curl -s 'http://localhost:9200/yb-logs/_count?pretty'
curl -s 'http://localhost:9200/yb-metrics/_count?pretty'
```

---

## Key concepts

| Concept | Detail |
|---------|--------|
| **GLog multiline format** | YB log lines start with `I`/`W`/`E`/`F` followed by date/time; the OTel `filelog` receiver uses `line_start_pattern: '^[IWEF]'` to reassemble multiline stack traces |
| **OTel as binary (not Docker)** | Running OTel as a devcontainer binary process means it can read log files directly from the devcontainer filesystem — no bind-mount or DooD complexity |
| **elasticsearch exporter** | Sends logs to the `yb-logs` regular index; `endpoints` takes a list unlike the OpenSearch exporter's `http.endpoint` scalar |
| **elasticsearch/metrics exporter** | Writes Prometheus metrics to the `yb-metrics` plain index; `mapping.mode: none` disables data-stream routing and ECS schema enforcement, making it work on a bare ES 8.x without any integration packages |
| **mapping.mode: none** | Skips all OTel/ECS schema enforcement; documents are serialised as-is. `mapping.mode: otel` (the v0.155.0 default) requires Elastic's OTel integration component templates which are not present in a stock ES install — without them, every document gets a `document_parsing_exception` 400 |
| **Pre-created indices** | `yb-logs` and `yb-metrics` are created at startup with `total_fields.limit: 5000`; YugabyteDB's Prometheus endpoint exports hundreds of metric names × label combinations, easily exceeding ES's default 1000-field cap |
| **Security disabled** | `xpack.security.enabled=false` (and the two SSL flags) simplifies the dev setup; Kibana connects via plain HTTP with no enrollment token |
| **Shared network namespace** | Elasticsearch and Kibana containers run with `--net container:<dc-id>` so all components communicate on `localhost` without extra port mapping |
| **Why not OpenSearch for metrics?** | OpenSearch forked from ES 7.10 and lacks the ES data-stream APIs and OTel integration package that the `elasticsearch/metrics` exporter targets |
