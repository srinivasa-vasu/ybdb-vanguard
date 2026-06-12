#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# YugabyteDB Distributed SQL demo  —  "The Sharding Playbook"
#
# How YugabyteDB physically distributes data across tablets, and how schema
# choices (hash vs range, clustering key direction, index type) directly
# affect query performance.
#
#   Part 1 · Hash Sharding   — uniform writes, 1-RPC point lookup, scatter-gather range
#   Part 2 · Range Sharding  — ordered storage, efficient range scan, pre-split
#   Part 3 · Secondary Indexes — hash (2 RPC), covering (1 RPC), bucket
#   Part 4 · Tablet Metadata  — yb_table_properties, yb_local_tablets
#
# Pre-requisites (handled by postStartCommand):
#   - 3-node YugabyteDB cluster running on 127.0.0.1:5433
# ─────────────────────────────────────────────────────────────────────────────

. pscript
set -f  # disable filename expansion — prevents SELECT * glob-expanding in eval $@

TYPE_SPEED=40
NO_WAIT=false
DEMO_PROMPT="${GREEN}➜ ${CYAN}\W ${COLOR_RESET}"

clear

# ── Cleanup from any previous demo run ────────────────────────────────────
ysqlsh -h 127.0.0.1 -X -c "
DROP TABLE IF EXISTS
  dsql_users, dsql_sensor_readings,
  dsql_products, dsql_log_entries, dsql_events CASCADE;" 2>/dev/null || true

# ── Scene 1: Intro ─────────────────────────────────────────────────────────

p "=== YugabyteDB Distributed SQL: Hash & Range Sharding ==="
p ""
p "EXPLAIN (ANALYZE, DIST) shows 'Storage Table Read Requests' — the number of"
p "tablet round-trips. That is the key cost metric in a distributed system."
p ""
p "3-node cluster, one per availability zone:"

pe "ysqlsh -h 127.0.0.1 -X -c \"SELECT host, zone, node_type FROM yb_servers();\""

# ── Scene 2: Hash Sharding ─────────────────────────────────────────────────

p ""
p "=== Part 1: Hash Sharding ==="
p ""
p "-- 1.1 Single-column hash (default)"
p "A TEXT PRIMARY KEY is hash-sharded by default. YugabyteDB hashes the key"
p "to route each row to exactly one tablet."

pe "ysqlsh -h 127.0.0.1 -X -c \"
CREATE TABLE dsql_users (
  user_id    TEXT PRIMARY KEY,
  name       TEXT,
  region     TEXT,
  status     TEXT,
  created_at DATE
);
INSERT INTO dsql_users (user_id, name, region, status, created_at)
SELECT 'user-' || i,
       'User ' || i,
       (ARRAY['US','EU','APAC'])[1 + mod(i,3)],
       (ARRAY['Active','Pending'])[1 + mod(i,2)],
       CURRENT_DATE - (i || ' days')::INTERVAL
FROM generate_series(1, 100) AS i;\""

p ""
p "Point lookup: hash(user_id) → 1 tablet, 1 RPC:"

pe "ysqlsh -h 127.0.0.1 -X -c \"EXPLAIN (ANALYZE, DIST) SELECT * FROM dsql_users WHERE user_id = 'user-42';\""

p ""
p "Range scan: must scatter to ALL tablets — hash destroys key order:"

pe "ysqlsh -h 127.0.0.1 -X -c \"EXPLAIN (ANALYZE, DIST) SELECT * FROM dsql_users WHERE user_id > 'user-50';\""

p ""
p "-- 1.2 Hash + DESC clustering key (latest-N pattern)"
p "Hash routes to the right tablet; DESC stores newest entries first within it."
p "No ORDER BY sort step needed for the latest-N query pattern."

pe "ysqlsh -h 127.0.0.1 -X -c \"
CREATE TABLE dsql_sensor_readings (
  sensor_id  TEXT,
  ts         TIMESTAMP,
  value      FLOAT,
  unit       TEXT,
  PRIMARY KEY (sensor_id HASH, ts DESC)
);
INSERT INTO dsql_sensor_readings (sensor_id, ts, value, unit)
SELECT 'S-' || (100 + mod(i,5)),
       NOW() - (i || ' minutes')::INTERVAL,
       20.0 + random() * 10, '°C'
FROM generate_series(1, 500) AS i;\""

p ""
p "Latest 10 for sensor S-102 — ts DESC is the physical storage order, no Sort node:"

pe "ysqlsh -h 127.0.0.1 -X -c \"EXPLAIN (ANALYZE, DIST) SELECT * FROM dsql_sensor_readings WHERE sensor_id = 'S-102' LIMIT 10;\""

# ── Scene 3: Range Sharding ────────────────────────────────────────────────

p ""
p "=== Part 2: Range Sharding ==="
p ""
p "-- 2.1 Auto-split: PRIMARY KEY ASC stores rows in global sorted order."
p "Range scans touch only the tablet(s) covering the requested range."
p "ORDER BY on the PK is free — rows arrive in physical order, no Sort node."

pe "ysqlsh -h 127.0.0.1 -X -c \"
CREATE TABLE dsql_products (
  product_id  TEXT  PRIMARY KEY ASC,
  category    TEXT,
  price       DECIMAL,
  status      TEXT
);
INSERT INTO dsql_products (product_id, category, price, status)
SELECT 'prod-' || lpad(i::text, 4, '0'),
       (ARRAY['Electronics','Books','Home','Apparel'])[1 + mod(i,4)],
       (10 + i * 9.99)::DECIMAL,
       (ARRAY['In Stock','Low','Out'])[1 + mod(i,3)]
FROM generate_series(1, 200) AS i;\""

p ""
p "Range scan — only tablet(s) covering prod-0050..prod-0100 are accessed:"

pe "ysqlsh -h 127.0.0.1 -X -c \"EXPLAIN (ANALYZE, DIST) SELECT * FROM dsql_products WHERE product_id BETWEEN 'prod-0050' AND 'prod-0100';\""

p ""
p "ORDER BY product_id ASC — physical storage order, no Sort node:"

pe "ysqlsh -h 127.0.0.1 -X -c \"EXPLAIN (ANALYZE, DIST) SELECT * FROM dsql_products ORDER BY product_id ASC LIMIT 10;\""

p ""
p "-- 2.2 Pre-split: SPLIT AT VALUES pre-creates tablet boundaries."
p "No cold-start single-tablet hotspot for range-sharded tables."

pe "ysqlsh -h 127.0.0.1 -X -c \"
CREATE TABLE dsql_log_entries (
  log_date   DATE  NOT NULL,
  host       TEXT  NOT NULL,
  severity   TEXT  NOT NULL,
  message    TEXT,
  PRIMARY KEY (log_date ASC, host ASC)
) SPLIT AT VALUES (
    ('2025-01-01'), ('2025-04-01'), ('2025-07-01'), ('2025-10-01')
);\""

p ""
p "yb_table_properties: 5 tablets pre-created (4 boundaries + 1 leading shard):"

pe "ysqlsh -h 127.0.0.1 -X -c \"SELECT * FROM yb_table_properties('dsql_log_entries'::regclass);\""

pe "ysqlsh -h 127.0.0.1 -X -c \"
INSERT INTO dsql_log_entries (log_date, host, severity, message)
SELECT CURRENT_DATE - (random() * 364)::int,
       'host-' || (1 + (random() * 9)::int),
       (ARRAY['INFO','WARN','ERROR'])[1 + mod(i,3)],
       'Log entry ' || i
FROM generate_series(1, 1000) AS i;\""

p ""
p "Quarter-scoped query: only Q2 tablet accessed (Storage Read Requests = 1):"

pe "ysqlsh -h 127.0.0.1 -X -c \"EXPLAIN (ANALYZE, DIST) SELECT count(*) FROM dsql_log_entries WHERE log_date BETWEEN '2025-04-01' AND '2025-06-30';\""

# ── Scene 4: Secondary Indexes ─────────────────────────────────────────────

p ""
p "=== Part 3: Secondary Indexes ==="
p ""
p "-- 3.1 Hash index → 2-RPC path"
p "Secondary index is a separate tablet group. Lookup: index tablet → PK → main tablet."

pe "ysqlsh -h 127.0.0.1 -X -c \"
ALTER TABLE dsql_users ADD COLUMN email TEXT;
UPDATE dsql_users SET email = 'user' || substr(user_id,6) || '@example.com';\""

p ""
p "Without index: Seq Scan, high Storage Table Rows Scanned:"

pe "ysqlsh -h 127.0.0.1 -X -c \"EXPLAIN (ANALYZE, DIST) SELECT * FROM dsql_users WHERE email = 'user42@example.com';\""

pe "ysqlsh -h 127.0.0.1 -X -c \"CREATE INDEX idx_dsql_users_email ON dsql_users (email HASH);\""

p ""
p "With hash index: 2 Storage Read Requests (index tablet → main tablet):"

pe "ysqlsh -h 127.0.0.1 -X -c \"EXPLAIN (ANALYZE, DIST) SELECT * FROM dsql_users WHERE email = 'user42@example.com';\""

p ""
p "-- 3.3 Covering index (INCLUDE) → 1-RPC path"
p "Store projected columns in the index leaf. Eliminates the main-table fetch."

pe "ysqlsh -h 127.0.0.1 -X -c \"
CREATE INDEX idx_dsql_users_cover
  ON dsql_users (email HASH) INCLUDE (name, region);\""

p ""
p "Index-only scan: name + region served from index leaf (1 RPC, no heap fetch):"

pe "ysqlsh -h 127.0.0.1 -X -c \"EXPLAIN (ANALYZE, DIST) SELECT name, region FROM dsql_users WHERE email = 'user42@example.com';\""

p ""
p "SELECT *: still needs the main table — status, created_at not in INCLUDE:"

pe "ysqlsh -h 127.0.0.1 -X -c \"EXPLAIN (ANALYZE, DIST) SELECT * FROM dsql_users WHERE email = 'user42@example.com';\""

p ""
p "-- 3.6 Bucket index — hot-key mitigation for monotone columns"
p "A plain range index on a timestamp creates a permanent write hotspot on the last tablet."
p "Prepend (yb_hash_code(ts) % N) to spread inserts across N balanced tablets."

pe "ysqlsh -h 127.0.0.1 -X -c \"
CREATE TABLE dsql_events (
  event_id  TEXT PRIMARY KEY,
  ts        TIMESTAMPTZ,
  device_id TEXT,
  metric    TEXT,
  value     DECIMAL
);
CREATE INDEX idx_dsql_events_ts ON dsql_events (
    (yb_hash_code(ts) % 3) ASC, ts DESC
) INCLUDE (metric, value)
  SPLIT AT VALUES ((1), (2));
INSERT INTO dsql_events (event_id, ts, device_id, metric, value)
SELECT 'ev-' || i,
       NOW() - (i * 7 || ' days')::INTERVAL,
       (ARRAY['dev-A','dev-B','dev-C'])[1 + mod(i,3)],
       (ARRAY['cpu','mem','disk'])[1 + mod(i,3)],
       (20 + i * 5.5)::DECIMAL
FROM generate_series(1, 500) AS i;\""

p ""
p "Merge Append of 3 bucket sub-scans — writes and reads balanced across 3 tablets:"

pe "ysqlsh -h 127.0.0.1 -X -c \"EXPLAIN (ANALYZE, DIST) SELECT event_id, ts, metric, value FROM dsql_events WHERE ts BETWEEN NOW() - '30 days'::INTERVAL AND NOW() ORDER BY ts DESC LIMIT 50;\""

# ── Scene 5: Tablet Metadata ───────────────────────────────────────────────

p ""
p "=== Part 4: Tablet Metadata ==="
p ""
p "yb_table_properties: num_tablets, hash vs range, colocation"

pe "ysqlsh -h 127.0.0.1 -X -c \"
SELECT c.relname AS table_name,
       p.num_tablets,
       p.num_hash_key_columns,
       p.is_colocated
FROM   pg_class c, yb_table_properties(c.oid) p
WHERE  c.relnamespace = 'public'::regnamespace
  AND  c.relkind = 'r'
  AND  c.relname LIKE 'dsql_%'
ORDER  BY c.relname;\""

p ""
p "yb_local_tablets: tablets on this node and their assigned tables:"

pe "ysqlsh -h 127.0.0.1 -X -c \"SELECT tablet_id, table_name FROM yb_local_tablets WHERE table_name LIKE 'dsql_%' LIMIT 20;\""

# ── Cleanup + Summary ──────────────────────────────────────────────────────

p ""
p "--- Cleanup ---"

pe "ysqlsh -h 127.0.0.1 -X -c \"
DROP TABLE IF EXISTS
  dsql_users, dsql_sensor_readings, dsql_products,
  dsql_log_entries, dsql_events CASCADE;\""

p ""
p "=== Summary: Sharding Cheat Sheet ==="
p ""
p "Hash sharding (default):"
p "  PRIMARY KEY (id)               → uniform writes, O(1) point lookup, scatter for ranges"
p "  PRIMARY KEY (id HASH, ts DESC)  → hash-route by entity + newest-first within tablet"
p ""
p "Range sharding:"
p "  PRIMARY KEY (id ASC)           → efficient range scans + free ORDER BY; hotspot risk"
p "  SPLIT AT VALUES (...)          → pre-create boundaries; no cold-start hotspot"
p ""
p "Secondary index types:"
p "  Hash index                     → 2 RPCs (index tablet + main tablet)"
p "  INCLUDE (col, ...)             → 1 RPC (index-only scan)"
p "  (yb_hash_code(ts) % N) bucket  → spread monotone-key writes, no hotspot"
p ""
p "Key EXPLAIN metric: 'Storage Table Read Requests' = tablet round-trips"

cmd

p ""
