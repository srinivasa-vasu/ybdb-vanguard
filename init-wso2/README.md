# WSO2 API Manager — Enterprise API Gateway with YugabyteDB

WSO2 API Manager (APIM) is an open-source, enterprise-grade API management platform. It stores its entire state — API definitions, subscriptions, throttling policies, users, OAuth clients, and OIDC tokens — in a backing RDBMS. This exercise swaps the standard PostgreSQL JDBC driver for the **YugabyteDB smart JDBC driver** (`com.yugabyte.Driver`, `jdbc:yugabytedb://`) across both WSO2 datasources, adding built-in connection load-balancing and topology awareness with zero WSO2 source changes.

---

## What you'll learn

- Run WSO2 APIM against YugabyteDB using the smart JDBC driver (drop-in, no code changes)
- How WSO2 bootstraps two separate YSQL databases on first boot via DDL scripts
- How to explore and query `wso2_shareddb` (users, roles, OAuth clients) and `wso2_amdb` (APIs, subscriptions, throttling)
- How to create an API via the Publisher REST API and trace its row directly in YugabyteDB
- The architecture of WSO2's two-database model and what lives where

---

## Setup overview

```
┌──────────────────────────────────────────────────────────────────────┐
│  devcontainer                                                        │
│                                                                      │
│  ┌─────────────────────────────┐   jdbc:yugabytedb://:5433           │
│  │  WSO2 API Manager 4.7.0     │ ─────────────────────────────────►  │
│  │  (Docker container,         │   ┌──────────────────────────────┐  │
│  │   --net container:DC)       │   │  YugabyteDB                  │  │
│  │                             │   │                              │  │
│  │  Publisher:   9443/publisher│   │  wso2_shareddb               │  │
│  │  Dev Portal:  9443/devportal│   │    UM_* · REG_* · IDN_*      │  │
│  │  Admin:       9443/carbon   │   │                              │  │
│  │  Gateway:     8280 / 8243   │   │  wso2_amdb                   │  │
│  └─────────────────────────────┘   │   AM_* (APIs, subs, policies)│  │
│                                    └──────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────┘
```

| Component | Address | Credentials |
|-----------|---------|-------------|
| WSO2 Publisher | https://localhost:9443/publisher | `admin` / `admin` |
| WSO2 Dev Portal | https://localhost:9443/devportal | `admin` / `admin` |
| WSO2 Admin Console | https://localhost:9443/carbon | `admin` / `admin` |
| Gateway (HTTP) | http://localhost:8280 | — |
| YugabyteDB YSQL | `127.0.0.1:5433` | `yugabyte` / (no password) |
| WSO2 DB role | — | `wso2` / `wso2` |

The startup script (`start-wso2.sh`) handles:
1. Starting a single-node YugabyteDB cluster
2. Creating the `wso2` role and both databases (`wso2_amdb`, `wso2_shareddb`)
3. Extracting WSO2's PostgreSQL DDL scripts from the Docker image using `docker create` + `docker cp` (no container startup)
4. Running the DDL scripts against YugabyteDB to bootstrap both schemas
5. Downloading `jdbc-yugabytedb-42.7.3-yb-4.jar` and bind-mounting it into WSO2's `repository/components/lib/`
6. Patching the extracted `deployment.toml` to point both datasources at YugabyteDB with `com.yugabyte.Driver`
7. Starting the WSO2 container with the patched config and YB JAR mounted
8. Waiting for the `/services/Version` endpoint before opening terminals

---

## Quick-reference: YugabyteDB configuration in deployment.toml

```toml
[database.apim_db]
type     = "postgre"
url      = "jdbc:yugabytedb://127.0.0.1:5433/wso2_amdb"
username = "wso2"
password = "wso2"
driver   = "com.yugabyte.Driver"

[database.shared_db]
type     = "postgre"
url      = "jdbc:yugabytedb://127.0.0.1:5433/wso2_shareddb"
username = "wso2"
password = "wso2"
driver   = "com.yugabyte.Driver"
```

The default `deployment.toml` ships with H2 (`type = "h2"`) and no `driver` field. The start script extracts the defaults, replaces both database sections in-place, and mounts the patched file — leaving all other settings (gateway, key manager, throttling) at their defaults.

---

## Workshop

> **Note:** WSO2 APIM takes 3–5 minutes to boot (JVM + OSGi/Carbon framework). The `wso2-demo` terminal waits for the server automatically. Use `wso2-ws` for all manual workshop steps below. Both terminals open in `init-wso2/`.

### Step 1: Verify WSO2 and the YugabyteDB driver

In the `wso2-ws` terminal:

```bash
# Check WSO2 version
curl -sk https://localhost:9443/services/Version \
  | grep -o '<productVersion>[^<]*</productVersion>'

# Confirm the driver in deployment.toml (inside the container)
docker exec wso2-apim grep -A5 '\[database\.apim_db\]' \
  /home/wso2carbon/wso2am-4.7.0/repository/conf/deployment.toml \
  | grep -E 'type|url|driver'
```

### Step 2: Explore wso2_shareddb

In the  `ysql` shell, run all the SQL queries:

```bash
ysqlsh -h 127.0.0.1 -d wso2_shareddb
```

```sql
-- All tables (UM_* = user management, REG_* = registry, IDN_* = identity)
\dt

-- Admin user created on first boot
SELECT UM_USER_NAME, UM_CHANGED_TIME FROM UM_USER ORDER BY UM_CHANGED_TIME;

-- Default roles
SELECT UM_ROLE_NAME FROM UM_ROLE ORDER BY UM_ROLE_NAME;

-- OAuth 2.0 consumer apps (populated as you create APIs)
SELECT APP_NAME, USERNAME, OAUTH_VERSION FROM IDN_OAUTH_CONSUMER_APPS;
```

### Step 3: Explore wso2_amdb

```bash
ysqlsh -h 127.0.0.1 -d wso2_amdb
```

```sql
-- All tables (AM_* = API Manager)
\dt

-- Default throttling policies seeded on first boot
SELECT NAME, RATE_LIMIT_COUNT, RATE_LIMIT_TIME_UNIT
FROM AM_POLICY_SUBSCRIPTION ORDER BY NAME;

-- No APIs yet
SELECT COUNT(*) FROM AM_API;
```

### Step 4: Create an API via Publisher REST API

Get an admin token first:

```bash
# Register a DCR client
CREDS=$(curl -sk -X POST https://localhost:9443/client-registration/v0.17/register \
  -H "Authorization: Basic $(echo -n 'admin:admin' | base64)" \
  -H 'Content-Type: application/json' \
  -d '{"clientName":"workshop","owner":"admin","grantType":"password refresh_token","saasApp":true}')

CLIENT_ID=$(echo $CREDS     | jq -r .clientId)
CLIENT_SECRET=$(echo $CREDS | jq -r .clientSecret)

# Get publisher token
TOKEN=$(curl -sk -X POST https://localhost:9443/oauth2/token \
  -d "grant_type=password&username=admin&password=admin&scope=apim:api_create apim:api_view apim:api_manage" \
  -u "${CLIENT_ID}:${CLIENT_SECRET}" | jq -r .access_token)
```

Create a simple API:

```bash
curl -sk -X POST https://localhost:9443/api/am/publisher/v4/apis \
  -H 'Content-Type: application/json' \
  -H "Authorization: Bearer ${TOKEN}" \
  -d '{
    "name": "PetStore",
    "version": "v1",
    "context": "/petstore",
    "endpointConfig": {
      "endpoint_type": "http",
      "production_endpoints": {"url": "https://petstore.swagger.io/v2"}
    },
    "policies": ["Unlimited"],
    "operations": [{
      "target": "/pet/{petId}", "verb": "GET",
      "authType": "Application", "throttlingPolicy": "Unlimited"
    }]
  }' | jq '{id: .id, name: .name, version: .version, status: .lifeCycleStatus}'
```

### Step 5: Trace the API in YugabyteDB

```sql
-- The API just created
SELECT API_ID, API_NAME, API_VERSION, CONTEXT, STATUS FROM AM_API;

-- After publishing the API, gateway artifacts appear here
SELECT API_ID, PUBLISHED_DEFAULT_VERSION FROM AM_GATEWAY_PUBLISHED_API_DETAILS;
```

### Step 6: Platform state across both databases

```sql
-- wso2_amdb
\c wso2_amdb
SELECT
  (SELECT COUNT(*) FROM AM_API)                  AS apis,
  (SELECT COUNT(*) FROM AM_POLICY_SUBSCRIPTION)  AS sub_policies,
  (SELECT COUNT(*) FROM AM_APPLICATION)          AS applications;

-- wso2_shareddb
\c wso2_shareddb
SELECT
  (SELECT COUNT(*) FROM UM_USER)                 AS users,
  (SELECT COUNT(*) FROM UM_ROLE)                 AS roles;
```

---

## Two-database model

| Database | Tables | Purpose |
|----------|--------|---------|
| `wso2_shareddb` | `UM_*` | Users, roles, permissions (Carbon user management) |
| `wso2_shareddb` | `REG_*` | Registry resources, properties, associations |
| `wso2_shareddb` | `IDN_*` | OAuth 2.0 / OIDC clients, tokens, authorization codes |
| `wso2_amdb` | `AM_API` | API catalog (name, version, context, endpoint) |
| `wso2_amdb` | `AM_APPLICATION` | Consumer applications |
| `wso2_amdb` | `AM_SUBSCRIPTION` | App-to-API subscriptions |
| `wso2_amdb` | `AM_POLICY_*` | Throttling policies (subscription, application, API-level) |
| `wso2_amdb` | `AM_GATEWAY_*` | Gateway publication and artifact tracking |

## Key concepts

| Concept | Detail |
|---------|--------|
| **YugabyteDB smart JDBC** | `com.yugabyte.Driver` with `jdbc:yugabytedb://`; adds connection load-balancing across YugabyteDB nodes over standard PostgreSQL JDBC |
| **`type = "postgre"`** | WSO2 still uses the PostgreSQL Hibernate dialect and DDL scripts; only the JDBC driver class and URL change |
| **Two-database model** | `wso2_shareddb` holds platform-wide state (users, identity); `wso2_amdb` holds API-specific state. Both must be present and bootstrapped before WSO2 starts |
| **Schema bootstrap** | Unlike Keycloak (Liquibase) or Kong (`migrations bootstrap`), WSO2 ships raw DDL scripts that must be run manually before first boot |
| **Shared network namespace** | The WSO2 container runs with `--net container:<devcontainer_id>` so it binds on the devcontainer's loopback and reaches YugabyteDB on `127.0.0.1:5433` |
| **Bind-mount driver** | The YB JAR is mounted into `repository/components/lib/` at runtime — no custom Docker image build needed |
