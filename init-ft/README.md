# Fault Tolerance & High Availability

Chaos engineering on a 6-node YugabyteDB cluster spread across 3 availability zones. Kill nodes, observe leader election and Raft re-replication, and verify zero data loss under continuous YSQL and YCQL load.

---

## Prerequisites

The devcontainer starts a **6-node cluster** (2 nodes × 3 AZs) with `fault_tolerance=zone`. Java 21 and `yb-sample-apps.jar` are installed automatically at container creation time.

---

## Starting the load generators

Once the cluster is ready, open the load generator shells from the VS Code **Terminal** menu:

| Task | Shell | What it runs |
|---|---|---|
| **Terminal → Run Task → `ysql-load`** | `ysql-load` | YSQL `SqlInserts` load generator |
| **Terminal → Run Task → `ycql-load`** | `ycql-load` | YCQL `CassandraKeyValue` load generator |
| **Terminal → Run Task → `az-fd`** | `az-fd` | Chaos engineering demo script |
| **Terminal → Run Task → `ft: start all`** | all three | Launches all shells in parallel |

Each task opens in its own **dedicated terminal panel** — you can observe metrics in `ysql-load` and `ycql-load` while running chaos experiments in `az-fd`.

---

## Running the chaos experiments

Once both load generators are running and showing steady throughput, use the `az-fd` shell:

```bash
cd init-ft && bash prompt.sh
```

The `prompt.sh` demo script walks through:
1. Observing data placement across zones via the yugabyted UI (`localhost:15433`)
2. Killing a node in one AZ — observe zero read/write interruption
3. Bringing the node back — observe automatic re-replication
4. Killing a second node — observe continued operation (RF=3, quorum intact)
5. Killing a third node in a second AZ — observe reduced availability

---

## Cluster topology

```
AZ1          AZ2          AZ3
127.0.0.1    127.0.0.2    127.0.0.3   ← initial 3-node quorum
127.0.0.4    127.0.0.5    127.0.0.6   ← scale-out nodes
```

All 6 nodes participate in Raft replication with `fault_tolerance=zone`.

---

## Useful commands

```bash
# Cluster status
yugabyted status

# Stop a node (simulate AZ failure)
yugabyted stop --base_dir ybdb/ybd3

# Restart it
yugabyted start --base_dir ybdb/ybd3 --advertise_address 127.0.0.3 \
  --cloud_location ybcloud.pandora.az3 --fault_tolerance zone --join 127.0.0.1 --background true

# Connect to YSQL
ysqlsh

# Connect to YCQL
ycqlsh
```
