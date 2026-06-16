#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# YugabyteDB Tablespace demo  —  "The Data Tier Migration"
#
# Scenario: An app starts with all tables in the default tablespace.
# As it grows, the team decides to pin hot/active data to the US-East node
# for lower latency, and age cold/archive data to EU-West. They also need
# to move an existing table and its indexes to a new tablespace online —
# without downtime.
#
# Cluster: 3 nodes with distinct region labels (same as geo exercise)
#   127.0.0.1  ybcloud.us-east.us-east-az1
#   127.0.0.2  ybcloud.eu-west.eu-west-az1
#   127.0.0.3  ybcloud.ap-south.ap-south-az1
#
# APIs demonstrated (all GA):
#   CREATE TABLESPACE ... WITH (replica_placement = '...')
#   CREATE TABLE      ... TABLESPACE <name>
#   CREATE INDEX      ... TABLESPACE <name>
#   ALTER  TABLE      ... SET TABLESPACE <name>   -- online move
#   ALTER  INDEX      ... SET TABLESPACE <name>
#   SET default_tablespace TO <name>              -- session default
#   pg_tables, pg_tablespace                      -- inspect placement
#
# NOTE: colocation + tablespace requires the Early Access flag
#   --ysql_enable_colocated_tables_with_tablespaces=true
# and is not demonstrated here.
# ─────────────────────────────────────────────────────────────────────────────

. pscript

TYPE_SPEED=40
NO_WAIT=false
# Each `pe` normally pauses TWICE (before typing the command, and again before
# running it). This removes the first pause so the command types out as soon as
# you reach it; you then press Enter ONCE to run it. One pause per step.
NO_WAIT_DISPLAY_CMD=true
DEMO_PROMPT="${GREEN}➜ ${CYAN}\W ${COLOR_RESET}"

clear

# ── Quiet setup: drop any leftover tables and tablespaces from a previous run ─
ysqlsh -h 127.0.0.1 -c "
  DROP TABLE IF EXISTS orders, orders_archive, products, audit_log CASCADE;
  DROP TABLESPACE IF EXISTS us_east_ts;
  DROP TABLESPACE IF EXISTS eu_west_ts;
  DROP TABLESPACE IF EXISTS ap_south_ts;
" 2>/dev/null || true

p "=== YugabyteDB Tablespaces: Placement & Online Data Migration ==="
p ""
p "Cluster: 3 nodes across us-east · eu-west · ap-south"
p "Goal: create placement-aware tablespaces and migrate data between them online."

# ─────────────────────────────────────────────────────────────────────────────
# PART 1: Inspect the cluster nodes and their placement labels
# ─────────────────────────────────────────────────────────────────────────────

p ""
p "━━━ Part 1: Cluster Node Placement Labels ━━━"
p ""
p "Each node has a cloud.region.zone label used by replica_placement."

pe "ysqlsh -h 127.0.0.1 -c \"
SELECT host, port, cloud, region, zone, node_type
FROM   yb_servers()
ORDER  BY region;\""

# ─────────────────────────────────────────────────────────────────────────────
# PART 2: Create placement-aware tablespaces
# ─────────────────────────────────────────────────────────────────────────────

p ""
p "━━━ Part 2: Create Tablespaces ━━━"
p ""
p "Each tablespace pins its tablets to a specific region."
p "replica_placement JSON specifies cloud, region, zone and min_num_replicas."

pe "ysqlsh -h 127.0.0.1 -c \"
CREATE TABLESPACE us_east_ts WITH (
  replica_placement = '{
    \\\"num_replicas\\\": 1,
    \\\"placement_blocks\\\": [{
      \\\"cloud\\\": \\\"ybcloud\\\",
      \\\"region\\\": \\\"us-east\\\",
      \\\"zone\\\": \\\"us-east-az1\\\",
      \\\"min_num_replicas\\\": 1
    }]
  }'
);\""

pe "ysqlsh -h 127.0.0.1 -c \"
CREATE TABLESPACE eu_west_ts WITH (
  replica_placement = '{
    \\\"num_replicas\\\": 1,
    \\\"placement_blocks\\\": [{
      \\\"cloud\\\": \\\"ybcloud\\\",
      \\\"region\\\": \\\"eu-west\\\",
      \\\"zone\\\": \\\"eu-west-az1\\\",
      \\\"min_num_replicas\\\": 1
    }]
  }'
);\""

pe "ysqlsh -h 127.0.0.1 -c \"
CREATE TABLESPACE ap_south_ts WITH (
  replica_placement = '{
    \\\"num_replicas\\\": 1,
    \\\"placement_blocks\\\": [{
      \\\"cloud\\\": \\\"ybcloud\\\",
      \\\"region\\\": \\\"ap-south\\\",
      \\\"zone\\\": \\\"ap-south-az1\\\",
      \\\"min_num_replicas\\\": 1
    }]
  }'
);\""

p ""
p "--- Verify tablespaces ---"

pe "ysqlsh -h 127.0.0.1 -c \"
SELECT spcname                                       AS tablespace,
       spcoptions::text                             AS placement
FROM   pg_tablespace
WHERE  spcname NOT IN ('pg_default','pg_global')
ORDER  BY spcname;\""

# ─────────────────────────────────────────────────────────────────────────────
# PART 3: Create tables pinned to specific tablespaces
# ─────────────────────────────────────────────────────────────────────────────

p ""
p "━━━ Part 3: Create Tables in Specific Tablespaces ━━━"
p ""
p "Append TABLESPACE <name> to CREATE TABLE to pin it at creation time."

pe "ysqlsh -h 127.0.0.1 -c \"
-- Active orders: pinned to US East for low-latency reads
CREATE TABLE orders (
  id         BIGSERIAL PRIMARY KEY,
  customer   TEXT      NOT NULL,
  amount     NUMERIC,
  status     TEXT      DEFAULT 'active',
  created_at TIMESTAMPTZ DEFAULT NOW()
) TABLESPACE us_east_ts;

-- Archived orders: cold data pinned to EU West
CREATE TABLE orders_archive (
  LIKE orders INCLUDING ALL
) TABLESPACE eu_west_ts;

-- Product catalog: APAC serving, pinned to AP South
CREATE TABLE products (
  id    SERIAL PRIMARY KEY,
  name  TEXT   NOT NULL,
  price NUMERIC
) TABLESPACE ap_south_ts;\""

p ""
p "--- Table → tablespace assignments ---"

pe "ysqlsh -h 127.0.0.1 -c \"
SELECT tablename, tablespace
FROM   pg_tables
WHERE  schemaname = 'public'
ORDER  BY tablename;\""

p ""
p "--- Index tablespace assignments ---"

pe "ysqlsh -h 127.0.0.1 -c \"
SELECT indexname, tablespace
FROM   pg_indexes
WHERE  schemaname = 'public'
ORDER  BY indexname;\""

p "Indexes inherit the table's tablespace when created with the table."

# ─────────────────────────────────────────────────────────────────────────────
# PART 4: Seed data
# ─────────────────────────────────────────────────────────────────────────────

p ""
p "━━━ Part 4: Seed Data ━━━"

(set -f; pe "ysqlsh -h 127.0.0.1 -c \"
INSERT INTO products(name, price)
VALUES ('Laptop',999),('Phone',599),('Tablet',399),('Watch',199);

INSERT INTO orders(customer, amount, status)
SELECT 'Customer ' || i,
       (50 + mod(i,950))::numeric,
       CASE WHEN mod(i,10)=0 THEN 'archived' ELSE 'active' END
FROM generate_series(1, 500) i;\"")

pe "ysqlsh -h 127.0.0.1 -c \"
SELECT status, COUNT(*), ROUND(SUM(amount),2) AS total
FROM   orders
GROUP  BY status;\""

# ─────────────────────────────────────────────────────────────────────────────
# PART 5: Online tablespace migration — ALTER TABLE SET TABLESPACE
# ─────────────────────────────────────────────────────────────────────────────

p ""
p "━━━ Part 5: Online Tablespace Migration ━━━"
p ""
p "Move an existing table to a different tablespace WITHOUT downtime."
p "ALTER TABLE SET TABLESPACE is non-blocking: the config changes immediately"
p "and tablet rebalancing happens in the background."

p ""
p "Move the products catalog from ap_south_ts → us_east_ts:"

pe "ysqlsh -h 127.0.0.1 -c \"ALTER TABLE products SET TABLESPACE us_east_ts;\""

p "Move the PRIMARY KEY index separately to match:"

pe "ysqlsh -h 127.0.0.1 -c \"ALTER INDEX products_pkey SET TABLESPACE us_east_ts;\""

p ""
p "--- Verify: products and its index are now on us_east_ts ---"

pe "ysqlsh -h 127.0.0.1 -c \"
SELECT t.tablename, t.tablespace AS table_ts,
       i.indexname, i.tablespace AS index_ts
FROM   pg_tables  t
JOIN   pg_indexes i ON i.tablename = t.tablename
WHERE  t.schemaname = 'public'
  AND  t.tablename  = 'products';\""

p ""
p "--- Full picture after migration ---"

pe "ysqlsh -h 127.0.0.1 -c \"
SELECT tablename, tablespace
FROM   pg_tables
WHERE  schemaname = 'public'
ORDER  BY tablename;\""

# ─────────────────────────────────────────────────────────────────────────────
# PART 6: Session default tablespace
# ─────────────────────────────────────────────────────────────────────────────

p ""
p "━━━ Part 6: Session default_tablespace ━━━"
p ""
p "SET default_tablespace TO <name> makes all subsequent CREATE TABLE/INDEX"
p "in the session land on that tablespace unless overridden."

pe "ysqlsh -h 127.0.0.1 -c \"
SET default_tablespace TO eu_west_ts;
SHOW default_tablespace;
CREATE TABLE audit_log (
  id         BIGSERIAL PRIMARY KEY,
  action     TEXT,
  actor      TEXT,
  logged_at  TIMESTAMPTZ DEFAULT NOW()
);
RESET default_tablespace;
SELECT tablename, tablespace FROM pg_tables
WHERE  schemaname = 'public' AND tablename = 'audit_log';\""

p "audit_log landed on eu_west_ts because of the session default."
p "RESET default_tablespace restores pg_default for the rest of the session."

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────

p ""
p "━━━ Summary ━━━"
p ""
p "  CREATE TABLESPACE ts WITH (replica_placement = '{...}')    pin to region/zone"
p "  CREATE TABLE t (...) TABLESPACE ts                          place at creation"
p "  ALTER  TABLE t SET TABLESPACE ts                            online move (async)"
p "  ALTER  INDEX i SET TABLESPACE ts                            move index too"
p "  SET    default_tablespace TO ts                             session default"
p ""
p "  Inspect:  SELECT tablename, tablespace FROM pg_tables;"
p "            SELECT indexname, tablespace FROM pg_indexes;"
p "            SELECT spcname, spcoptions FROM pg_tablespace;"
p ""
p "  NOTE: colocation + tablespace is an Early Access feature."
p "        Enable with: --ysql_enable_colocated_tables_with_tablespaces=true"

cmd

p ""
