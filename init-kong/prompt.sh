#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Kong Gateway demo  —  "The Durable API Gateway"
#
# Scenario: Your platform team needs an API gateway whose entire configuration
# survives restarts.  Kong Gateway stores every service, route, plugin, and
# consumer in its backing database.  By wiring Kong to YugabyteDB (YSQL) you
# get a distributed, resilient config store with zero code changes — Kong speaks
# PostgreSQL wire protocol and YugabyteDB speaks it back.
#
# The demo provisions a Kong service + route that proxy-fords requests to
# httpbin.konghq.com, adds a rate-limiting plugin, then reads every object
# back directly from YugabyteDB to show the durable config store in action.
# ─────────────────────────────────────────────────────────────────────────────

. pscript

TYPE_SPEED=70
NO_WAIT=false
DEMO_PROMPT="${GREEN}➜ ${CYAN}\W ${COLOR_RESET}"

HOST="127.0.0.1"
KONG_ADMIN="http://localhost:8001"
KONG_PROXY="http://localhost:8000"
DB="kong"

# ── Wait for Kong Admin API before starting the demo ─────────────────────────
bash ../.devcontainer/scripts/wait-for-svc.sh \
  "${KONG_ADMIN}/" 'Kong Admin API :8001'

clear

# ── Scene 0 ───────────────────────────────────────────────────────────────────

p ""
p "=== Kong Gateway  —  The Durable API Gateway ==="
p ""
p "Kong Gateway stores its entire config in YugabyteDB."
p "Every service, route, plugin, and consumer you create via the Admin API"
p "lands in a YugabyteDB YSQL table — durable, distributed, and queryable."
p ""

# ── Scene 1: Verify Kong ─────────────────────────────────────────────────────

p "━━━ 1 of 5: Kong is up — confirm version and database backend ━━━"
p ""
pe "curl -s ${KONG_ADMIN}/ | jq '{version: .version, database: .configuration.database, pg_port: .configuration.pg_port}'"

# ── Scene 2: YugabyteDB tables created by Kong migrations ───────────────────

p ""
p "━━━ 2 of 5: Schema — Kong migrations created these tables in YugabyteDB ━━━"
p ""
pe "ysqlsh -h ${HOST} -d ${DB} -c '\pset pager off' -c '\dt'"

p ""
p "Every row in these tables is a live Kong config object."
p "Restart Kong without a snapshot — it re-reads everything from YugabyteDB."

# ── Scene 3: Create a service + route ────────────────────────────────────────

p ""
p "━━━ 3 of 5: Configure — service  →  route ━━━"
p ""
p "Create a Kong service that proxies to httpbin.konghq.com:"
pe "curl -s -X POST ${KONG_ADMIN}/services \
  -H 'Content-Type: application/json' \
  -d '{\"name\":\"demo-api\",\"url\":\"https://httpbin.konghq.com\"}' \
  | jq '{id: .id, name: .name, host: .host, port: .port, protocol: .protocol}'"

p ""
p "Attach a route — any request to /api will be forwarded to the service:"
pe "curl -s -X POST ${KONG_ADMIN}/services/demo-api/routes \
  -H 'Content-Type: application/json' \
  -d '{\"name\":\"demo-route\",\"paths\":[\"/api\"]}' \
  | jq '{id: .id, name: .name, paths: .paths}'"

# ── Scene 4: Test the proxy ───────────────────────────────────────────────────

p ""
p "━━━ 4 of 5: Traffic — proxy a request through Kong ━━━"
p ""
p "Kong rewrites the Host header and forwards to httpbin.konghq.com/get:"
pe "curl -s ${KONG_PROXY}/api/get | jq '{url: .url, via_kong_host: .headers.Host}'"

p ""
p "Add a rate-limiting plugin to the demo-api service (10 req/min):"
pe "curl -s -X POST ${KONG_ADMIN}/services/demo-api/plugins \
  -H 'Content-Type: application/json' \
  -d '{\"name\":\"rate-limiting\",\"config\":{\"minute\":10,\"policy\":\"local\"}}' \
  | jq '{id: .id, name: .name, config: {minute: .config.minute}}'"

p ""
p "The response now carries rate-limit headers:"
pe "curl -sv ${KONG_PROXY}/api/get 2>&1 | grep -i 'ratelimit'"

# ── Scene 5: Inspect config rows in YugabyteDB ───────────────────────────────

p ""
p "━━━ 5 of 5: Persistence — every config object is a row in YugabyteDB ━━━"
p ""
p "Services:"
pe "ysqlsh -h ${HOST} -d ${DB} -c '\pset pager off' -c 'SELECT id, name, host, port, protocol FROM services;'"

p ""
p "Routes:"
pe "ysqlsh -h ${HOST} -d ${DB} -c '\pset pager off' -c 'SELECT id, name, paths FROM routes;'"

p ""
p "Plugins (rate-limiting):"
pe "ysqlsh -h ${HOST} -d ${DB} -c '\pset pager off' -c \"SELECT id, name, config->>'minute' AS per_minute FROM plugins;\""

p ""
p "Config count — one row per gateway object type:"
pe "ysqlsh -h ${HOST} -d ${DB} -c \"\pset pager off\" -c \"SELECT
  (SELECT COUNT(*) FROM services) AS services,
  (SELECT COUNT(*) FROM routes)   AS routes,
  (SELECT COUNT(*) FROM plugins)  AS plugins;\""

p ""
p "────────────────────────────────────────────────────────────────────────────"
p "Kong Gateway is fully operational and backed by YugabyteDB."
p ""
p "  Admin API   →  http://localhost:8001"
p "  Proxy       →  http://localhost:8000"
p "  YSQL shell  →  ysqlsh -h 127.0.0.1 -d kong"
p "────────────────────────────────────────────────────────────────────────────"
