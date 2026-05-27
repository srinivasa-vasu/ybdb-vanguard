# ybdb-vanguard

Hands-on YugabyteDB exercises covering distributed SQL, query tuning, data migration, CDC, scalability, and fault tolerance. Each exercise runs in a fully pre-configured cloud development environment — no local YugabyteDB installation required.

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

### 2 · Pick a platform

---

#### ☁️ GitHub Codespaces

The easiest path — runs entirely in your browser, no local Docker required.

**Option A — `launch` script (recommended)**

```bash
./launch
```

Pick an exercise number. The script prints a `codespaces.new` URL — open it in your browser and GitHub will create a Codespace pre-configured for that exercise.

```
╔══════════════════════════════════════════════════════╗
║        YugabyteDB Vanguard — Exercise Launcher       ║
╚══════════════════════════════════════════════════════╝

  1. Into the distributed and postgres++ SQL universe
  2. Query tuning tips and tricks
  3. Development innerloop workflow
  ...

Enter the number of the exercise (0 to exit): 1

▶  Open this URL to create your Codespace:

   https://codespaces.new/<your-fork>/ybdb-vanguard?devcontainer_path=.devcontainer%2Finit-dsql%2Fdevcontainer.json
```

If the [GitHub CLI](https://cli.github.com/) (`gh`) is installed, the script also offers to create the Codespace directly.

**Option B — GitHub Codespaces picker**

1. Navigate to your fork on GitHub
2. Click **Code → Codespaces → New codespace**
3. Select the exercise from the devcontainer configuration dropdown

**Option C — GitHub CLI**

```bash
gh codespace create \
  --repo <your-github-username>/ybdb-vanguard \
  --devcontainer-path .devcontainer/init-dsql/devcontainer.json
```

Replace `init-dsql` with the exercise directory of your choice (see [exercise list](#exercises) below).

---

#### 🖥️ VS Code Dev Containers

Runs locally in Docker. Full offline support once the image is pulled.

1. Clone the repo and open it in VS Code:
   ```bash
   code ybdb-vanguard
   ```
2. When prompted **"Reopen in Container"**, click it — or open the Command Palette (`⇧⌘P`) and run **Dev Containers: Open Folder in Container…**
3. VS Code detects multiple devcontainer configs and shows a picker. Select the exercise you want to run.

> **Tip:** You can also open a specific exercise directly:  
> Command Palette → **Dev Containers: Open Folder in Container…** → choose the repo root → select the config from the list.

---

#### 🚀 DevPod

[DevPod](https://devpod.sh) is an open-source, provider-agnostic devcontainer runner. It uses the same `devcontainer.json` files as Codespaces — no configuration changes needed.

```bash
# Run directly from your fork (DevPod pulls the repo)
devpod up https://github.com/<your-github-username>/ybdb-vanguard \
  --devcontainer-path .devcontainer/init-dsql/devcontainer.json

# Or, if you have the repo cloned locally
devpod up . --devcontainer-path .devcontainer/init-dsql/devcontainer.json
```

Replace `init-dsql` with the exercise directory of your choice. DevPod opens the workspace in VS Code (or your configured IDE) automatically.

---

## Exercises

### Distributed SQL Universe
![Dev](https://img.shields.io/badge/dev-orange?style=for-the-badge)
![Ops](https://img.shields.io/badge/ops-blue?style=for-the-badge)

[README →](init-dsql/README.md) | devcontainer: `init-dsql`

Get started with YugabyteDB and explore the distributed SQL universe — YSQL compatibility, resilience, and geo-distribution fundamentals.

---

### Query Tuning Tips and Tricks
![Dev](https://img.shields.io/badge/dev-orange?style=for-the-badge)
![Ops](https://img.shields.io/badge/ops-blue?style=for-the-badge)

[README →](init-qt/README.md) | devcontainer: `init-qt`

Query planning, index strategies, and performance tuning in a distributed SQL context.

---

### Development Innerloop Workflow
![Dev](https://img.shields.io/badge/dev-orange?style=for-the-badge)

[README →](init-iloop/README.md) | devcontainer: `init-iloop`

Build a YugabyteDB-backed application from scratch using JHipster. Covers the full inner-loop: scaffold → connect → iterate.

---

### Java Microservices
![Dev](https://img.shields.io/badge/dev-orange?style=for-the-badge)

[Repository →](https://github.com/srinivasa-vasu/yb-ms-data)

Spring Boot, Quarkus, and Micronaut integration patterns with YugabyteDB (external repo).

---

### Java Testcontainers
![Dev](https://img.shields.io/badge/dev-orange?style=for-the-badge)

[Repository →](https://github.com/srinivasa-vasu/ybdb-boot-data)

Testcontainers integration with YugabyteDB for integration testing (external repo).

---

### Securing Spring Boot Microservices
![Dev](https://img.shields.io/badge/dev-orange?style=for-the-badge)

[Repository →](https://github.com/srinivasa-vasu/ybdb-sealed-secrets)

Secure a Spring Boot application with YugabyteDB over TLS using cloud-native secret management (external repo).

---

### Data Migration — MySQL → YugabyteDB
![Dev](https://img.shields.io/badge/dev-orange?style=for-the-badge)
![Ops](https://img.shields.io/badge/ops-blue?style=for-the-badge)

[README →](init-voyager-mysql/README.md) | devcontainer: `init-voyager-mysql`

Offline migration from MySQL to YugabyteDB using [YB Voyager](https://docs.yugabyte.com/preview/yugabyte-voyager/).

---

### Data Migration — MariaDB → YugabyteDB
![Dev](https://img.shields.io/badge/dev-orange?style=for-the-badge)
![Ops](https://img.shields.io/badge/ops-blue?style=for-the-badge)

[README →](init-voyager-mariadb/README.md) | devcontainer: `init-voyager-mariadb`

Offline migration from MariaDB to YugabyteDB using YB Voyager.

---

### Data Migration — Oracle → YugabyteDB
![Dev](https://img.shields.io/badge/dev-orange?style=for-the-badge)
![Ops](https://img.shields.io/badge/ops-blue?style=for-the-badge)

[README →](init-voyager-oracle/README.md) | devcontainer: `init-voyager-oracle`

Offline migration from Oracle Database to YugabyteDB using YB Voyager. Uses an Oracle 21c XE container as the source.

> **Note:** Requires 8 CPUs / 64 GB RAM — Oracle image is heavyweight.

---

### Live Data Migration — PostgreSQL → YugabyteDB
![Dev](https://img.shields.io/badge/dev-orange?style=for-the-badge)
![Ops](https://img.shields.io/badge/ops-blue?style=for-the-badge)

[README →](init-voyager-postgres/README.md) | devcontainer: `init-voyager-postgres`

Live (online) migration from PostgreSQL to YugabyteDB with minimal downtime using YB Voyager.

---

### Change Data Capture — YugabyteDB → PostgreSQL
![Dev](https://img.shields.io/badge/dev-orange?style=for-the-badge)
![Ops](https://img.shields.io/badge/ops-blue?style=for-the-badge)

[README →](init-cdc/README.md) | devcontainer: `init-cdc`

Stream changes from YugabyteDB to PostgreSQL using Confluent Platform (Kafka Connect + Debezium + YB Debezium connector).

> **Note:** Requires 8 CPUs / 64 GB RAM — Confluent Platform is resource-intensive.

---

### CDC Streaming — YSQL → YCQL
![Dev](https://img.shields.io/badge/dev-orange?style=for-the-badge)

[Repository →](https://github.com/srinivasa-vasu/yb-cdc-streams)

Spring Cloud Stream microservices-based CDC integration from YSQL to YCQL through a supplier-processor-consumer pattern (external repo).

---

### Data Distribution and Scalability
![Ops](https://img.shields.io/badge/ops-blue?style=for-the-badge)

[README →](init-scale/README.md) | devcontainer: `init-scale`

Explore tablet-based data distribution, tablet splitting, and horizontal scale-out on a 3-node cluster under `yb-sample-apps` load.

---

### Fault Tolerance and High Availability
![Ops](https://img.shields.io/badge/ops-blue?style=for-the-badge)

[README →](init-ft/README.md) | devcontainer: `init-ft`

Chaos engineering on a 6-node cluster across 3 availability zones. Kill nodes, observe leader election, and verify zero data loss under `yb-sample-apps` load.

---

## Devcontainer Reference

| Exercise | Directory | Nodes | CPUs | RAM |
|---|---|---|---|---|
| Distributed SQL | `init-dsql` | 3 | 4 | 8 GB |
| Query Tuning | `init-qt` | 3 | 4 | 8 GB |
| Innerloop | `init-iloop` | 1 | 4 | 8 GB |
| MySQL Migration | `init-voyager-mysql` | 1 | 4 | 8 GB |
| MariaDB Migration | `init-voyager-mariadb` | 1 | 4 | 8 GB |
| Oracle Migration | `init-voyager-oracle` | 1 | 8 | 64 GB |
| PostgreSQL Migration | `init-voyager-postgres` | 1 | 4 | 16 GB |
| CDC | `init-cdc` | 1 | 8 | 64 GB |
| Scalability | `init-scale` | 3 (→6) | 8 | 16 GB |
| Fault Tolerance | `init-ft` | 6 | 8 | 16 GB |

---

## YugabyteDB Version

This repo is pinned to **YugabyteDB 2025.2.3.0-b149**. The [CI workflow](.github/workflows/ci.yml) runs a weekly version drift check and will warn when a newer stable release is available.
