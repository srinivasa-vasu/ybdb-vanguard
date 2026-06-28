#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Keycloak — Identity & Access Management with YugabyteDB
#
# Keycloak stores every identity object (users, realms, sessions, credentials)
# in YugabyteDB using the YugabyteDB smart JDBC driver (com.yugabyte.Driver).
# The driver is a drop-in replacement for PostgreSQL JDBC with built-in
# connection load-balancing and topology awareness.
# ─────────────────────────────────────────────────────────────────────────────

. pscript

TYPE_SPEED=70
HOST="127.0.0.1"
KC_URL="http://localhost:8080"
DB="keycloak"

# ── Wait for Keycloak before starting the demo ────────────────────────────────
bash ../.devcontainer/scripts/wait-for-svc.sh \
  "${KC_URL}/" 'Keycloak :8080'

clear

p ""
p "━━━ Keycloak + YugabyteDB — Identity & Access Management ━━━"
p ""
p "Keycloak is an open-source Identity and Access Management (IAM) solution."
p "By default it uses an embedded H2 database.  In production it supports"
p "PostgreSQL — and YugabyteDB is a drop-in replacement for PostgreSQL."

# ─────────────────────────────────────────────────────────────────────────────
# PART 1 — YugabyteDB as Keycloak's identity store
# ─────────────────────────────────────────────────────────────────────────────

p ""
p "━━━ Part 1: YugabyteDB — Keycloak's Identity Store ━━━"
p ""
p "Keycloak database and role were provisioned at container startup:"
pe "ysqlsh -h ${HOST} -c '\l'"

p ""
p "Keycloak connects via the YugabyteDB smart JDBC driver with these settings:"
p "  KC_DB=postgres"
p "  KC_DB_DRIVER=com.yugabyte.Driver"
p "  KC_DB_URL=jdbc:yugabytedb://127.0.0.1:5433/${DB}"
p "  KC_DB_USERNAME=keycloak"
p ""
p "The YB driver adds connection load-balancing across YugabyteDB nodes."
p "No Keycloak source changes — only the driver JAR and JDBC URL differ."

# ─────────────────────────────────────────────────────────────────────────────
# PART 2 — Keycloak schema created in YugabyteDB
# ─────────────────────────────────────────────────────────────────────────────

p ""
p "━━━ Part 2: Keycloak Schema in YugabyteDB ━━━"
p ""
p "On first boot Keycloak ran its Liquibase migrations against YugabyteDB."
p "Inspect the tables it created:"
pe "ysqlsh -h ${HOST} -d ${DB} -c '\pset pager off' -c '\dt'"

p ""
p "The master realm is already stored in YugabyteDB:"
pe "ysqlsh -h ${HOST} -d ${DB} -c 'SELECT id, name, enabled FROM realm;'"

p ""
p "Roles Keycloak seeded for the master realm:"
pe "ysqlsh -h ${HOST} -d ${DB} -c \"SELECT name, description FROM keycloak_role WHERE realm_id IN (SELECT id FROM realm WHERE name = 'master') LIMIT 10;\""

# ─────────────────────────────────────────────────────────────────────────────
# PART 3 — Identity operations that write to YugabyteDB
# ─────────────────────────────────────────────────────────────────────────────

p ""
p "━━━ Part 3: Identity Operations → Data Stored in YugabyteDB ━━━"
p ""
p "Obtain an admin access token from Keycloak:"
pe "curl -s -X POST '${KC_URL}/realms/master/protocol/openid-connect/token' \
  -d 'client_id=admin-cli' -d 'username=admin' -d 'password=admin' \
  -d 'grant_type=password' | jq -r '.access_token' | cut -c1-80"

# Capture token for subsequent API calls
_TOKEN=$(curl -s -X POST "${KC_URL}/realms/master/protocol/openid-connect/token" \
  -d "client_id=admin-cli" -d "username=admin" -d "password=admin" \
  -d "grant_type=password" 2>/dev/null | jq -r '.access_token' 2>/dev/null || echo "")

p ""
p "Create a 'yugabyte' realm (HTTP 201 = created):"
pe "curl -s -o /dev/null -w 'HTTP %{http_code}' \
  -X POST '${KC_URL}/admin/realms' \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer ${_TOKEN}' \
  -d '{\"realm\":\"yugabyte\",\"enabled\":true,\"displayName\":\"YugabyteDB Realm\"}'"

p ""
p "Create user alice in the yugabyte realm (HTTP 201 = created):"
_TOKEN=$(curl -s -X POST "${KC_URL}/realms/master/protocol/openid-connect/token" \
  -d "client_id=admin-cli" -d "username=admin" -d "password=admin" \
  -d "grant_type=password" 2>/dev/null | jq -r '.access_token // empty' 2>/dev/null)
pe "curl -s -o /dev/null -w 'HTTP %{http_code}' \
  -X POST '${KC_URL}/admin/realms/yugabyte/users' \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer ${_TOKEN}' \
  -d '{\"username\":\"alice\",\"email\":\"alice@yugabyte.com\",\"enabled\":true,\"firstName\":\"Alice\",\"lastName\":\"Dev\"}'"

p ""
p "Create user bob in the yugabyte realm:"
_TOKEN=$(curl -s -X POST "${KC_URL}/realms/master/protocol/openid-connect/token" \
  -d "client_id=admin-cli" -d "username=admin" -d "password=admin" \
  -d "grant_type=password" 2>/dev/null | jq -r '.access_token // empty' 2>/dev/null)
pe "curl -s -o /dev/null -w 'HTTP %{http_code}' \
  -X POST '${KC_URL}/admin/realms/yugabyte/users' \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer ${_TOKEN}' \
  -d '{\"username\":\"bob\",\"email\":\"bob@yugabyte.com\",\"enabled\":true,\"firstName\":\"Bob\",\"lastName\":\"Ops\"}'"

p ""
p "Query all realms directly from YugabyteDB:"
pe "ysqlsh -h ${HOST} -d ${DB} -c 'SELECT name, enabled FROM realm ORDER BY name;'"

p ""
p "Query all users directly from YugabyteDB:"
pe "ysqlsh -h ${HOST} -d ${DB} -c 'SELECT username, email, first_name, last_name, (SELECT name FROM realm WHERE id = user_entity.realm_id) AS realm FROM user_entity ORDER BY realm, username;'"

# ─────────────────────────────────────────────────────────────────────────────
# PART 4 — Summary counts
# ─────────────────────────────────────────────────────────────────────────────

p ""
p "━━━ Part 4: What YugabyteDB Holds ━━━"
p ""
p "Entity count across Keycloak's distributed identity store:"
pe "ysqlsh -h ${HOST} -d ${DB} -c \
  'SELECT (SELECT count(*) FROM realm) AS realms, \
          (SELECT count(*) FROM user_entity) AS users, \
          (SELECT count(*) FROM client) AS clients, \
          (SELECT count(*) FROM keycloak_role) AS roles, \
          (SELECT count(*) FROM credential) AS credentials;'"

p ""
p "━━━ Done ━━━"
p ""
p "YugabyteDB stores every Keycloak identity object — users, realms, sessions,"
p "credentials, roles — backed by the YugabyteDB smart JDBC driver."
p ""
p "  Admin console  →  http://localhost:8080/admin  (admin / admin)"
p "  YSQL shell     →  ysqlsh -h 127.0.0.1 -d keycloak"
