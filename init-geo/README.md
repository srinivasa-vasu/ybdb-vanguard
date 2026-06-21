# Geo-distribution & Tablespaces

[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/srinivasa-vasu/ybdb-vanguard?devcontainer_path=.devcontainer%2Finit-geo%2Fdevcontainer.json)

Multi-region data placement, row-level data residency, and low-latency follower reads on a YugabyteDB 3-node cluster simulating three geographic regions on a single machine.

---

> **Run queries interactively**: Select any SQL block → **`Ctrl+Shift+Enter`** (Windows/Linux) or **`Cmd+Shift+Enter`** (Mac) → runs in the active terminal.

---

## Cluster topology

| Node | IP | Region | Zone |
|---|---|---|---|
| 1 | `127.0.0.1` | `us-east` | `us-east-az1` |
| 2 | `127.0.0.2` | `eu-west` | `eu-west-az1` |
| 3 | `127.0.0.3` | `ap-south` | `ap-south-az1` |

`cloud_location` format: `ybcloud.<region>.<zone>`

`yugabyted configure data_placement --fault_tolerance=region` is run at startup to enable region-level placement policies and tablespace enforcement.

---

## Prerequisites

The devcontainer starts the 3-node multi-region cluster automatically via `start-geo.sh`. All exercises are self-contained.

Connect with:
```bash
ysqlsh
```

---

## Running the demo

| Task | What it runs |
|---|---|
| **Terminal → Run Task → `geo-demo`** | "The Global Banking Platform" (`prompt.sh`) |
| **Terminal → Run Task → `ysql`** | YSQL shell for the Workshop section below |

The demo covers: tablespace creation → geo-partitioned table → automatic partition routing → tablet leader verification → preferred zones → follower reads.

---

## Workshop

> Use the **`ysql`** terminal — it opens automatically when the container starts.

### Part 1 · Verify cluster topology

```sql
-- Nodes with cloud/region/zone
SELECT host, cloud, region, zone, node_type FROM yb_servers() ORDER BY region;

-- Tablet leader distribution across regions
SELECT tm.leader, sv.zone, COUNT(*) AS tablet_count
FROM yb_tablet_metadata tm
JOIN yb_servers() sv ON tm.leader LIKE sv.host || '%'
GROUP BY tm.leader, sv.zone ORDER BY tablet_count DESC;
```

---

### Part 2 · Tablespaces: pinning data to regions

A **tablespace** binds a table or index to a specific placement via `replica_placement` JSON.

```sql
-- One replica in US East (production: use num_replicas=3 with 3 nodes per region)
CREATE TABLESPACE us_east_ts WITH (
  replica_placement = '{"num_replicas": 1, "placement_blocks": [
    {"cloud":"ybcloud","region":"us-east","zone":"us-east-az1","min_num_replicas":1}
  ]}'
);

-- EU West (GDPR residency)
CREATE TABLESPACE eu_west_ts WITH (
  replica_placement = '{"num_replicas": 1, "placement_blocks": [
    {"cloud":"ybcloud","region":"eu-west","zone":"eu-west-az1","min_num_replicas":1}
  ]}'
);

-- AP South
CREATE TABLESPACE ap_south_ts WITH (
  replica_placement = '{"num_replicas": 1, "placement_blocks": [
    {"cloud":"ybcloud","region":"ap-south","zone":"ap-south-az1","min_num_replicas":1}
  ]}'
);

-- Global: one replica per region, RF=3
CREATE TABLESPACE global_ts WITH (
  replica_placement = '{"num_replicas": 3, "placement_blocks": [
    {"cloud":"ybcloud","region":"us-east","zone":"us-east-az1","min_num_replicas":1},
    {"cloud":"ybcloud","region":"eu-west","zone":"eu-west-az1","min_num_replicas":1},
    {"cloud":"ybcloud","region":"ap-south","zone":"ap-south-az1","min_num_replicas":1}
  ]}'
);
```

With `leader_preference` to bias reads and writes toward a region:
```sql
CREATE TABLESPACE us_primary_ts WITH (
  replica_placement = '{"num_replicas": 3, "placement_blocks": [
    {"cloud":"ybcloud","region":"us-east","zone":"us-east-az1","min_num_replicas":1,"leader_preference":1},
    {"cloud":"ybcloud","region":"eu-west","zone":"eu-west-az1","min_num_replicas":1,"leader_preference":2},
    {"cloud":"ybcloud","region":"ap-south","zone":"ap-south-az1","min_num_replicas":1}
  ]}'
);
```

#### Create region-pinned table and index

```sql
CREATE TABLE orders_eu (
    order_id   BIGSERIAL PRIMARY KEY,
    customer   TEXT NOT NULL,
    amount     NUMERIC(10,2) NOT NULL
) TABLESPACE eu_west_ts SPLIT INTO 1 TABLETS;

-- Index lives in the same region as the table
CREATE INDEX idx_orders_eu_customer ON orders_eu(customer) TABLESPACE eu_west_ts;

-- Move an existing table to a different tablespace
ALTER TABLE some_table SET TABLESPACE eu_west_ts;
```

#### Inspect tablespace assignments

```sql
-- All defined tablespaces
SELECT spcname, spcoptions FROM pg_tablespace
WHERE spcname NOT IN ('pg_default', 'pg_global');

-- Tablespace per table/index
SELECT c.relname, c.relkind, COALESCE(t.spcname, 'pg_default') AS tablespace
FROM pg_class c
LEFT JOIN pg_tablespace t ON c.reltablespace = t.oid
WHERE c.relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public')
ORDER BY tablespace, c.relkind, c.relname;
```

---

### Part 3 · Row-level geo-partitioning

Combine `PARTITION BY LIST` with per-partition `TABLESPACE` to enforce data residency at the row level.

```sql
-- Parent table (no tablespace = default)
CREATE TABLE bank_txns (
    txn_id   BIGSERIAL    NOT NULL,
    region   TEXT         NOT NULL,   -- partition key
    customer TEXT         NOT NULL,
    amount   NUMERIC(12,2) NOT NULL,
    txn_type TEXT         NOT NULL,
    ts       TIMESTAMPTZ  NOT NULL DEFAULT now()
) PARTITION BY LIST (region);

-- EU partition — GDPR: all data stays in eu-west
CREATE TABLE bank_txns_eu
    PARTITION OF bank_txns (
        txn_id, region, customer, amount, txn_type, ts,
        PRIMARY KEY (txn_id HASH, region)
    )
    FOR VALUES IN ('EU')
    TABLESPACE eu_west_ts;

CREATE INDEX ON bank_txns_eu (customer) TABLESPACE eu_west_ts;

-- US partition
CREATE TABLE bank_txns_us
    PARTITION OF bank_txns (
        txn_id, region, customer, amount, txn_type, ts,
        PRIMARY KEY (txn_id HASH, region)
    )
    FOR VALUES IN ('US')
    TABLESPACE us_east_ts;

-- AP partition
CREATE TABLE bank_txns_ap
    PARTITION OF bank_txns (
        txn_id, region, customer, amount, txn_type, ts,
        PRIMARY KEY (txn_id HASH, region)
    )
    FOR VALUES IN ('AP')
    TABLESPACE ap_south_ts;
```

**Insert** — partition routing is transparent to the application:
```sql
INSERT INTO bank_txns (region, customer, amount, txn_type)
VALUES ('EU', 'Lars Eriksson', 2500.00, 'transfer');
-- → automatically goes to bank_txns_eu (eu-west node)
```

**Verify** EXPLAIN confirms partition pruning:
```sql
EXPLAIN SELECT * FROM bank_txns WHERE region = 'EU';
-- → Seq Scan on bank_txns_eu   (only the EU partition is scanned)
```

**Add a new region** at runtime — no downtime:
```sql
CREATE TABLE bank_txns_latam
    PARTITION OF bank_txns (
        txn_id, region, customer, amount, txn_type, ts,
        PRIMARY KEY (txn_id HASH, region)
    )
    FOR VALUES IN ('LATAM')
    TABLESPACE us_east_ts;   -- or a dedicated latam tablespace
```

---

### Part 4 · Local table reads (`yb_is_local_table`)

```sql
-- Returns only rows whose partition tablet leader is on this connected node
SELECT region, customer, amount
FROM bank_txns
WHERE yb_is_local_table(tableoid)
ORDER BY region;
```

In production: each region's application server connects to its local YugabyteDB node, and `yb_is_local_table` ensures reads never fan out to remote nodes.

---

### Part 5 · Preferred zones: controlling leader placement

Leaders handle all writes and strong reads. Pinning leaders to a preferred zone reduces latency for that region's workload.

```bash
# Make us-east the primary leader zone
yb-admin --master_addresses 127.0.0.1:7100,127.0.0.2:7100,127.0.0.3:7100 \
  set_preferred_zones ybcloud.us-east.us-east-az1

# Multi-tier preference: us-east primary, eu-west secondary
yb-admin --master_addresses 127.0.0.1:7100,127.0.0.2:7100,127.0.0.3:7100 \
  set_preferred_zones \
    ybcloud.us-east.us-east-az1:1 \
    ybcloud.eu-west.eu-west-az1:2

# Verify leader distribution after setting preference
```

```sql
SELECT tm.relname, sv.region, sv.zone, COUNT(*) AS leaders
FROM yb_tablet_metadata tm
JOIN yb_servers() sv ON tm.leader LIKE sv.host || '%'
WHERE tm.db_name = current_database()
GROUP BY tm.relname, sv.region, sv.zone
ORDER BY leaders DESC;
```

---

### Part 6 · Follower reads: low-latency stale reads

Follower reads serve reads from the nearest replica rather than the leader, trading a small staleness window for lower latency.

```sql
-- Enable follower reads for the current session (must be read-only)
SET yb_read_from_followers = true;
SET yb_follower_read_staleness_ms = 10000;   -- 10-second staleness window
SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY;

SELECT region, COUNT(*), ROUND(SUM(amount), 2)
FROM bank_txns GROUP BY region;

-- Reset
SET SESSION CHARACTERISTICS AS TRANSACTION READ WRITE;
SET yb_read_from_followers = false;
```

**Within a single transaction:**
```sql
BEGIN;
SET TRANSACTION READ ONLY;
SET LOCAL yb_read_from_followers = true;
SET LOCAL yb_follower_read_staleness_ms = 5000;
SELECT * FROM bank_txns WHERE region = 'EU' LIMIT 20;
COMMIT;
```

| Parameter | Default | Notes |
|---|---|---|
| `yb_read_from_followers` | `false` | Must be `true` to enable |
| `yb_follower_read_staleness_ms` | `30000` (30s) | Minimum: ~2× `raft_heartbeat_interval_ms` |
| Transaction must be | read-only | `SET TRANSACTION READ ONLY` or `BEGIN READ ONLY` |

---

## Key mental models

```
Tablespace
  replica_placement JSON → maps num_replicas to cloud/region/zone blocks
  table IN TABLESPACE    → all tablets for that table placed in matching nodes
  index IN TABLESPACE    → index tablets co-located with data (no cross-region index lookup)
  ALTER TABLE SET        → move existing table to a different tablespace

Geo-partitioning
  PARTITION BY LIST (region)           → route rows by a discriminator column
  partition FOR VALUES IN ('EU') TABLESPACE eu_west_ts  → data stays in EU
  transparent routing                  → INSERT uses the region value, no app logic needed
  yb_is_local_table(tableoid)          → filter to only rows whose leader is on this node
  EXPLAIN shows partition pruning      → WHERE region = 'EU' scans only bank_txns_eu

Leader preference
  set_preferred_zones region:priority  → bias tablet leaders toward preferred zones
  priority 1 = first choice, 2 = secondary fallback

Follower reads
  yb_read_from_followers = true        → session-level opt-in
  yb_follower_read_staleness_ms        → how stale reads can be (default 30s)
  transaction must be READ ONLY        → follower reads rejected in read-write transactions
  use case                             → analytics, dashboards, non-critical lookups
```

---

## Useful commands

```sql
-- View all tablespaces
SELECT spcname, spcoptions FROM pg_tablespace;

-- View tablet placement (cluster-wide)
SELECT relname, leader, start_hash_code, end_hash_code FROM yb_tablet_metadata
WHERE db_name = current_database() ORDER BY relname;

-- Node topology
SELECT host, cloud, region, zone, node_type FROM yb_servers();
```

```bash
# Set preferred leader zone
yb-admin --master_addresses 127.0.0.1:7100,127.0.0.2:7100,127.0.0.3:7100 \
  set_preferred_zones ybcloud.<region>.<zone>

# Check cluster placement status
yugabyted status

# Connect to YSQL
ysqlsh
```
