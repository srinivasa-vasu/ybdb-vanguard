# ybdb-vanguard

Hands-on YugabyteDB exercises covering distributed SQL, query tuning, data migration, CDC, scalability, fault tolerance, observability, and data protection. Each exercise runs in a fully pre-configured cloud development environment — no local YugabyteDB installation required.

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

The `launch` script presents a categorised menu with role tags and resource warnings:

```
╔══════════════════════════════════════════════════════╗
║        YugabyteDB Vanguard — Exercise Launcher       ║
╚══════════════════════════════════════════════════════╝

  ── SQL Fundamentals ─────────────────────────────────────────
   1.  Distributed SQL Universe                        dev  arc
   2.  Query Tuning Tips & Tricks                      dev  arc

  ── Migration  (YB Voyager) ──────────────────────────────────
   3.  MySQL → YugabyteDB                             dev  ops
   4.  MariaDB → YugabyteDB                           dev  ops
   5.  Oracle → YugabyteDB          ⚠ 8c · 16g       dev  ops  sre
   6.  PostgreSQL → YugabyteDB (live migration)       dev  ops  sre
  ...

  Tags:  dev developer   ops operations   sre reliability   arc architect
  ⚠ = above standard requirements (default: 4 CPU · 8 GB RAM · 32 GB disk)
```

Pick a number — the script prints a Codespaces URL, a DevPod command, and a VS Code Dev Containers instruction for the selected exercise. If the [GitHub CLI](https://cli.github.com/) (`gh`) is installed it also offers to create the Codespace directly.

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
![Architect](https://img.shields.io/badge/arc-green?style=for-the-badge)

[README →](init-dsql/README.md) | devcontainer: `init-dsql`

Get started with YugabyteDB: hash vs range sharding, YSQL and YCQL basics, tablet distribution, and fault-tolerance fundamentals.

---

#### Query Tuning Tips & Tricks
![Dev](https://img.shields.io/badge/dev-orange?style=for-the-badge)
![Architect](https://img.shields.io/badge/arc-green?style=for-the-badge)

[README →](init-qt/README.md) | devcontainer: `init-qt`

Query execution patterns, pushdown operations, index strategies (hash, range, covering, partial, expression), join optimisation, advanced SQL, and programmability — all with `EXPLAIN (ANALYZE, DIST)`.

---

### Migration  (YB Voyager)

#### Data Migration — MySQL → YugabyteDB
![Dev](https://img.shields.io/badge/dev-orange?style=for-the-badge)
![Ops](https://img.shields.io/badge/ops-blue?style=for-the-badge)

[README →](init-voyager-mysql/README.md) | devcontainer: `init-voyager-mysql`

Offline migration from MySQL to YugabyteDB using [YB Voyager](https://docs.yugabyte.com/preview/yugabyte-voyager/): export schema → analyse → export data → import schema → import data.

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
![SRE](https://img.shields.io/badge/sre-yellow?style=for-the-badge)

[README →](init-voyager-oracle/README.md) | devcontainer: `init-voyager-oracle`

Offline migration from Oracle Database to YugabyteDB using YB Voyager. Uses an Oracle Free container as the source.

> **Note:** Requires 8 CPUs · 16 GB RAM · 64 GB disk — Oracle container is heavyweight.

---

#### Live Data Migration — PostgreSQL → YugabyteDB
![Dev](https://img.shields.io/badge/dev-orange?style=for-the-badge)
![Ops](https://img.shields.io/badge/ops-blue?style=for-the-badge)
![SRE](https://img.shields.io/badge/sre-yellow?style=for-the-badge)

[README →](init-voyager-postgres/README.md) | devcontainer: `init-voyager-postgres`

Live (online) migration from PostgreSQL to YugabyteDB with minimal downtime using YB Voyager — export + streaming changes + cutover.

---

### Streaming & CDC

#### Change Data Capture — YugabyteDB → PostgreSQL
![Dev](https://img.shields.io/badge/dev-orange?style=for-the-badge)
![Ops](https://img.shields.io/badge/ops-blue?style=for-the-badge)
![SRE](https://img.shields.io/badge/sre-yellow?style=for-the-badge)

[README →](init-cdc/README.md) | devcontainer: `init-cdc`

Stream changes from YugabyteDB to PostgreSQL using the **YugabyteDB Debezium connector** (`yboutput` logical replication plugin) and a JDBC sink connector. Includes a guided demo: register connectors, snapshot, live INSERT/UPDATE/DELETE propagation.

---

#### CDC Streaming — YSQL → YCQL
![Dev](https://img.shields.io/badge/dev-orange?style=for-the-badge)

[Repository →](https://github.com/srinivasa-vasu/yb-cdc-streams)

Spring Cloud Stream microservices-based CDC from YSQL to YCQL through a supplier-processor-consumer pattern (external repo).

---

### Scalability & HA

#### Data Distribution and Scalability
![Ops](https://img.shields.io/badge/ops-blue?style=for-the-badge)
![SRE](https://img.shields.io/badge/sre-yellow?style=for-the-badge)
![Architect](https://img.shields.io/badge/arc-green?style=for-the-badge)

[README →](init-scale/README.md) | devcontainer: `init-scale`

Explore tablet-based data distribution, automatic tablet splitting, and horizontal scale-out on a 3-node cluster under `yb-sample-apps` load.

> **Note:** Requires 8 CPUs · 16 GB RAM.

---

#### Fault Tolerance and High Availability
![Ops](https://img.shields.io/badge/ops-blue?style=for-the-badge)
![SRE](https://img.shields.io/badge/sre-yellow?style=for-the-badge)
![Architect](https://img.shields.io/badge/arc-green?style=for-the-badge)

[README →](init-ft/README.md) | devcontainer: `init-ft`

Chaos engineering on a 6-node cluster across 3 availability zones. Kill nodes, observe leader election and Raft re-replication, and verify zero data loss under continuous YSQL and YCQL load.

> **Note:** Requires 8 CPUs · 16 GB RAM.

---

### Global Distribution

#### Geo-distribution & Tablespaces
![Dev](https://img.shields.io/badge/dev-orange?style=for-the-badge)
![Ops](https://img.shields.io/badge/ops-blue?style=for-the-badge)
![SRE](https://img.shields.io/badge/sre-yellow?style=for-the-badge)
![Architect](https://img.shields.io/badge/arc-green?style=for-the-badge)

[README →](init-geo/README.md) | devcontainer: `init-geo`

Multi-region data placement, row-level data residency, and low-latency reads on a 3-node cluster simulating US East / EU West / AP South. Covers: `CREATE TABLESPACE` with `replica_placement` JSON, region-pinned tables and indexes, row-level geo-partitioning with `PARTITION BY LIST`, `yb_is_local_table`, preferred zone configuration with `yb-admin set_preferred_zones`, and follower reads (`SET yb_read_from_followers`).

---

### Data Protection

#### Point-in-Time Recovery (PITR)
![Ops](https://img.shields.io/badge/ops-blue?style=for-the-badge)
![SRE](https://img.shields.io/badge/sre-yellow?style=for-the-badge)

[README →](init-pitr/README.md) | devcontainer: `init-pitr`

Create snapshot schedules, simulate accidental `DELETE` and `DROP TABLE` disasters, and restore the database online to any second within the retention window — without stopping the cluster.

---

#### DB Clone — Instant Database Copies
![Dev](https://img.shields.io/badge/dev-orange?style=for-the-badge)
![Ops](https://img.shields.io/badge/ops-blue?style=for-the-badge)
![SRE](https://img.shields.io/badge/sre-yellow?style=for-the-badge)

[README →](init-clone/README.md) | devcontainer: `init-clone`

Clone a live database with a single SQL statement: `CREATE DATABASE clone TEMPLATE source [AS OF '<timestamp>']`. Test migrations safely, create rollback baselines, and reproduce past states — production is never touched.

---

#### Time Travel — `yb_read_time`
![Dev](https://img.shields.io/badge/dev-orange?style=for-the-badge)
![Ops](https://img.shields.io/badge/ops-blue?style=for-the-badge)

[README →](init-tt/README.md) | devcontainer: `init-tt`

Read historical snapshots of your data by setting a session-level read timestamp (`SET yb_read_time TO <unix_microseconds>`). Audit what changed, find deleted rows, run forensic investigations — the live database is never modified.

---

### Observability

#### Observability & Performance Diagnosis
![Ops](https://img.shields.io/badge/ops-blue?style=for-the-badge)
![SRE](https://img.shields.io/badge/sre-yellow?style=for-the-badge)
![Architect](https://img.shields.io/badge/arc-green?style=for-the-badge)

[README →](init-obs/README.md) | devcontainer: `init-obs`

End-to-end performance investigation using built-in YugabyteDB SQL views: `pg_stat_statements` (`docdb_rows_scanned`, `yb_latency_histogram`, P99), Active Session History (`yb_active_session_history`) grouped by query / tablet / node / session, `EXPLAIN (ANALYZE, DIST)`, `pg_locks`, `yb_cancel_transaction()`, and `yb_query_diagnostics`. No external agents or dashboards required.

---

### Security

#### Encryption at Rest (EAR) + Key Rotation
![Ops](https://img.shields.io/badge/ops-blue?style=for-the-badge)
![SRE](https://img.shields.io/badge/sre-yellow?style=for-the-badge)

[README →](init-ear/README.md) | devcontainer: `init-ear`

Enable and rotate cluster-level encryption at rest on a live YugabyteDB node — no restart required. Covers: `openssl rand` key generation, `yb-admin add_universe_key_to_all_masters`, `rotate_universe_key_in_memory`, `is_encryption_enabled`, and a full quarterly key-rotation workflow.

---

#### Row Level Security & Multi-tenancy
![Dev](https://img.shields.io/badge/dev-orange?style=for-the-badge)
![Architect](https://img.shields.io/badge/arc-green?style=for-the-badge)

[README →](init-rls/README.md) | devcontainer: `init-rls`

Database-enforced tenant isolation on a 3-node YugabyteDB cluster. Covers: `CREATE POLICY` with `USING` and `WITH CHECK`, session-variable multi-tenancy (`SET app.tenant_id`, `current_setting()`), `BYPASSRLS` for admin roles, `SECURITY DEFINER` functions, partial index optimisation for RLS predicates, and schema-per-tenant comparison.

---

#### Data Privacy — Column Encryption & Anonymization
![Dev](https://img.shields.io/badge/dev-orange?style=for-the-badge)
![Architect](https://img.shields.io/badge/arc-green?style=for-the-badge)

[README →](init-privacy/README.md) | devcontainer: `init-privacy`

PII protection at the column level using the `pgcrypto` extension. Covers: `pgp_sym_encrypt` / `pgp_sym_decrypt` (AES via GnuPG), `digest` (SHA-256 for searchable hashes), `hmac` (tamper-evident audit logs), `gen_random_bytes`, masking and pseudonymization patterns, anonymized views for multi-schema access (production vs analytics), and column-level key rotation.

---

### Dev Innerloop

#### Development Innerloop Workflow
![Dev](https://img.shields.io/badge/dev-orange?style=for-the-badge)

[README →](init-iloop/README.md) | devcontainer: `init-iloop`

Scaffold a YugabyteDB-backed application from scratch using the JHipster YugabyteDB generator. Covers the full inner-loop: generate → connect → iterate.

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
| Distributed SQL | `init-dsql` | 3 | 4 | 8 GB | 32 GB |
| Query Tuning | `init-qt` | 3 | 4 | 8 GB | 32 GB |
| MySQL Migration | `init-voyager-mysql` | 1 | 4 | 8 GB | 32 GB |
| MariaDB Migration | `init-voyager-mariadb` | 1 | 4 | 8 GB | 32 GB |
| Oracle Migration | `init-voyager-oracle` | 1 | **8** | **16 GB** | **64 GB** |
| PostgreSQL Migration | `init-voyager-postgres` | 1 | 4 | 8 GB | 32 GB |
| CDC (Debezium) | `init-cdc` | 1 | 4 | 8 GB | 32 GB |
| Scalability | `init-scale` | 3 (→6) | **8** | **16 GB** | 32 GB |
| Fault Tolerance | `init-ft` | 6 | **8** | **16 GB** | 32 GB |
| PITR | `init-pitr` | 1 | 4 | 8 GB | 32 GB |
| DB Clone | `init-clone` | 1 | 4 | 8 GB | 32 GB |
| Time Travel | `init-tt` | 1 | 4 | 8 GB | 32 GB |
| Geo-distribution | `init-geo` | 3 | 4 | 8 GB | 32 GB |
| Observability | `init-obs` | 3 | 4 | 8 GB | 32 GB |
| Encryption at Rest | `init-ear` | 1 | 4 | 8 GB | 32 GB |
| Row Level Security | `init-rls` | 1 | 4 | 8 GB | 32 GB |
| Data Privacy | `init-privacy` | 1 | 4 | 8 GB | 32 GB |
| Dev Innerloop | `init-iloop` | 1 | 4 | 8 GB | 32 GB |

Bold = above standard. All exercises default to Ubuntu-based devcontainer image on `linux/amd64` and `linux/arm64`.

---

## YugabyteDB Version

This repo is pinned to **YugabyteDB 2025.2.3.0-b149**. The [CI workflow](.github/workflows/ci.yml) runs a weekly version drift check and will warn when a newer stable release is available.
