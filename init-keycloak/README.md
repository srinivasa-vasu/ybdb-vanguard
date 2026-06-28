# Keycloak — Identity & Access Management with YugabyteDB

Keycloak is an enterprise-grade open-source Identity and Access Management (IAM) solution. It supports PostgreSQL as a production backend via JDBC. This exercise replaces the standard PostgreSQL JDBC driver with the **YugabyteDB smart JDBC driver** (`com.yugabyte.Driver`, `jdbc:yugabytedb://`), which adds built-in connection load-balancing and topology awareness — with zero Keycloak source changes.

---

## What you'll learn

- Run a real enterprise application (Keycloak) against YugabyteDB without source changes
- How Keycloak's Liquibase schema migrations create tables in YugabyteDB on first boot
- How to read and query Keycloak identity objects (users, realms, roles) directly via YSQL
- The difference between managing identities via the Keycloak Admin UI, the REST API, and raw SQL

---

## Setup overview

```
┌────────────────────────────────────────────────────────────┐
│  devcontainer                                              │
│                                                            │
│  ┌─────────────────────────┐   JDBC / port 5433           │
│  │  Keycloak 26.x          │ ──────────────────────────►  │
│  │  (Docker container,     │         ┌──────────────────┐ │
│  │   --net container:DC)   │         │  YugabyteDB      │ │
│  │  port 8080              │         │  database:       │ │
│  └─────────────────────────┘         │  keycloak        │ │
│                                      └──────────────────┘ │
└────────────────────────────────────────────────────────────┘
```

| Component | Address | Credentials |
|-----------|---------|-------------|
| Keycloak Admin Console | http://localhost:8080/admin | `admin` / `admin` |
| YugabyteDB YSQL | `127.0.0.1:5433` | `yugabyte` / (no password) |
| Keycloak DB role | — | `keycloak` / `keycloak123` |

The startup script (`start-keycloak.sh`) handles:
1. Starting a single-node YugabyteDB cluster
2. Creating the `keycloak` role and database in YugabyteDB
3. Downloading the YugabyteDB JDBC JAR (`jdbc-yugabytedb-42.7.3-yb-4.jar`)
4. Building a local `keycloak-yugabyte` Docker image: `COPY`s the YB JAR into `/opt/keycloak/providers/` and runs `kc.sh build` at image-build time to compile the driver into the Quarkus augmentation artifacts, then launching `kc.sh start-dev`
5. Waiting for both services to be ready before opening terminals

---

## Quick-reference: Keycloak configuration for YugabyteDB

```bash
KC_DB=postgres                                          # use PostgreSQL dialect & Liquibase scripts
KC_DB_DRIVER=com.yugabyte.Driver                        # YugabyteDB smart JDBC driver
KC_DB_URL=jdbc:yugabytedb://127.0.0.1:5433/keycloak    # YB URL scheme
KC_DB_USERNAME=keycloak
KC_DB_PASSWORD=keycloak123
KC_HOSTNAME_STRICT=false
KC_HTTP_ENABLED=true
```

The YugabyteDB JDBC JAR (`jdbc-yugabytedb-42.7.3-yb-4.jar`) is downloaded at container startup and bind-mounted into `/opt/keycloak/providers/`. The JAR is `COPY`'d into the image and `kc.sh build` runs at image-build time so the Quarkus augmentation artifacts include the driver. The container then runs `kc.sh start-dev`, which re-augments in dev mode and finds the driver already on the classpath. No `keycloak.conf` edits required.

---

## Workshop

> **Note:** The `keycloak-demo` terminal waits automatically for Keycloak to be ready before starting — no manual delay needed. Both terminals open in `init-keycloak/`. Use `keycloak-ws` for the workshop steps below.

### Step 1: Verify both services are running

In the `keycloak-ws` terminal:

```bash
# Keycloak container log (last 20 lines)
docker logs keycloak-ybdb --tail 20

# Keycloak HTTP health
curl -s http://localhost:8080/health/ready | jq .
```

### Step 2: Explore the schema Keycloak created in YugabyteDB

```bash
ysqlsh -h 127.0.0.1 -d keycloak
```

```sql
-- All tables (Keycloak creates ~90 tables via Liquibase)
\dt

-- The master realm (created automatically on first boot)
SELECT id, name, enabled, display_name, ssl_required FROM realm;

-- Clients registered in the master realm
SELECT client_id, name, enabled FROM client
WHERE realm_id = (SELECT id FROM realm WHERE name = 'master');

-- Roles in the master realm
SELECT name, description FROM keycloak_role
WHERE realm_id = (SELECT id FROM realm WHERE name = 'master')
ORDER BY name;
```

### Step 3: Create a realm and users via the Admin Console

1. Open **http://localhost:8080/admin** (admin / admin)
2. Click **Create realm** → name it `workshop` → **Create**
3. In the `workshop` realm, go to **Users** → **Add user**
4. Username: `alice`, Email: `alice@example.com` → **Create**
5. On the **Credentials** tab, set a password (disable **Temporary**)

### Step 4: Query the new identity objects from YugabyteDB

After creating the realm and user in the UI:

```sql
-- All realms
SELECT name, enabled, display_name FROM realm ORDER BY name;

-- Users across all realms
SELECT
  u.username,
  u.email,
  u.first_name,
  u.last_name,
  r.name AS realm
FROM user_entity u
JOIN realm r ON r.id = u.realm_id
ORDER BY r.name, u.username;

-- Credentials stored for each user (hashed — never plaintext)
SELECT
  u.username,
  c.type,
  c.created_date
FROM credential c
JOIN user_entity u ON u.id = c.user_id
ORDER BY u.username;
```

### Step 5: Create a realm via REST API

Keycloak exposes a full admin REST API. Get an admin token and create a realm programmatically:

```bash
# Obtain admin token
TOKEN=$(curl -s -X POST "http://localhost:8080/realms/master/protocol/openid-connect/token" \
  -d "client_id=admin-cli" \
  -d "username=admin" \
  -d "password=admin" \
  -d "grant_type=password" | jq -r .access_token)

# Create realm
curl -s -o /dev/null -w "HTTP %{http_code}\n" \
  -X POST "http://localhost:8080/admin/realms" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"realm":"api-realm","enabled":true,"displayName":"API Created Realm"}'

# Create user in the new realm
curl -s -o /dev/null -w "HTTP %{http_code}\n" \
  -X POST "http://localhost:8080/admin/realms/api-realm/users" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{"username":"devuser","email":"dev@example.com","enabled":true}'
```

Then verify immediately in YSQL:

```sql
SELECT name, display_name FROM realm WHERE name = 'api-realm';
SELECT username, email FROM user_entity
WHERE realm_id = (SELECT id FROM realm WHERE name = 'api-realm');
```

### Step 6: Observe Keycloak's distributed tables in YugabyteDB

```sql
-- Entity count overview
SELECT
  (SELECT count(*) FROM realm)          AS realms,
  (SELECT count(*) FROM user_entity)    AS users,
  (SELECT count(*) FROM client)         AS clients,
  (SELECT count(*) FROM keycloak_role)  AS roles,
  (SELECT count(*) FROM credential)     AS credentials,
  (SELECT count(*) FROM event_entity)   AS events;

-- All tables with row counts (approximate)
SELECT
  relname  AS table_name,
  n_live_tup AS approx_rows
FROM pg_stat_user_tables
ORDER BY n_live_tup DESC
LIMIT 20;
```

---

## Key concepts

| Concept | Detail |
|---------|--------|
| **YugabyteDB JDBC driver** | `com.yugabyte.Driver` with `jdbc:yugabytedb://`; adds connection load-balancing and topology awareness over standard PostgreSQL JDBC |
| **`KC_DB=postgres`** | Keycloak still uses the PostgreSQL Hibernate dialect and Liquibase scripts — only the JDBC driver class and URL scheme change |
| **Liquibase migrations** | Keycloak manages its schema with Liquibase; migrations run against YugabyteDB without modification |
| **Custom image + `start-dev`** | JAR is `COPY`'d into the image; `kc.sh build` runs at image-build time to register the driver in Quarkus augmentation artifacts; `start-dev` re-augments in dev mode and finds the driver on the classpath |
| **Shared network namespace** | The Keycloak container runs with `--net container:<devcontainer_id>` so it binds on the devcontainer's loopback |
| **Table count** | Keycloak creates ~90 tables on first boot covering realms, users, roles, sessions, clients, events, and audit logs |
