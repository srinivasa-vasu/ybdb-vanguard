#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# WSO2 API Manager demo  —  "The Enterprise Integration Hub"
#
# Scenario: An enterprise API platform team needs every API definition,
# subscription, throttling policy, and user credential to survive node
# failures and restarts — with no external backup.  WSO2 APIM stores all of
# this state in its backing RDBMS.  By connecting it to YugabyteDB via the
# smart JDBC driver (com.yugabyte.Driver, jdbc:yugabytedb://), the platform
# inherits built-in connection load-balancing and survives YugabyteDB node
# restarts without connection-pool reconfiguration.
#
# Two databases:
#   wso2_shareddb  —  Carbon/Identity:  UM_* (users/roles), IDN_* (OAuth/OIDC)
#   wso2_amdb      —  API Manager:      AM_* (APIs, subscriptions, throttling)
# ─────────────────────────────────────────────────────────────────────────────

. pscript

TYPE_SPEED=70
WSO2_VERSION="${WSO2_VERSION:-4.7.0}"
WSO2_HOME="/home/wso2carbon/wso2am-${WSO2_VERSION}"
NO_WAIT=false
DEMO_PROMPT="${GREEN}➜ ${CYAN}\W ${COLOR_RESET}"

clear

HOST="127.0.0.1"
WSO2_BASE="https://localhost:9443"

# ── Wait for WSO2 before starting the demo ───────────────────────────────────
bash ../.devcontainer/scripts/wait-for-svc.sh \
  'https://localhost:9443/' 'WSO2 API Manager :9443'

# ── OAuth token helper (silent — not typed out) ───────────────────────────────
_get_token() {
  local _creds
  _creds=$(curl -sk -X POST "${WSO2_BASE}/client-registration/v0.17/register" \
    -H "Authorization: Basic $(echo -n 'admin:admin' | base64)" \
    -H 'Content-Type: application/json' \
    -d '{"clientName":"ybdb-demo","owner":"admin","grantType":"password refresh_token","saasApp":true}' \
    2>/dev/null)
  local _id _secret
  _id=$(echo "${_creds}"     | jq -r '.clientId     // empty' 2>/dev/null)
  _secret=$(echo "${_creds}" | jq -r '.clientSecret // empty' 2>/dev/null)
  [ -z "${_id}" ] && return
  curl -sk -X POST "${WSO2_BASE}/oauth2/token" \
    -d "grant_type=password&username=admin&password=admin&scope=apim:api_create apim:api_view apim:subscribe apim:api_manage" \
    -u "${_id}:${_secret}" 2>/dev/null \
    | jq -r '.access_token // empty' 2>/dev/null
}

# ── Scene 0 ───────────────────────────────────────────────────────────────────
p ""
p "=== WSO2 API Manager  —  The Enterprise Integration Hub ==="
p ""
p "WSO2 APIM stores all platform state in YugabyteDB:"
p "  wso2_shareddb  →  users, roles, OAuth clients, OIDC tokens"
p "  wso2_amdb      →  API definitions, subscriptions, throttling policies"
p ""
p "Driver: com.yugabyte.Driver   (drop-in, zero WSO2 code changes)"
p ""

# ── Scene 1: Health ───────────────────────────────────────────────────────────
p "━━━ 1 of 5: WSO2 APIM is up — verify version and JDBC driver ━━━"
p ""
pe "curl -sk ${WSO2_BASE}/services/Version | grep -o '<return>[^<]*</return>'"

p ""
p "YugabyteDB JDBC driver in deployment.toml (both datasources):"
pe "docker exec wso2-apim grep -A5 '\[database\.apim_db\]' \
  ${WSO2_HOME}/repository/conf/deployment.toml \
  | grep -E 'type|url|driver'"

# ── Scene 2: wso2_shareddb schema ────────────────────────────────────────────
p ""
p "━━━ 2 of 5: wso2_shareddb — user management + identity tables ━━━"
p ""
pe "ysqlsh -h ${HOST} -d wso2_shareddb -c '\pset pager off' -c '\dt'"

p ""
p "Admin user provisioned on first boot:"
pe "ysqlsh -h ${HOST} -d wso2_shareddb -c \
  'SELECT UM_USER_NAME, UM_CHANGED_TIME FROM UM_USER ORDER BY UM_CHANGED_TIME LIMIT 5;'"

# ── Scene 3: wso2_amdb schema ─────────────────────────────────────────────────
p ""
p "━━━ 3 of 5: wso2_amdb — API management tables ━━━"
p ""
pe "ysqlsh -h ${HOST} -d wso2_amdb -c '\pset pager off' -c '\dt'"

p ""
p "Default throttling policies seeded on first boot:"
pe "ysqlsh -h ${HOST} -d wso2_amdb -c \
  'SELECT NAME, RATE_LIMIT_COUNT, RATE_LIMIT_TIME_UNIT FROM AM_POLICY_SUBSCRIPTION ORDER BY NAME;'"

# ── Scene 4: Create an API via Publisher REST API ─────────────────────────────
p ""
p "━━━ 4 of 5: Publish an API — every object lands in wso2_amdb ━━━"
p ""
_TOKEN=$(_get_token)

pe "curl -sk -X POST ${WSO2_BASE}/api/am/publisher/v4/apis \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer ${_TOKEN}' \
  -d '{
    \"name\":\"PetStore\",
    \"version\":\"v1\",
    \"context\":\"/petstore\",
    \"endpointConfig\":{\"endpoint_type\":\"http\",
      \"production_endpoints\":{\"url\":\"https://petstore.swagger.io/v2\"}},
    \"policies\":[\"Unlimited\"],
    \"operations\":[{\"target\":\"/pet/{petId}\",\"verb\":\"GET\",\"authType\":\"Application\",\"throttlingPolicy\":\"Unlimited\"}]
  }' | jq '{id: .id, name: .name, version: .version, status: .lifeCycleStatus}'"

p ""
p "API row now in wso2_amdb:"
pe "ysqlsh -h ${HOST} -d wso2_amdb -c \
  'SELECT API_ID, API_NAME, API_VERSION, CONTEXT, STATUS FROM AM_API ORDER BY API_ID DESC LIMIT 5;'"

# ── Scene 5: Cross-database picture ──────────────────────────────────────────
p ""
p "━━━ 5 of 5: Platform state — both YugabyteDB databases ━━━"
p ""
pe "ysqlsh -h ${HOST} -d wso2_shareddb -c \
  \"SELECT 'wso2_shareddb' AS database,
    (SELECT COUNT(*) FROM UM_USER)             AS users,
    (SELECT COUNT(*) FROM UM_ROLE)             AS roles;\""

pe "ysqlsh -h ${HOST} -d wso2_amdb -c \
  \"SELECT 'wso2_amdb' AS database,
    (SELECT COUNT(*) FROM AM_API)                  AS apis,
    (SELECT COUNT(*) FROM AM_POLICY_SUBSCRIPTION)  AS sub_policies,
    (SELECT COUNT(*) FROM AM_APPLICATION)          AS applications;\""

p ""
p "────────────────────────────────────────────────────────────────────────────"
p "WSO2 API Manager is fully operational on YugabyteDB."
p ""
p "  Publisher     →  https://localhost:9443/publisher   (admin / admin)"
p "  Dev Portal    →  https://localhost:9443/devportal"
p "  Admin Console →  https://localhost:9443/carbon"
p "  Gateway       →  http://localhost:8280"
p "  YSQL shells   →  ysqlsh -h 127.0.0.1 -d wso2_amdb"
p "                    ysqlsh -h 127.0.0.1 -d wso2_shareddb"
p "────────────────────────────────────────────────────────────────────────────"
