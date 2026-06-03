#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# YugabyteDB Geo-distribution demo  —  "The Global Banking Platform"
#
# Scenario: A fintech company operates in three regions (US East, EU West,
# AP South). EU regulations require customer data to stay within EU borders.
# US and APAC have similar residency requirements. Using YugabyteDB tablespaces
# and row-level geo-partitioning, they enforce data residency in SQL — no
# application-level routing needed.
#
# Pre-requisites (handled by postStartCommand):
#   - 3-node cluster: 127.0.0.1 (us-east) / 127.0.0.2 (eu-west) / 127.0.0.3 (ap-south)
#   - yugabyted configure data_placement --fault_tolerance=region already run
#   - pscript (demo-magic) downloaded
# ─────────────────────────────────────────────────────────────────────────────

. pscript

TYPE_SPEED=35
NO_WAIT=false
DEMO_PROMPT="${GREEN}➜ ${CYAN}\W ${COLOR_RESET}"

clear

# ── Quiet cleanup: drop objects from a previous run ───────────────────────────
ysqlsh -h 127.0.0.1 -c "DROP TABLE IF EXISTS bank_txns CASCADE;" 2>/dev/null || true
ysqlsh -h 127.0.0.1 -c "DROP TABLESPACE IF EXISTS us_east_ts;" 2>/dev/null || true
ysqlsh -h 127.0.0.1 -c "DROP TABLESPACE IF EXISTS eu_west_ts;" 2>/dev/null || true
ysqlsh -h 127.0.0.1 -c "DROP TABLESPACE IF EXISTS ap_south_ts;" 2>/dev/null || true

# ── Scene 1: Show the multi-region topology ───────────────────────────────────

p "=== 'The Global Banking Platform' ==="
p ""
p "Three-node cluster simulating three geographic regions:"

pe "ysqlsh -h 127.0.0.1 -c \"SELECT host, cloud, region, zone, node_type FROM yb_servers() ORDER BY region;\""

p "Each IP maps to a real region. Tablespaces will pin data to these regions."

# ── Scene 2: Create tablespaces ───────────────────────────────────────────────

p ""
p "--- Step 1: Create region-specific tablespaces ---"
p "replica_placement JSON ties a tablespace to a cloud/region/zone."

pe "ysqlsh -h 127.0.0.1 -c \"CREATE TABLESPACE us_east_ts WITH (replica_placement = '{\\\"num_replicas\\\": 1, \\\"placement_blocks\\\": [{\\\"cloud\\\":\\\"ybcloud\\\",\\\"region\\\":\\\"us-east\\\",\\\"zone\\\":\\\"us-east-az1\\\",\\\"min_num_replicas\\\":1}]}');\""

pe "ysqlsh -h 127.0.0.1 -c \"CREATE TABLESPACE eu_west_ts WITH (replica_placement = '{\\\"num_replicas\\\": 1, \\\"placement_blocks\\\": [{\\\"cloud\\\":\\\"ybcloud\\\",\\\"region\\\":\\\"eu-west\\\",\\\"zone\\\":\\\"eu-west-az1\\\",\\\"min_num_replicas\\\":1}]}');\""

pe "ysqlsh -h 127.0.0.1 -c \"CREATE TABLESPACE ap_south_ts WITH (replica_placement = '{\\\"num_replicas\\\": 1, \\\"placement_blocks\\\": [{\\\"cloud\\\":\\\"ybcloud\\\",\\\"region\\\":\\\"ap-south\\\",\\\"zone\\\":\\\"ap-south-az1\\\",\\\"min_num_replicas\\\":1}]}');\""

pe "ysqlsh -h 127.0.0.1 -c \"SELECT spcname AS tablespace FROM pg_tablespace WHERE spcname NOT IN ('pg_default','pg_global') ORDER BY spcname;\""

# ── Scene 3: Geo-partitioned table ────────────────────────────────────────────

p ""
p "--- Step 2: Geo-partitioned transactions table ---"
p "One parent table. Each partition is pinned to its region's tablespace."

pe "ysqlsh -h 127.0.0.1 -c \"
CREATE TABLE bank_txns (
  txn_id   BIGSERIAL  NOT NULL,
  region   TEXT       NOT NULL,
  customer TEXT       NOT NULL,
  amount   NUMERIC(12,2) NOT NULL,
  txn_type TEXT       NOT NULL,
  ts       TIMESTAMPTZ NOT NULL DEFAULT now()
) PARTITION BY LIST (region);\""

pe "ysqlsh -h 127.0.0.1 -c \"
CREATE TABLE bank_txns_us PARTITION OF bank_txns
  (txn_id, region, customer, amount, txn_type, ts,
   PRIMARY KEY (txn_id HASH, region))
  FOR VALUES IN ('US') TABLESPACE us_east_ts;\""

pe "ysqlsh -h 127.0.0.1 -c \"
CREATE TABLE bank_txns_eu PARTITION OF bank_txns
  (txn_id, region, customer, amount, txn_type, ts,
   PRIMARY KEY (txn_id HASH, region))
  FOR VALUES IN ('EU') TABLESPACE eu_west_ts;\""

pe "ysqlsh -h 127.0.0.1 -c \"
CREATE TABLE bank_txns_ap PARTITION OF bank_txns
  (txn_id, region, customer, amount, txn_type, ts,
   PRIMARY KEY (txn_id HASH, region))
  FOR VALUES IN ('AP') TABLESPACE ap_south_ts;\""

# ── Scene 4: Insert and verify routing ────────────────────────────────────────

p ""
p "--- Step 3: Routing is automatic — app just sets the region column ---"

pe "ysqlsh -h 127.0.0.1 -c \"INSERT INTO bank_txns (region, customer, amount, txn_type) VALUES
  ('EU', 'Lars Eriksson',  2500.00, 'transfer'),
  ('EU', 'Marie Dupont',    850.00, 'payment'),
  ('US', 'Alice Johnson', 1200.00, 'deposit'),
  ('US', 'Bob Williams',   430.00, 'payment'),
  ('AP', 'Priya Sharma',   950.00, 'transfer');\""

pe "ysqlsh -h 127.0.0.1 -c \"SELECT tableoid::regclass AS partition, region, customer, amount FROM bank_txns ORDER BY region, customer;\""

p "Every EU row landed in bank_txns_eu. No application-level routing needed."

# ── Scene 5: Verify tablet leaders confirm data residency ────────────────────

p ""
p "--- Step 4: Verify tablet leaders are in the right region ---"

pe "ysqlsh -h 127.0.0.1 -c \"
SELECT tm.relname AS partition, sv.region, sv.zone, tm.leader
FROM yb_tablet_metadata tm
JOIN yb_servers() sv ON tm.leader LIKE sv.host || '%'
WHERE tm.db_name = current_database()
  AND tm.relname LIKE 'bank_txns%'
ORDER BY tm.relname;\""

p "bank_txns_eu leader is on 127.0.0.2 (eu-west). EU data never leaves EU."

# ── Scene 6: EXPLAIN confirms partition pruning ───────────────────────────────

p ""
p "--- Step 5: Partition pruning — only the EU partition is scanned ---"

pe "ysqlsh -h 127.0.0.1 -c \"EXPLAIN SELECT * FROM bank_txns WHERE region = 'EU';\""

p "Seq Scan on bank_txns_eu only. The US and AP partitions are not touched."

# ── Scene 7: Local table reads ────────────────────────────────────────────────

p ""
p "--- Step 6: yb_is_local_table — read only what's local to this node ---"

pe "ysqlsh -h 127.0.0.1 -c \"SELECT region, customer, amount FROM bank_txns WHERE yb_is_local_table(tableoid) ORDER BY region, customer;\""

p "Returns only the partition whose leader is on the connected node."
p "In production, each region's app server connects to its local node."

# ── Scene 8: Preferred zones ──────────────────────────────────────────────────

p ""
p "--- Step 7: Preferred zones — pin tablet leaders to a specific region ---"
p "Useful when one region handles most writes and you want low-latency leaders."

pe "yb-admin --master_addresses ${MASTERS} set_preferred_zones ybcloud.us-east.us-east-az1"

sleep 3

pe "ysqlsh -h 127.0.0.1 -c \"
SELECT tm.relname, sv.region, sv.zone, COUNT(*) AS leader_count
FROM yb_tablet_metadata tm
JOIN yb_servers() sv ON tm.leader LIKE sv.host || '%'
WHERE tm.db_name = current_database()
GROUP BY tm.relname, sv.region, sv.zone
ORDER BY leader_count DESC LIMIT 10;\""

p "Tablet leaders migrate toward us-east. Revert with: set_preferred_zones (empty)."

# ── Scene 9: Follower reads ───────────────────────────────────────────────────

p ""
p "--- Step 8: Follower reads — serve reads from the nearest replica ---"
p "Ideal for analytics queries where a few seconds of staleness is acceptable."

pe "ysqlsh -h 127.0.0.1 -c \"
BEGIN;
SET TRANSACTION READ ONLY;
SET LOCAL yb_read_from_followers = true;
SET LOCAL yb_follower_read_staleness_ms = 10000;
SELECT region, COUNT(*) AS txns, ROUND(SUM(amount),2) AS total
FROM bank_txns GROUP BY region ORDER BY region;
COMMIT;\""

p "Served from the nearest follower replica — reduced latency, bounded staleness."

# ── Wrap up ───────────────────────────────────────────────────────────────────

p ""
p "=== Geo-distribution in YugabyteDB — no middleware, pure SQL ==="
p ""
p "  Tablespace      → pin a table or index to a specific cloud/region/zone"
p "  Geo-partition   → per-row residency via LIST partition + tablespace"
p "  Leader pref     → yb-admin set_preferred_zones for low-latency writes"
p "  Follower reads  → SET yb_read_from_followers = true (read-only session)"
p "  Local reads     → WHERE yb_is_local_table(tableoid)"

cmd
p ""
