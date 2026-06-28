# Kong Gateway — API Gateway with YugabyteDB

Kong Gateway is a cloud-native, platform-agnostic API gateway. It stores its entire configuration (services, routes, plugins, consumers) in a PostgreSQL-compatible database. This exercise wires Kong to **YugabyteDB YSQL** (port 5433) — Kong detects the PostgreSQL wire protocol and connects without modification. Every `POST /services` or `POST /plugins` call you make through the Admin API is immediately durable in a distributed YugabyteDB cluster.

---

## What you'll learn

- Run Kong Gateway with YugabyteDB as its backing config store (zero code changes — PostgreSQL wire protocol)
- How Kong migrations create tables in YugabyteDB on first boot
- How to create and query Kong services, routes, and plugins via the Admin API
- How to read Kong config objects back directly from YugabyteDB using YSQL
- The difference between Kong's Admin API and querying the backing database directly

---

## Setup overview

```
┌──────────────────────────────────────────────────────────────┐
│  devcontainer                                                │
│                                                              │
│  ┌──────────────────────────┐   PostgreSQL / port 5433       │
│  │  Kong Gateway 3.9        │ ─────────────────────────────► │
│  │  (Docker container,      │         ┌──────────────────┐   │
│  │   --net container:DC)    │         │  YugabyteDB      │   │
│  │  proxy:   8000           │         │  database: kong  │   │
│  │  admin:   8001           │         └──────────────────┘   │
│  └──────────────────────────┘                                │
└──────────────────────────────────────────────────────────────┘
```

| Component | Address | Credentials |
|-----------|---------|-------------|
| Kong Admin API | http://localhost:8001 | — (no auth in dev mode) |
| Kong Proxy | http://localhost:8000 | — |
| YugabyteDB YSQL | `127.0.0.1:5433` | `yugabyte` / (no password) |
| Kong DB role | — | `kong` / `kong` |

The startup script (`start-kong.sh`) handles:
1. Starting a single-node YugabyteDB cluster
2. Creating the `kong` role and `kong` database in YugabyteDB
3. Running `kong migrations bootstrap` to create ~60 tables
4. Starting the Kong Gateway container with `--net container:<dc-id>` so it shares the devcontainer loopback
5. Waiting for the Admin API to be ready before opening terminals

---

## Quick-reference: Kong configuration for YugabyteDB

```bash
KONG_DATABASE=postgres          # PostgreSQL dialect (YugabyteDB is PG-compatible)
KONG_PG_HOST=127.0.0.1
KONG_PG_PORT=5433               # YugabyteDB YSQL port
KONG_PG_USER=kong
KONG_PG_PASSWORD=kong
KONG_PG_DATABASE=kong
KONG_PROXY_LISTEN=0.0.0.0:8000
KONG_ADMIN_LISTEN=0.0.0.0:8001
```

No schema changes, no custom driver — Kong's standard PostgreSQL support works as-is.

---

## Workshop

> **Note:** The `kong-demo` terminal auto-starts Kong's demo script when ready. Use `kong-ws` for all manual workshop steps below. Both terminals open in `init-kong/`.

### Step 1: Verify Kong is running

In the `kong-ws` terminal:

```bash
# Kong node info + database backend
curl -s http://localhost:8001/ | jq '{version: .version, database: .configuration.database, pg_port: .configuration.pg_port}'

# Kong is healthy when "status": "ready"
curl -s http://localhost:8001/status | jq .server
```

### Step 2: Explore the schema Kong created in YugabyteDB

```bash
ysqlsh -h 127.0.0.1 -d kong
```

```sql
-- All tables created by Kong migrations (~60 tables)
\dt

-- Check schema version
SELECT * FROM schema_meta ORDER BY major DESC, minor DESC LIMIT 5;

-- Core config tables
SELECT table_name, pg_size_pretty(pg_total_relation_size(quote_ident(table_name))) AS size
FROM information_schema.tables
WHERE table_schema = 'public'
  AND table_name IN ('services','routes','plugins','consumers','upstreams','targets')
ORDER BY table_name;
```

### Step 3: Create a service and route via the Admin API

```bash
# Create a service pointing to httpbin.konghq.com
curl -s -X POST http://localhost:8001/services \
  -H 'Content-Type: application/json' \
  -d '{"name":"demo-api","url":"https://httpbin.konghq.com"}' \
  | jq '{id: .id, name: .name, host: .host, port: .port}'

# Attach a route — /api path forwards to the service
curl -s -X POST http://localhost:8001/services/demo-api/routes \
  -H 'Content-Type: application/json' \
  -d '{"name":"demo-route","paths":["/api"]}' \
  | jq '{id: .id, name: .name, paths: .paths}'
```

### Step 4: Test the proxy

```bash
# Kong forwards to httpbin.konghq.com/get and rewrites the Host header
curl -s http://localhost:8000/api/get | jq '{url: .url, via_host: .headers.Host}'
```

### Step 5: Query the new config from YugabyteDB

After creating the service and route via the Admin API:

```sql
-- Services
SELECT id, name, host, port, protocol FROM services;

-- Routes
SELECT id, name, paths FROM routes;

-- Service + route join
SELECT s.name AS service, r.name AS route, r.paths
FROM routes r
JOIN services s ON s.id = r.service_id;
```

### Step 6: Add plugins

```bash
# Rate-limiting plugin on the demo-api service
curl -s -X POST http://localhost:8001/services/demo-api/plugins \
  -H 'Content-Type: application/json' \
  -d '{"name":"rate-limiting","config":{"minute":10,"policy":"local"}}' \
  | jq '{id: .id, name: .name, config: {minute: .config.minute}}'

# Response headers show the rate-limit counters
curl -sv http://localhost:8000/api/get 2>&1 | grep -i ratelimit
```

Then verify the plugin row in YugabyteDB:

```sql
SELECT id, name, config->>'minute' AS per_minute FROM plugins;
```

### Step 7: Observe all config objects

```sql
-- Config count per object type
SELECT
  (SELECT COUNT(*) FROM services)  AS services,
  (SELECT COUNT(*) FROM routes)    AS routes,
  (SELECT COUNT(*) FROM plugins)   AS plugins,
  (SELECT COUNT(*) FROM consumers) AS consumers;

-- Full config audit
SELECT
  'service' AS type, id::text, name FROM services
UNION ALL
SELECT
  'route',  id::text, name FROM routes
UNION ALL
SELECT
  'plugin', id::text, name FROM plugins
ORDER BY type, name;
```

---

## Key concepts

| Concept | Detail |
|---------|--------|
| **PostgreSQL wire protocol** | Kong uses `KONG_DATABASE=postgres`; YugabyteDB speaks the same wire protocol, so no driver change is needed |
| **Kong migrations** | On first boot, `kong migrations bootstrap` creates ~60 tables in the `kong` database — schema management is built into Kong itself |
| **Admin API** | All configuration changes go through `http://localhost:8001` (REST); Kong is stateless between restarts — config is reloaded from YugabyteDB |
| **Proxy** | Client traffic enters on `http://localhost:8000`; Kong matches the request path to a route, resolves the upstream service, and forwards |
| **rate-limiting plugin** | Increments a counter per consumer/IP per window; `policy: local` keeps state in Kong's in-memory store (use `policy: cluster` for shared counters across Kong nodes) |
| **Shared network namespace** | The Kong container runs with `--net container:<devcontainer_id>` so it binds on the devcontainer's loopback and can reach YugabyteDB on `127.0.0.1:5433` |
