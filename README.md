# ybdb-vanguard

Hands-on YugabyteDB exercises covering distributed SQL, data architecture, scalability, fault tolerance, multi-region distribution, disaster recovery, CDC, observability, security, and data migration. Each exercise runs in a fully pre-configured cloud development environment — no local YugabyteDB installation required.

---

[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/srinivasa-vasu/ybdb-vanguard?devcontainer_path=.devcontainer%2Fdevcontainer.json)

---

## Prerequisites

| Platform | Requirements |
|---|---|
| **GitHub Codespaces** | GitHub account (free tier: 60 core-hours/month) |
| **VS Code Dev Containers** | Docker Desktop · [VS Code](https://code.visualstudio.com/) · [Dev Containers extension](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers) |
| **DevPod** | Docker Desktop · [DevPod CLI](https://devpod.sh/docs/getting-started/install) |

---

## Getting Started

### 1 · Fork and clone

```bash
# Fork via GitHub UI first, then:
git clone https://github.com/<your-github-username>/ybdb-vanguard.git
cd ybdb-vanguard
```

### 2 · Pick an exercise

```bash
./launch
```

The `launch` script presents a categorised menu with role tags and resource warnings. Pick a number — the script prints a Codespaces URL, a DevPod command, and a VS Code Dev Containers instruction for the selected exercise.

**Alternative launch paths — Codespaces picker:**
1. Navigate to your fork on GitHub
2. Click **Code → Codespaces → New codespace**
3. Select the exercise from the devcontainer configuration dropdown

**GitHub CLI:**
```bash
gh codespace create \
  --repo <your-github-username>/ybdb-vanguard \
  --devcontainer-path .devcontainer/init-dsql/devcontainer.json
```

**DevPod:**
```bash
devpod up . --devcontainer-path .devcontainer/init-dsql/devcontainer.json
```

**VS Code Dev Containers:**
Open Command Palette → **Dev Containers: Open Folder in Container…** → select the exercise config.

---

## Exercises

### SQL Fundamentals

#### Distributed SQL Universe
![Dev](https://img.shields.io/badge/dev-orange?style=for-the-badge)
![Architect](https://img.shields.io/badge/arc-red?style=for-the-badge)

[README →](init-dsql/README.md) | devcontainer: `init-dsql`

Get started with YugabyteDB: hash vs range sharding, YSQL and YCQL basics, tablet distribution, and fault-tolerance fundamentals.

---

#### Query Tuning Tips & Tricks
![Dev](https://img.shields.io/badge/dev-orange?style=for-the-badge)
![Architect](https://img.shields.io/badge/arc-red?style=for-the-badge)

[README →](init-qt/README.md) | devcontainer: `init-qt`

Query execution patterns, pushdown operations, index strategies (hash, range, covering, partial, expression), join optimisation, advanced SQL, and programmability — all with `EXPLAIN (ANALYZE, DIST)`.

---

#### Query Plan Management (QPM)
![Dev](https://img.shields.io/badge/dev-orange?style=for-the-badge)
![Ops](https://img.shields.io/badge/ops-blue?style=for-the-badge)
![SRE](https://img.shields.io/badge/sre-purple?style=for-the-badge)
![Architect](https://img.shields.io/badge/arc-red?style=for-the-badge)

[README →](init-qpm/README.md) | devcontainer: `init-qpm`

Detect, compare, and pin query plans with QPM (EA, v2025.2.3+). Capture every plan a query has used in `yb_pg_stat_plans`, spot a regression after a statistics change, and pin a known-good plan via the `pg_hint_plan` hint table. The database is fully QPM-ready (extensions, defaults, and seed data) the moment the container starts.

---

### Data Placement & Architecture

#### Colocation & Distributed Tables
![Dev](https://img.shields.io/badge/dev-orange?style=for-the-badge)
![Architect](https://img.shields.io/badge/arc-red?style=for-the-badge)

[README →](init-colocate/README.md) | devcontainer: `init-colocate`

Co-locate small reference tables on a single shared tablet for local joins while keeping high-volume tables distributed. Covers `CREATE DATABASE ... WITH COLOCATION = true`, `WITH (COLOCATION = false)` opt-out, `yb_table_properties()`, and `yb_is_database_colocated()`.

---

#### Tablespaces & Online Data Migration
![Dev](https://img.shields.io/badge/dev-orange?style=for-the-badge)
![Ops](https://img.shields.io/badge/ops-blue?style=for-the-badge)
![Architect](https://img.shields.io/badge/arc-red?style=for-the-badge)

[README →](init-tablespace/README.md) | devcontainer: `init-tablespace`

Create placement-aware tablespaces with `replica_placement` JSON, pin tables and indexes to specific regions at creation time, and migrate data between tablespaces online with `ALTER TABLE SET TABLESPACE` — no cluster downtime. Covers `ALTER INDEX SET TABLESPACE` and `SET default_tablespace`.

---

### Scalability & High Availability

#### Data Distribution and Scalability
![Ops](https://img.shields.io/badge/ops-blue?style=for-the-badge)
![SRE](https://img.shields.io/badge/sre-purple?style=for-the-badge)
![Architect](https://img.shields.io/badge/arc-red?style=for-the-badge)

[README →](init-scale/README.md) | devcontainer: `init-scale`

Explore tablet-based data distribution, automatic tablet splitting, and horizontal scale-out on a 3-node cluster under `yb-sample-apps` load.

> **Note:** Requires 8 CPUs · 16 GB RAM.

---

#### Fault Tolerance and High Availability
![Ops](https://img.shields.io/badge/ops-blue?style=for-the-badge)
![SRE](https://img.shields.io/badge/sre-purple?style=for-the-badge)
![Architect](https://img.shields.io/badge/arc-red?style=for-the-badge)

[README →](init-ft/README.md) | devcontainer: `init-ft`

Chaos engineering on a 6-node cluster across 3 availability zones. Kill nodes, observe leader election and Raft re-replication, and verify zero data loss under continuous YSQL and YCQL load.

> **Note:** Requires 8 CPUs · 16 GB RAM.

---

### Multi-Region & Disaster Recovery

#### Geo-distribution & Tablespaces
![Dev](https://img.shields.io/badge/dev-orange?style=for-the-badge)
![Ops](https://img.shields.io/badge/ops-blue?style=for-the-badge)
![SRE](https://img.shields.io/badge/sre-purple?style=for-the-badge)
![Architect](https://img.shields.io/badge/arc-red?style=for-the-badge)

[README →](init-geo/README.md) | devcontainer: `init-geo`

Multi-region data placement and low-latency reads on a 3-node cluster simulating US East / EU West / AP South. Covers `CREATE TABLESPACE` with `replica_placement` JSON, region-pinned tables, row-level geo-partitioning, `yb_is_local_table`, preferred zone configuration, and follower reads.

---

#### xCluster Replication & Disaster Recovery
![Ops](https://img.shields.io/badge/ops-blue?style=for-the-badge)
![SRE](https://img.shields.io/badge/sre-purple?style=for-the-badge)
![Architect](https://img.shields.io/badge/arc-red?style=for-the-badge)

[README →](init-xcluster/README.md) | devcontainer: `init-xcluster`

Set up transactional xCluster replication with **automatic DDL propagation** between two universes (v2025.2.1+). DDL runs only on the primary — the standby receives schema changes automatically. Covers `create_xcluster_checkpoint`, PITR on standby, `setup_xcluster_replication`, role verification (`yb_xcluster_ddl_replication.get_replication_role()`), lag monitoring, and planned failover — all with standalone `yb-admin` (no YugabyteDB Anywhere required).

> **Note:** Requires 8 GB RAM (two single-node clusters running simultaneously).

---

### Data Protection & Recovery

#### Point-in-Time Recovery (PITR)
![Ops](https://img.shields.io/badge/ops-blue?style=for-the-badge)
![SRE](https://img.shields.io/badge/sre-purple?style=for-the-badge)

[README →](init-pitr/README.md) | devcontainer: `init-pitr`

Create snapshot schedules, simulate accidental `DELETE` and `DROP TABLE` disasters, and restore the database online to any second within the retention window — without stopping the cluster. Bonus: `SET yb_read_time` time-travel queries as a forensics tool.

---

#### DB Clone — Instant Database Copies
![Dev](https://img.shields.io/badge/dev-orange?style=for-the-badge)
![Ops](https://img.shields.io/badge/ops-blue?style=for-the-badge)
![SRE](https://img.shields.io/badge/sre-purple?style=for-the-badge)

[README →](init-clone/README.md) | devcontainer: `init-clone`

Clone a live database with a single SQL statement: `CREATE DATABASE clone TEMPLATE source [AS OF '<timestamp>']`. Test migrations safely, create rollback baselines, and reproduce past states — production is never touched.

---

#### Time Travel — `yb_read_time`
![Dev](https://img.shields.io/badge/dev-orange?style=for-the-badge)
![Ops](https://img.shields.io/badge/ops-blue?style=for-the-badge)

[README →](init-tt/README.md) | devcontainer: `init-tt`

Read historical snapshots of your data by setting a session-level read timestamp (`SET yb_read_time TO <unix_microseconds>`). Audit what changed, find deleted rows, run forensic investigations — the live database is never modified.

---

### Streaming & CDC

#### Change Data Capture — YugabyteDB → PostgreSQL
![Dev](https://img.shields.io/badge/dev-orange?style=for-the-badge)
![Ops](https://img.shields.io/badge/ops-blue?style=for-the-badge)
![SRE](https://img.shields.io/badge/sre-purple?style=for-the-badge)

[README →](init-cdc/README.md) | devcontainer: `init-cdc`

Stream changes from YugabyteDB to PostgreSQL using the **YugabyteDB Debezium connector** (`yboutput` logical replication plugin) and a JDBC sink connector. Guided demo: register connectors, snapshot, live INSERT/UPDATE/DELETE propagation.

---

#### CDC Streaming — YSQL → YCQL
![Dev](https://img.shields.io/badge/dev-orange?style=for-the-badge)

[Repository →](https://github.com/srinivasa-vasu/yb-cdc-streams)

Spring Cloud Stream microservices-based CDC from YSQL to YCQL through a supplier-processor-consumer pattern (external repo).

---

### Observability

#### Observability & Performance Diagnosis
![Ops](https://img.shields.io/badge/ops-blue?style=for-the-badge)
![SRE](https://img.shields.io/badge/sre-purple?style=for-the-badge)
![Architect](https://img.shields.io/badge/arc-red?style=for-the-badge)

[README →](init-obs/README.md) | devcontainer: `init-obs`

End-to-end performance investigation using built-in YugabyteDB SQL views: `pg_stat_statements` (with `docdb_rows_scanned`, `yb_latency_histogram`, P99), Active Session History (`yb_active_session_history`) grouped by query / tablet / node / session, `EXPLAIN (ANALYZE, DIST)`, `pg_locks`, `yb_cancel_transaction()`, and `yb_query_diagnostics`. No external agents or dashboards required.

---

#### OpenSearch — Log Observability with YugabyteDB
![Dev](https://img.shields.io/badge/dev-orange?style=for-the-badge)
![Ops](https://img.shields.io/badge/ops-blue?style=for-the-badge)
![SRE](https://img.shields.io/badge/sre-purple?style=for-the-badge)
![Architect](https://img.shields.io/badge/arc-red?style=for-the-badge)

[README →](init-opensearch/README.md) | devcontainer: `init-opensearch`

Ships YugabyteDB structured logs into **OpenSearch** using the **OpenTelemetry Collector contrib** binary. The OTel Collector runs as a process inside the devcontainer (not a sibling Docker container) so it can read YB GLog files directly from the filesystem. A `filelog` receiver tails master and tserver `.INFO` log files with GLog multiline parsing; a second `filelog` receiver captures PostgreSQL and pgaudit log entries. Logs flow to the `yb-logs` index. OpenSearch Dashboards provides search, index-pattern exploration, and visualization.

---

#### Elasticsearch — Logs & Metrics Observability with YugabyteDB
![Dev](https://img.shields.io/badge/dev-orange?style=for-the-badge)
![Ops](https://img.shields.io/badge/ops-blue?style=for-the-badge)
![SRE](https://img.shields.io/badge/sre-purple?style=for-the-badge)
![Architect](https://img.shields.io/badge/arc-red?style=for-the-badge)

[README →](init-elasticsearch/README.md) | devcontainer: `init-elasticsearch`

Ships YugabyteDB structured logs **and** Prometheus metrics into **Elasticsearch** using the **OpenTelemetry Collector contrib** binary. Two `filelog` receivers handle GLog (master/tserver) and PostgreSQL/pgaudit log files; a `prometheus` receiver scrapes four YB metrics endpoints (master :7000, tserver :9000, YSQL :13000, YCQL :12000) every 15 s. Logs flow to the `yb-logs` index; metrics flow to the `yb-metrics` index via the `elasticsearch/metrics` exporter with `mapping.mode: none`. Kibana provides index-pattern search and visualization for both signals. Uses Elasticsearch 8.x with security disabled for dev simplicity.

---

### Security

#### Encryption at Rest (EAR) + Key Rotation
![Ops](https://img.shields.io/badge/ops-blue?style=for-the-badge)
![SRE](https://img.shields.io/badge/sre-purple?style=for-the-badge)

[README →](init-ear/README.md) | devcontainer: `init-ear`

Enable and rotate cluster-level encryption at rest on a live YugabyteDB node — no restart required. Covers `openssl rand` key generation, `yb-admin add_universe_key_to_all_masters`, `rotate_universe_key_in_memory`, `is_encryption_enabled`, and a full quarterly key-rotation workflow.

---

#### Row Level Security & Multi-tenancy
![Dev](https://img.shields.io/badge/dev-orange?style=for-the-badge)
![Architect](https://img.shields.io/badge/arc-red?style=for-the-badge)

[README →](init-rls/README.md) | devcontainer: `init-rls`

Database-enforced tenant isolation. Covers `CREATE POLICY` with `USING` and `WITH CHECK`, session-variable multi-tenancy (`SET app.tenant_id`, `current_setting()`), `BYPASSRLS` for admin roles, `SECURITY DEFINER` functions, partial index optimisation for RLS predicates, and schema-per-tenant comparison.

---

#### Data Privacy — Column Encryption & Anonymization
![Dev](https://img.shields.io/badge/dev-orange?style=for-the-badge)
![Architect](https://img.shields.io/badge/arc-red?style=for-the-badge)

[README →](init-privacy/README.md) | devcontainer: `init-privacy`

PII protection at the column level using the `pgcrypto` extension. Covers `pgp_sym_encrypt` / `pgp_sym_decrypt` (AES via GnuPG), `digest` (SHA-256 for searchable hashes), `hmac` (tamper-evident audit logs), masking and pseudonymization patterns, anonymized views, and column-level key rotation.

---

### Search & Extensions

#### Full-Text Search
![Dev](https://img.shields.io/badge/dev-orange?style=for-the-badge)
![Architect](https://img.shields.io/badge/arc-red?style=for-the-badge)

[README →](init-fts/README.md) | devcontainer: `init-fts`

SQL-native full-text search without an external search engine. Covers `tsvector` / `tsquery`, stemming and stop-word removal, boolean and phrase operators (`to_tsquery`, `phraseto_tsquery`, `websearch_to_tsquery`), relevance ranking (`ts_rank`), highlighted snippets (`ts_headline`), persisted `tsvector` columns, `ybgin` index for single-term fast lookups, and auto-update with `tsvector_update_trigger`.

---

#### Semantic Search with pgvector
![Dev](https://img.shields.io/badge/dev-orange?style=for-the-badge)
![Architect](https://img.shields.io/badge/arc-red?style=for-the-badge)

[README →](init-pgvector/README.md) | devcontainer: `init-pgvector`

Vector similarity search using the bundled `pgvector` extension. Covers all three distance operators (`<->` L2, `<=>` cosine, `<#>` inner product), converting distance to similarity, vector magnitude (`l2_norm`) and normalization (`l2_normalize`), the normalization identity that makes inner product equivalent to cosine — enabling a `vector_ip_ops` index as the preferred choice for normalized embeddings, hybrid SQL + vector queries, and `ybhnsw` approximate nearest neighbor index with `ef_search` tuning.

---

---

### Migration  (YB Voyager)

#### Data Migration — MySQL → YugabyteDB
![Dev](https://img.shields.io/badge/dev-orange?style=for-the-badge)
![Ops](https://img.shields.io/badge/ops-blue?style=for-the-badge)

[README →](init-voyager-mysql/README.md) | devcontainer: `init-voyager-mysql`

Offline migration from MySQL to YugabyteDB using [YB Voyager](https://docs.yugabyte.com/preview/yugabyte-voyager/): assess → export schema → analyse → export data → import schema → import data → finalise.

---

#### Data Migration — MariaDB → YugabyteDB
![Dev](https://img.shields.io/badge/dev-orange?style=for-the-badge)
![Ops](https://img.shields.io/badge/ops-blue?style=for-the-badge)

[README →](init-voyager-mariadb/README.md) | devcontainer: `init-voyager-mariadb`

Offline migration from MariaDB to YugabyteDB using YB Voyager.

---

#### Data Migration — Oracle → YugabyteDB
![Dev](https://img.shields.io/badge/dev-orange?style=for-the-badge)
![Ops](https://img.shields.io/badge/ops-blue?style=for-the-badge)
![SRE](https://img.shields.io/badge/sre-purple?style=for-the-badge)

[README →](init-voyager-oracle/README.md) | devcontainer: `init-voyager-oracle`

Offline migration from Oracle Database to YugabyteDB using YB Voyager. Uses an Oracle Free container as the source.

> **Note:** Requires 8 CPUs · 16 GB RAM · 64 GB disk — Oracle container is heavyweight.

---

#### Live Data Migration — PostgreSQL → YugabyteDB
![Dev](https://img.shields.io/badge/dev-orange?style=for-the-badge)
![Ops](https://img.shields.io/badge/ops-blue?style=for-the-badge)
![SRE](https://img.shields.io/badge/sre-purple?style=for-the-badge)

[README →](init-voyager-postgres/README.md) | devcontainer: `init-voyager-postgres`

Live (online) migration from PostgreSQL to YugabyteDB with minimal downtime using YB Voyager — export + streaming CDC changes + cutover.

---

### Ecosystem

#### Keycloak — Identity & Access Management
![Dev](https://img.shields.io/badge/dev-orange?style=for-the-badge)
![Architect](https://img.shields.io/badge/arc-red?style=for-the-badge)

[README →](init-keycloak/README.md) | devcontainer: `init-keycloak`

YugabyteDB as Keycloak's backend identity store using the **YugabyteDB smart JDBC driver** (`com.yugabyte.Driver`, `jdbc:yugabytedb://`). Drop in the YB JDBC JAR and set `KC_DB_DRIVER` + `KC_DB_URL` — Keycloak needs no other changes. Covers Liquibase schema migration (~90 tables), real-time YSQL queries alongside Keycloak Admin API calls, realm and user creation via REST, and connection load-balancing across YugabyteDB nodes.

---

#### Kong Gateway — API Gateway with YugabyteDB
![Dev](https://img.shields.io/badge/dev-orange?style=for-the-badge)
![Ops](https://img.shields.io/badge/ops-blue?style=for-the-badge)
![Architect](https://img.shields.io/badge/arc-red?style=for-the-badge)

[README →](init-kong/README.md) | devcontainer: `init-kong`

Kong Gateway stores its entire configuration (services, routes, plugins, consumers) in a PostgreSQL-compatible backing database. This exercise connects Kong to **YugabyteDB YSQL** (port 5433) — Kong uses the standard PostgreSQL wire protocol and YugabyteDB speaks it back, requiring zero driver or code changes. Covers Kong bootstrap migrations (~60 tables), creating services and routes via the Admin API, proxying traffic, adding the rate-limiting plugin, and reading every config object back directly from YugabyteDB with YSQL.

---

#### WSO2 API Manager — Enterprise API Gateway with YugabyteDB
![Dev](https://img.shields.io/badge/dev-orange?style=for-the-badge)
![Ops](https://img.shields.io/badge/ops-blue?style=for-the-badge)
![Architect](https://img.shields.io/badge/arc-red?style=for-the-badge)
> ⚠ Requires **8 CPU · 16 GB RAM** (WSO2 APIM JVM + YugabyteDB)

[README →](init-wso2/README.md) | devcontainer: `init-wso2`

WSO2 API Manager stores all platform state — API definitions, subscriptions, throttling policies, users, OAuth clients, and OIDC tokens — across two YugabyteDB databases. The standard PostgreSQL JDBC driver is replaced with the **YugabyteDB smart JDBC driver** (`com.yugabyte.Driver`, `jdbc:yugabytedb://`) in `deployment.toml`, adding built-in connection load-balancing with zero WSO2 code changes. Covers two-database architecture (`wso2_amdb` for API management, `wso2_shareddb` for Carbon/Identity), DDL bootstrap from WSO2's shipped SQL scripts, the Publisher REST API, and direct YSQL queries against both databases.

---

### External Resources

#### Java Microservices
![Dev](https://img.shields.io/badge/dev-orange?style=for-the-badge)

[Repository →](https://github.com/srinivasa-vasu/yb-ms-data)

Spring Boot, Quarkus, and Micronaut integration patterns with YugabyteDB (external repo).

---

#### Java Testcontainers
![Dev](https://img.shields.io/badge/dev-orange?style=for-the-badge)

[Repository →](https://github.com/srinivasa-vasu/ybdb-boot-data)

Testcontainers integration with YugabyteDB for integration testing (external repo).

---

#### Securing Spring Boot Microservices
![Dev](https://img.shields.io/badge/dev-orange?style=for-the-badge)

[Repository →](https://github.com/srinivasa-vasu/ybdb-sealed-secrets)

Secure a Spring Boot application with YugabyteDB over TLS using cloud-native secret management (external repo).

---

## Devcontainer Reference

| Exercise | Directory | Nodes | CPUs | RAM | Disk |
|---|---|---|---|---|---|
| **SQL Fundamentals** | | | | | |
| Distributed SQL | `init-dsql` | 3 | 4 | 8 GB | 32 GB |
| Query Tuning | `init-qt` | 3 | 4 | 8 GB | 32 GB |
| Query Plan Management | `init-qpm` | 1 | 4 | 8 GB | 32 GB |
| **Data Placement & Architecture** | | | | | |
| Colocation | `init-colocate` | 3 | 4 | 8 GB | 32 GB |
| Tablespaces | `init-tablespace` | 3 | 4 | 8 GB | 32 GB |
| **Scalability & HA** | | | | | |
| Scalability | `init-scale` | 3 (→6) | **8** | **16 GB** | 32 GB |
| Fault Tolerance | `init-ft` | 6 | **8** | **16 GB** | 32 GB |
| **Multi-Region & DR** | | | | | |
| Geo-distribution | `init-geo` | 3 | 4 | 8 GB | 32 GB |
| xCluster Replication | `init-xcluster` | 2×1 | 4 | **8 GB** | 32 GB |
| **Data Protection & Recovery** | | | | | |
| PITR | `init-pitr` | 1 | 4 | 8 GB | 32 GB |
| DB Clone | `init-clone` | 1 | 4 | 8 GB | 32 GB |
| Time Travel | `init-tt` | 1 | 4 | 8 GB | 32 GB |
| **Streaming & CDC** | | | | | |
| CDC (Debezium) | `init-cdc` | 1 | 4 | 8 GB | 32 GB |
| **Observability** | | | | | |
| Observability | `init-obs` | 3 | 4 | 8 GB | 32 GB |
| OpenSearch Observability | `init-opensearch` | 1 | 4 | 8 GB | 32 GB |
| Elasticsearch Observability | `init-elasticsearch` | 1 | 4 | 8 GB | 32 GB |
| **Security** | | | | | |
| Encryption at Rest | `init-ear` | 1 | 4 | 8 GB | 32 GB |
| Row Level Security | `init-rls` | 1 | 4 | 8 GB | 32 GB |
| Data Privacy | `init-privacy` | 1 | 4 | 8 GB | 32 GB |
| **Search & Extensions** | | | | | |
| Full-Text Search | `init-fts` | 1 | 4 | 8 GB | 32 GB |
| pgvector | `init-pgvector` | 1 | 4 | 8 GB | 32 GB |
| **Migration** | | | | | |
| MySQL Migration | `init-voyager-mysql` | 1 | 4 | 8 GB | 32 GB |
| MariaDB Migration | `init-voyager-mariadb` | 1 | 4 | 8 GB | 32 GB |
| Oracle Migration | `init-voyager-oracle` | 1 | **8** | **16 GB** | **64 GB** |
| PostgreSQL Migration | `init-voyager-postgres` | 1 | 4 | 8 GB | 32 GB |
| **Ecosystem** | | | | | |
| Keycloak IAM | `init-keycloak` | 1 | 4 | 8 GB | 32 GB |
| Kong Gateway | `init-kong` | 1 | 4 | 8 GB | 32 GB |
| WSO2 API Manager | `init-wso2` | 1 | **8** | **16 GB** | 32 GB |

All exercises default to Ubuntu-based devcontainer image on `linux/amd64` and `linux/arm64`.

---

## YugabyteDB Version

This repo is pinned to **YugabyteDB 2025.2.3.2-b1**.
