# Data Distribution & Scalability

[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/srinivasa-vasu/ybdb-vanguard?devcontainer_path=.devcontainer%2Finit-scale%2Fdevcontainer.json)

Observe how YugabyteDB distributes data across tablets, watch live metrics under `yb-sample-apps` load, and scale the cluster from 3 nodes to 6 — all without downtime.

---

## Prerequisites

The devcontainer starts a **3-node cluster** configured with 2 shards per tserver (`ysql_num_shards_per_tserver=2`, `yb_num_shards_per_tserver=2`). Java 21 and `yb-sample-apps.jar` are installed automatically.

---

## Running the exercise

Open the task shells from the VS Code **Terminal** menu:

| Task | What it does |
|---|---|
| **Terminal → Run Task → `scale: ysql-load`** | YSQL `SqlInserts` load — 2 read threads / 1 write thread |
| **Terminal → Run Task → `scale: ycql-load`** | YCQL `CassandraKeyValue` load — 3 read threads / 1 write thread |
| **Terminal → Run Task → `ybdb-scale`** | Scale-out demo script (`prompt.sh`) |
| **Terminal → Run Task → `scale: start all`** | Launches all three in parallel |

**Recommended flow:**
1. Start `scale: ysql-load` and `scale: ycql-load` first and let them reach steady throughput
2. Open the yugabyted UI at `localhost:15433` to observe tablet distribution
3. Then run `ybdb-scale` to trigger the scale-out from 3 → 6 nodes

---

## What the demo shows

The `ybdb-scale` demo (`prompt.sh`) adds three new nodes — one per AZ — while load generators run continuously:

1. **Baseline** — observe tablet leaders spread across 3 nodes
2. **Add node 4** (AZ1, `127.0.0.4`) — watch tablets rebalance automatically
3. **Add node 5** (AZ2, `127.0.0.5`) — more rebalancing, no downtime
4. **Add node 6** (AZ3, `127.0.0.6`) — cluster now fully 6-node across 3 AZs
5. **Verify** — check that load generators never stopped; data is intact

---

## Cluster topology

```
Before scale-out          After scale-out
──────────────────        ──────────────────────────────
AZ1: 127.0.0.1            AZ1: 127.0.0.1  127.0.0.4
AZ2: 127.0.0.2            AZ2: 127.0.0.2  127.0.0.5
AZ3: 127.0.0.3            AZ3: 127.0.0.3  127.0.0.6
```

The extra nodes join as peers — no leader election restart, no client reconnection required.

---

## Useful commands

```bash
# Cluster status and node list
yugabyted status

# Tablet distribution (from ysqlsh)
SELECT host, zone, COUNT(*) AS leader_count
FROM yb_tablet_metadata tm
JOIN yb_servers() sv ON tm.leader LIKE sv.host || '%'
GROUP BY host, zone ORDER BY host;

# Scale up manually (or use the demo script)
yugabyted start --base_dir ${DATA_PATH}/ybd4 --advertise_address 127.0.0.4 \
  --join 127.0.0.1 --cloud_location ybcloud.pandora.az1 \
  --fault_tolerance zone --background=true

# Connect to YSQL
ysqlsh -h 127.0.0.1

# Connect to YCQL
ycqlsh -h 127.0.0.1
```
