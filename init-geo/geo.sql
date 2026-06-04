-- ═════════════════════════════════════════════════════════════════════════════
-- geo.sql  —  YugabyteDB Geo-distribution & Tablespaces
--
-- Load the full file:  \i init-geo/geo.sql
-- Or paste individual blocks interactively.
--
-- Cluster topology (3 nodes on loopback IPs):
--   127.0.0.1  ybcloud.us-east.us-east-az1   (US East)
--   127.0.0.2  ybcloud.eu-west.eu-west-az1   (EU West)
--   127.0.0.3  ybcloud.ap-south.ap-south-az1 (AP South)
-- ═════════════════════════════════════════════════════════════════════════════
-- ── Active cleanup: drop any leftover tables and tablespaces from previous runs ──
DROP TABLE IF EXISTS global_orders CASCADE;
DROP TABLE IF EXISTS orders_us, orders_eu, orders_ap, products CASCADE;
DROP TABLESPACE IF EXISTS us_east_ts;
DROP TABLESPACE IF EXISTS eu_west_ts;
DROP TABLESPACE IF EXISTS ap_south_ts;
DROP TABLESPACE IF EXISTS global_ts;

\echo ''
\echo '════════════════════════════════════════════════════════════════════'
\echo ' Part 1 — Cluster topology verification                              '
\echo '════════════════════════════════════════════════════════════════════'

-- ── 1.1  All nodes with cloud/region/zone ────────────────────────────────────
\echo '-- 1.1  Cluster nodes and their geographic placement'
SELECT host, port, cloud, region, zone, node_type, num_connections
FROM yb_servers()
ORDER BY region;

-- ── 1.2  Tablet distribution across nodes ────────────────────────────────────
\echo '-- 1.2  Tablet leaders per node (shows even distribution)'
SELECT
    tm.leader                               AS leader_node,
    sv.zone,
    COUNT(*)                                AS tablet_count
FROM yb_tablet_metadata tm
JOIN yb_servers() sv ON tm.leader LIKE sv.host || '%'
GROUP BY tm.leader, sv.zone
ORDER BY tablet_count DESC;


\echo ''
\echo '════════════════════════════════════════════════════════════════════'
\echo ' Part 2 — Tablespaces: pinning data to geographic regions            '
\echo '════════════════════════════════════════════════════════════════════'

-- ── 2.1  Create region-specific tablespaces ──────────────────────────────────
\echo '-- 2.1  Create tablespaces for US-East, EU-West, AP-South, and global'

-- Global tablespace: one replica per region — data spread across all three
CREATE TABLESPACE global_ts WITH (
  replica_placement = '{"num_replicas": 3, "placement_blocks": [
    {"cloud":"ybcloud","region":"us-east","zone":"us-east-az1","min_num_replicas":1},
    {"cloud":"ybcloud","region":"eu-west","zone":"eu-west-az1","min_num_replicas":1},
    {"cloud":"ybcloud","region":"ap-south","zone":"ap-south-az1","min_num_replicas":1}
  ]}'
);

-- US-East tablespace: all replicas stay in us-east (data residency)
-- Production: use num_replicas=3 with 3 nodes in the region; here RF=1 for single-node demo
CREATE TABLESPACE us_east_ts WITH (
  replica_placement = '{"num_replicas": 1, "placement_blocks": [
    {"cloud":"ybcloud","region":"us-east","zone":"us-east-az1","min_num_replicas":1}
  ]}'
);

-- EU-West tablespace: all replicas stay in eu-west (GDPR / data sovereignty)
CREATE TABLESPACE eu_west_ts WITH (
  replica_placement = '{"num_replicas": 1, "placement_blocks": [
    {"cloud":"ybcloud","region":"eu-west","zone":"eu-west-az1","min_num_replicas":1}
  ]}'
);

-- AP-South tablespace: all replicas stay in ap-south
CREATE TABLESPACE ap_south_ts WITH (
  replica_placement = '{"num_replicas": 1, "placement_blocks": [
    {"cloud":"ybcloud","region":"ap-south","zone":"ap-south-az1","min_num_replicas":1}
  ]}'
);

-- ── 2.2  Inspect tablespace definitions ──────────────────────────────────────
\echo '-- 2.2  Tablespace definitions in the catalog'
SELECT spcname AS tablespace, spcoptions AS options
FROM pg_tablespace
WHERE spcname NOT IN ('pg_default', 'pg_global')
ORDER BY spcname;

-- ── 2.3  Create region-pinned tables ─────────────────────────────────────────
\echo '-- 2.3  Create tables pinned to specific regions'

-- Global products catalogue: replicated across all three regions
CREATE TABLE products (
    product_id  SERIAL          PRIMARY KEY,
    name        TEXT            NOT NULL,
    category    TEXT            NOT NULL,
    price       NUMERIC(10, 2)  NOT NULL
) TABLESPACE global_ts SPLIT INTO 3 TABLETS;

-- US orders: stays in US East
CREATE TABLE orders_us (
    order_id    BIGSERIAL       PRIMARY KEY,
    customer    TEXT            NOT NULL,
    product_id  INT             REFERENCES products(product_id),
    amount      NUMERIC(10, 2)  NOT NULL,
    created_at  TIMESTAMPTZ     NOT NULL DEFAULT now()
) TABLESPACE us_east_ts SPLIT INTO 1 TABLETS;

-- EU orders: stays in EU West (GDPR)
CREATE TABLE orders_eu (
    order_id    BIGSERIAL       PRIMARY KEY,
    customer    TEXT            NOT NULL,
    product_id  INT             REFERENCES products(product_id),
    amount      NUMERIC(10, 2)  NOT NULL,
    created_at  TIMESTAMPTZ     NOT NULL DEFAULT now()
) TABLESPACE eu_west_ts SPLIT INTO 1 TABLETS;

-- APAC orders: stays in AP South
CREATE TABLE orders_ap (
    order_id    BIGSERIAL       PRIMARY KEY,
    customer    TEXT            NOT NULL,
    product_id  INT             REFERENCES products(product_id),
    amount      NUMERIC(10, 2)  NOT NULL,
    created_at  TIMESTAMPTZ     NOT NULL DEFAULT now()
) TABLESPACE ap_south_ts SPLIT INTO 1 TABLETS;

-- ── 2.4  Regional indexes in matching tablespace ──────────────────────────────
\echo '-- 2.4  Indexes co-located with their table (same tablespace)'
CREATE INDEX idx_orders_us_customer  ON orders_us(customer)  TABLESPACE us_east_ts;
CREATE INDEX idx_orders_eu_customer  ON orders_eu(customer)  TABLESPACE eu_west_ts;
CREATE INDEX idx_orders_ap_customer  ON orders_ap(customer)  TABLESPACE ap_south_ts;

-- ── 2.5  Seed data ────────────────────────────────────────────────────────────
\echo '-- 2.5  Seed products (global) and regional orders'
INSERT INTO products (name, category, price) VALUES
  ('Widget Pro', 'electronics', 49.99),
  ('Gadget Plus', 'electronics', 99.99),
  ('Basic Kit', 'tools', 19.99),
  ('Premium Bundle', 'tools', 149.99),
  ('Standard Pack', 'supplies', 9.99);

INSERT INTO orders_us (customer, product_id, amount)
SELECT 'US-Customer-' || i, (i % 5) + 1, (random() * 200 + 10)::NUMERIC(10,2)
FROM generate_series(1, 500) i;

INSERT INTO orders_eu (customer, product_id, amount)
SELECT 'EU-Customer-' || i, (i % 5) + 1, (random() * 200 + 10)::NUMERIC(10,2)
FROM generate_series(1, 500) i;

INSERT INTO orders_ap (customer, product_id, amount)
SELECT 'AP-Customer-' || i, (i % 5) + 1, (random() * 200 + 10)::NUMERIC(10,2)
FROM generate_series(1, 500) i;

-- ── 2.6  Verify tablet placement ─────────────────────────────────────────────
\echo '-- 2.6  Tablet leaders per table — confirm regional pinning'
SELECT
    tm.relname                      AS table_name,
    tm.leader                       AS leader_node,
    sv.region,
    sv.zone
FROM yb_tablet_metadata tm
JOIN yb_servers() sv ON tm.leader LIKE sv.host || '%'
WHERE tm.db_name = current_database()
  AND tm.relname IN ('products','orders_us','orders_eu','orders_ap')
ORDER BY tm.relname, sv.region;


\echo ''
\echo '════════════════════════════════════════════════════════════════════'
\echo ' Part 3 — Leader preference: controlling where reads and writes land '
\echo '════════════════════════════════════════════════════════════════════'

\echo '-- 3.1  Current tablet leader distribution'
SELECT tm.relname, tm.leader, sv.region
FROM yb_tablet_metadata tm
JOIN yb_servers() sv ON tm.leader LIKE sv.host || '%'
WHERE tm.db_name = current_database() AND tm.relname = 'products'
ORDER BY tm.leader;

\echo ''
\echo '-- 3.2  Set us-east as the preferred (primary) leader zone'
\echo '--      Run from the ysqlsh shell or connector-config terminal:'
\echo '--'
\echo '--  yb-admin --master_addresses 127.0.0.1:7100,127.0.0.2:7100,127.0.0.3:7100 \'
\echo '--    set_preferred_zones ybcloud.us-east.us-east-az1'
\echo '--'
\echo '-- After setting, tablet leaders for products migrate to us-east.'
\echo '-- Verify with Part 3.1 query above.'

\echo ''
\echo '-- 3.3  Add a secondary preference (eu-west if us-east is unavailable)'
\echo '--'
\echo '--  yb-admin --master_addresses 127.0.0.1:7100,127.0.0.2:7100,127.0.0.3:7100 \'
\echo '--    set_preferred_zones ybcloud.us-east.us-east-az1:1 ybcloud.eu-west.eu-west-az1:2'


\echo ''
\echo '════════════════════════════════════════════════════════════════════'
\echo ' Part 4 — Row-level geo-partitioning: automatic data residency       '
\echo '════════════════════════════════════════════════════════════════════'

\echo '-- 4.1  Create a geo-partitioned orders table (single parent, three regions)'

CREATE TABLE global_orders (
    order_id    BIGSERIAL        NOT NULL,
    region      TEXT             NOT NULL,   -- partition key: US | EU | AP
    customer    TEXT             NOT NULL,
    amount      NUMERIC(10, 2)   NOT NULL,
    status      TEXT             NOT NULL DEFAULT 'pending',
    created_at  TIMESTAMPTZ      NOT NULL DEFAULT now()
) PARTITION BY LIST (region);

-- US partition — data pinned to us-east
CREATE TABLE global_orders_us
    PARTITION OF global_orders (
        order_id, region, customer, amount, status, created_at,
        PRIMARY KEY (order_id HASH, region)
    )
    FOR VALUES IN ('US')
    TABLESPACE us_east_ts;

CREATE INDEX ON global_orders_us (customer) TABLESPACE us_east_ts;

-- EU partition — data pinned to eu-west (GDPR residency)
CREATE TABLE global_orders_eu
    PARTITION OF global_orders (
        order_id, region, customer, amount, status, created_at,
        PRIMARY KEY (order_id HASH, region)
    )
    FOR VALUES IN ('EU')
    TABLESPACE eu_west_ts;

CREATE INDEX ON global_orders_eu (customer) TABLESPACE eu_west_ts;

-- AP partition — data pinned to ap-south
CREATE TABLE global_orders_ap
    PARTITION OF global_orders (
        order_id, region, customer, amount, status, created_at,
        PRIMARY KEY (order_id HASH, region)
    )
    FOR VALUES IN ('AP')
    TABLESPACE ap_south_ts;

CREATE INDEX ON global_orders_ap (customer) TABLESPACE ap_south_ts;

\echo '-- 4.2  Insert rows — partition routing is automatic'
INSERT INTO global_orders (region, customer, amount) VALUES
  ('US', 'Alice Johnson', 1200.00),
  ('EU', 'Lars Eriksson', 850.00),
  ('AP', 'Priya Sharma',  950.00),
  ('US', 'Bob Williams',  430.00),
  ('EU', 'Marie Dupont',  620.00);

\echo '-- 4.3  Rows land in the correct regional partition'
SELECT tableoid::regclass AS partition, region, customer, amount
FROM global_orders
ORDER BY region, customer;

\echo '-- 4.4  Query only the local partition (yb_is_local_table)'
\echo '--      Returns rows whose partition tablet leader is on this node.'
SELECT order_id, region, customer, amount
FROM global_orders
WHERE yb_is_local_table(tableoid)
ORDER BY region, customer;

\echo '-- 4.5  EXPLAIN confirms partition pruning — only one partition scanned'
EXPLAIN SELECT * FROM global_orders WHERE region = 'EU';

\echo '-- 4.6  Add a new region at runtime — no downtime'
CREATE TABLE global_orders_latam
    PARTITION OF global_orders (
        order_id, region, customer, amount, status, created_at,
        PRIMARY KEY (order_id HASH, region)
    )
    FOR VALUES IN ('LATAM')
    TABLESPACE us_east_ts;  -- nearest region for demo; add latam_ts for production

INSERT INTO global_orders (region, customer, amount)
  VALUES ('LATAM', 'Carlos Mendez', 780.00);

SELECT region, COUNT(*) AS orders FROM global_orders GROUP BY region ORDER BY region;


\echo ''
\echo '════════════════════════════════════════════════════════════════════'
\echo ' Part 5 — Follower reads: low-latency reads from the nearest replica '
\echo '════════════════════════════════════════════════════════════════════'

\echo '-- 5.1  Default: reads go to the tablet leader (strong consistency)'
SELECT COUNT(*), ROUND(SUM(amount), 2) AS total
FROM global_orders WHERE region = 'EU';

\echo '-- 5.2  Enable follower reads for the session'
\echo '--      The read is served from the nearest replica — may be slightly stale.'
SET yb_read_from_followers = true;
SET yb_follower_read_staleness_ms = 10000;   -- 10-second staleness window
SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY;

SELECT COUNT(*), ROUND(SUM(amount), 2) AS total
FROM global_orders WHERE region = 'EU';

\echo '-- 5.3  Reset to strong reads'
SET SESSION CHARACTERISTICS AS TRANSACTION READ WRITE;
SET yb_read_from_followers = false;

\echo '-- 5.4  Follower reads with explicit read-only transaction'
BEGIN;
SET TRANSACTION READ ONLY;
SET LOCAL yb_read_from_followers = true;
SET LOCAL yb_follower_read_staleness_ms = 5000;
SELECT order_id, customer, amount FROM global_orders WHERE region = 'AP';
COMMIT;

\echo '-- Key insight: yb_read_from_followers requires a read-only transaction.'
\echo '   Default staleness is 30000ms. Reduce for freshness, increase for throughput.'


\echo ''
\echo '════════════════════════════════════════════════════════════════════'
\echo ' Part 6 — Verification and inspection queries                        '
\echo '════════════════════════════════════════════════════════════════════'

\echo '-- 6.1  All tablespaces and their replica placement JSON'
SELECT spcname, spcoptions FROM pg_tablespace
WHERE spcname NOT IN ('pg_default', 'pg_global')
ORDER BY spcname;

\echo '-- 6.2  Which tablespace each table/index is in'
SELECT
    c.relname                                   AS object_name,
    c.relkind                                   AS kind,
    COALESCE(t.spcname, 'pg_default')           AS tablespace
FROM pg_class c
LEFT JOIN pg_tablespace t ON c.reltablespace = t.oid
WHERE c.relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public')
  AND c.relkind IN ('r', 'i', 'p')
ORDER BY tablespace, kind, object_name;

\echo '-- 6.3  Tablet leaders with region details — full picture'
SELECT
    tm.relname                                  AS table_name,
    tm.tablet_id,
    tm.leader                                   AS leader_node,
    sv.region,
    sv.zone,
    tm.start_hash_code,
    tm.end_hash_code
FROM yb_tablet_metadata tm
JOIN yb_servers() sv ON tm.leader LIKE sv.host || '%'
WHERE tm.db_name = current_database()
  AND tm.relname LIKE 'global_orders%'
ORDER BY tm.relname, sv.region;


\echo ''
\echo '════════════════════════════════════════════════════════════════════'
\echo ' Cleanup                                                             '
\echo '════════════════════════════════════════════════════════════════════'

-- \echo 'To clean up: run the following'
-- DROP TABLE IF EXISTS global_orders CASCADE;
-- DROP TABLE IF EXISTS orders_us, orders_eu, orders_ap, products CASCADE;
-- DROP TABLESPACE IF EXISTS us_east_ts;
-- DROP TABLESPACE IF EXISTS eu_west_ts;
-- DROP TABLESPACE IF EXISTS ap_south_ts;
-- DROP TABLESPACE IF EXISTS global_ts;
