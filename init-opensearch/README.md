# OpenSearch — Log Observability with YugabyteDB

YugabyteDB emits structured GLog files from each master and tserver process, plus a PostgreSQL-compatible YSQL activity log. This exercise ships those logs into **OpenSearch** using the **OpenTelemetry Collector contrib** binary as the pipeline, then visualises them in **OpenSearch Dashboards** — without modifying YugabyteDB or writing a single line of custom exporter code.

---

## What you'll learn

- How YugabyteDB structured logs (GLog multiline format) are captured with the OTel `filelog` receiver
- How the OTel `opensearch` exporter ships logs into an index
- How pgaudit, SQL statements, tablet IDs, and session metadata are extracted as structured fields
- How to search YugabyteDB logs in OpenSearch with simple queries
- How to create index patterns in OpenSearch Dashboards and explore the log stream in real time
- Why the OTel Collector runs as a binary process (not a Docker container) to avoid bind-mount portability issues

---

## Setup overview

```
┌──────────────────────────────────────────────────────────────────────────┐
│  devcontainer                                                            │
│                                                                          │
│  ┌─────────────────┐   GLog + PG logs (filelog receivers)                │
│  │  YugabyteDB     │ ──────────────────────────────────────►             │
│  │                 │                                                     │
│  │  master  :7000  │   ┌──────────────────────────────────────┐          │
│  │  tserver :9000  │   │  OTel Collector contrib              │          │
│  │  ysql    :13000 │   │  (binary process)                    │          │
│  │  ycql    :12000 │   │  filelog/glog → opensearch → yb-logs │          │
│  │  ysql    :5433  │   │  filelog/pg   → opensearch → yb-logs │          │
│  └─────────────────┘   └──────────────────┬───────────────────┘          │
│                                           │ HTTP :9200                   │
│  ┌────────────────────────────────────────▼─────────────────────────┐    │
│  │  OpenSearch 3.7 (Docker, --net container:DC)     :9200           │    │
│  │    index: yb-logs                                                │    │
│  └──────────────────────────────────────────────────────────────────┘    │
│                                                                          │
│  ┌───────────────────────────────────────────────────────────────────┐   │
│  │  OpenSearch Dashboards 3.7 (Docker)              :5601            │   │
│  └───────────────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────────────┘
```

| Component | Address | Notes |
|-----------|---------|-------|
| OpenSearch API | http://localhost:9200 | Security plugin disabled |
| OpenSearch Dashboards | http://localhost:5601 | Security plugin disabled |
| YugabyteDB YSQL | `127.0.0.1:5433` | `yugabyte` / (no password) |
| YugabyteDB Master UI | http://localhost:7000 | Admin UI, tablet map |
| YugabyteDB TServer UI | http://localhost:9000 | Admin UI, tablet details |
| YB log dir | `/workspaces/<repo>/ybdb/ybd1/logs/` | `master/` and `tserver/` subdirs |
| OTel log | `/tmp/opensearch-init/otelcol.log` | Config at `/tmp/opensearch-init/otel-config.yaml` |

The startup script (`start-opensearch.sh`) handles:
1. Starting a single-node YugabyteDB cluster
2. Starting the OpenSearch container with `--net container:<dc-id>`
3. Starting the OpenSearch Dashboards container with the same network
4. Downloading the OTel Collector contrib binary (cached in `/tmp/opensearch-init/otel/`)
5. Writing the OTel config with resolved absolute log paths
6. Waiting for OpenSearch on `:9200`, then starting the OTel Collector as a background process
7. Waiting for Dashboards on `:5601`

---

## Workshop

> **Note:** The `opensearch-demo` terminal auto-runs the guided demo script. Use `opensearch-ws` for all manual workshop steps below. Both terminals open in `init-opensearch/`.

### Step 1: Verify OpenSearch is healthy

In the `opensearch-ws` terminal:

```bash
# Cluster health — status should be "green" or "yellow" (single node)
curl -s 'http://localhost:9200/_cluster/health?pretty' \
  | grep -E '"status"|"number_of_nodes"'

# List all indices
curl -s 'http://localhost:9200/_cat/indices?v'
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

### Step 4: Search logs by severity

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

### Step 5: Explore in OpenSearch Dashboards

1. Open **http://localhost:5601** in your browser (or use the port-forwarded URL from the Ports panel)
2. Go to **Discover** (hamburger menu → OpenSearch Dashboards → Discover)
3. Click **Create index pattern** → enter `yb-logs*` → select `@timestamp` as the time field → **Create**
4. Browse the log stream; use the search bar to filter (e.g. `log.level: warn`, `resource.yb.component: master`)
5. Filter by node with `resource.yb.node: 1` (multi-node clusters)

### Step 6: Inspect the OTel pipeline

```bash
# Live OTel collector output — Ctrl-C to stop
tail -f /tmp/opensearch-init/otelcol.log

# Review the generated config (paths resolved at startup)
cat /tmp/opensearch-init/otel-config.yaml

# Collector process info
ps aux | grep otelcol-contrib | grep -v grep
```

### Step 7: Trigger more activity and watch the log stream

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

# After ~10s batch flush, count should have increased
sleep 15
curl -s 'http://localhost:9200/yb-logs/_count?pretty'
```

---

## Key concepts

| Concept | Detail |
|---------|--------|
| **GLog multiline format** | YB log lines start with `I`/`W`/`E`/`F` followed by date/time; the OTel `filelog` receiver uses `line_start_pattern: '^[IWEF]'` to reassemble multiline stack traces |
| **OTel as binary (not Docker)** | Running OTel as a devcontainer binary process means it can read log files directly from the devcontainer filesystem — no bind-mount or DooD complexity |
| **opensearch exporter** | Native OpenSearch exporter; uses `logs_index: yb-logs` to write logs to a fixed index |
| **Security disabled** | `DISABLE_SECURITY_PLUGIN=true` and `DISABLE_SECURITY_DASHBOARDS_PLUGIN=true` simplify the dev setup; production deployments require TLS + auth |
| **Shared network namespace** | OpenSearch and Dashboards containers run with `--net container:<dc-id>` so all components communicate on `localhost` without extra port mapping |
| **Batch processor** | OTel `batch` processor with `timeout: 10s` accumulates records before flushing — reduces per-document overhead but introduces up to 10 s of latency |
