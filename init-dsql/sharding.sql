-- ============================================================
-- YugabyteDB — Hash & Range Sharding Exercises
-- ============================================================
-- Run interactively inside ysqlsh:
--   ysqlsh                    (connects to yugabyte@127.0.0.1:5433)
--   \i init-dsql/sharding.sql (execute the whole file)
--   or paste individual blocks to explore step-by-step
-- ============================================================

\echo ''
\echo '═══════════════════════════════════════════════════════════'
\echo '  Part 1 · Hash Sharding'
\echo '═══════════════════════════════════════════════════════════'

-- ── 1.1  Single-column hash (default) ─────────────────────────────────────────
-- A single-column PRIMARY KEY is hash-sharded by default.
-- YugabyteDB applies a hash function to the key to route each row to a tablet.
-- Consequence: point lookups are always 1 RPC; range scans scatter to ALL tablets.

\echo '--- 1.1  Single-column hash (default)'

CREATE TABLE users (
  user_id    TEXT PRIMARY KEY,   -- HASH by default
  name       TEXT,
  region     TEXT,
  status     TEXT,
  created_at DATE
);

INSERT INTO users (user_id, name, region, status, created_at)
SELECT 'user-' || i,
       'User ' || i,
       (ARRAY['US','EU','APAC'])[1 + mod(i,3)],
       (ARRAY['Active','Pending'])[1 + mod(i,2)],
       CURRENT_DATE - (i || ' days')::INTERVAL
FROM generate_series(1, 100) AS i;

-- ✅ Point lookup → hash(user_id) → single tablet, 1 RPC
EXPLAIN (ANALYZE, DIST) SELECT * FROM users WHERE user_id = 'user-42';

-- ⚠️  Range scan → scatter-gather across ALL tablets
EXPLAIN (ANALYZE, DIST) SELECT * FROM users WHERE user_id > 'user-50';

-- ── 1.2  Hash + ASC clustering key (time-series per entity) ───────────────────
-- Hash routes to the right tablet; the clustering key sorts rows within it.
-- Ideal for "all events for entity X sorted oldest-first."

\echo '--- 1.2  Hash + ASC clustering key'

CREATE TABLE tenant_logs (
  tenant_id  TEXT,
  log_time   TIMESTAMP,
  level      TEXT,
  message    TEXT,
  version    TEXT,
  PRIMARY KEY (tenant_id HASH, log_time ASC)
);

INSERT INTO tenant_logs (tenant_id, log_time, level, message, version)
SELECT (ARRAY['AcmeCorp','Globex','Initech'])[1 + mod(i,3)],
       NOW() - (i || ' hours')::INTERVAL,
       (ARRAY['INFO','WARN','ERROR'])[1 + mod(i,3)],
       'Log message ' || i,
       'v' || (1 + mod(i,3))
FROM generate_series(1, 300) AS i;

-- Single-tablet time-range query — efficient: no scatter-gather
EXPLAIN (ANALYZE, DIST)
SELECT * FROM tenant_logs
WHERE  tenant_id = 'AcmeCorp'
  AND  log_time > NOW() - '48 hours'::INTERVAL;

-- ── 1.3  Hash + DESC clustering key (latest-N pattern) ───────────────────────
-- DESC stores newest rows first within the tablet partition.
-- "Give me the last N events for this device" needs no sort step.

\echo '--- 1.3  Hash + DESC clustering key (latest-N)'

CREATE TABLE sensor_readings (
  sensor_id  TEXT,
  ts         TIMESTAMP,
  value      FLOAT,
  unit       TEXT,
  status     TEXT,
  PRIMARY KEY (sensor_id HASH, ts DESC)
);

INSERT INTO sensor_readings (sensor_id, ts, value, unit, status)
SELECT 'S-' || (100 + mod(i,5)),
       NOW() - (i || ' minutes')::INTERVAL,
       20.0 + random() * 10,
       '°C',
       (ARRAY['Normal','Warning','Critical'])[1 + mod(i,3)]
FROM generate_series(1, 500) AS i;

-- No ORDER BY needed — DESC is the physical storage order
EXPLAIN (ANALYZE, DIST)
SELECT * FROM sensor_readings WHERE sensor_id = 'S-102' LIMIT 10;

-- Compare: ASC table requires a sort or backward scan for the same query
CREATE TABLE sensor_readings_asc (
  sensor_id  TEXT,
  ts         TIMESTAMP,
  value      FLOAT,
  PRIMARY KEY (sensor_id HASH, ts ASC)
);

INSERT INTO sensor_readings_asc SELECT sensor_id, ts, value FROM sensor_readings;

-- ASC: must reverse-scan or sort to get latest first
EXPLAIN (ANALYZE, DIST)
SELECT * FROM sensor_readings_asc
WHERE  sensor_id = 'S-102'
ORDER BY ts DESC LIMIT 10;

-- ── 1.4  Composite hash key ────────────────────────────────────────────────────
-- Hashing on two columns together routes by the combination, not either column alone.
-- Prevents hot partitions when either column alone would concentrate writes.

\echo '--- 1.4  Composite hash key'

CREATE TABLE audit_events (
  tenant      TEXT,
  app_id      TEXT,
  event_time  TIMESTAMP,
  event       TEXT,
  status      TEXT,
  PRIMARY KEY ((tenant, app_id) HASH, event_time ASC)
);

INSERT INTO audit_events (tenant, app_id, event_time, event, status)
SELECT (ARRAY['Acme','Globex','Initech'])[1 + mod(i,3)],
       (ARRAY['web','api','mobile'])[1 + mod(i,3)],
       NOW() - (i || ' hours')::INTERVAL,
       'Event ' || i,
       'OK'
FROM generate_series(1, 300) AS i;

-- hash(tenant, app_id) → single tablet, full clustering-key range scan
EXPLAIN (ANALYZE, DIST)
SELECT * FROM audit_events
WHERE  tenant = 'Acme' AND app_id = 'web'
ORDER BY event_time DESC LIMIT 20;

-- ⚠️  Single-column filter on a composite hash → scatter-gather
EXPLAIN (ANALYZE, DIST)
SELECT * FROM audit_events WHERE tenant = 'Acme';


\echo ''
\echo '═══════════════════════════════════════════════════════════'
\echo '  Part 2 · Range Sharding'
\echo '═══════════════════════════════════════════════════════════'

-- ── 2.1  Single-column range (auto-split) ────────────────────────────────────
-- ASC / DESC on a PRIMARY KEY makes the table range-sharded.
-- Rows are stored in global sorted order across tablets.
-- Tablets split automatically when they grow beyond the size threshold (~64 MB).

\echo '--- 2.1  Single-column range (auto-split)'

CREATE TABLE products (
  product_id  TEXT  PRIMARY KEY ASC,
  category    TEXT,
  price       DECIMAL,
  status      TEXT,
  supplier    TEXT
);

INSERT INTO products (product_id, category, price, status, supplier)
SELECT 'prod-' || lpad(i::text, 4, '0'),
       (ARRAY['Electronics','Books','Home','Apparel'])[1 + mod(i,4)],
       (10 + i * 9.99)::DECIMAL,
       (ARRAY['In Stock','Low','Out'])[1 + mod(i,3)],
       (ARRAY['TechCo','PubCo','HomeCo','StyleCo'])[1 + mod(i,4)]
FROM generate_series(1, 200) AS i;

-- ✅ Range scan touches only overlapping tablets — not all of them
EXPLAIN (ANALYZE, DIST)
SELECT * FROM products WHERE product_id BETWEEN 'prod-0050' AND 'prod-0100';

-- ✅ ORDER BY product_id: no sort step — rows arrive in physical order
EXPLAIN (ANALYZE, DIST)
SELECT * FROM products ORDER BY product_id ASC LIMIT 10;

-- ── 2.2  Pre-split at known values ────────────────────────────────────────────
-- SPLIT AT VALUES pre-creates tablet boundaries, eliminating the initial
-- single-hot-tablet period for range-sharded tables.
-- Use when you know the data distribution in advance.

\echo '--- 2.2  Pre-split at known values'

CREATE TABLE log_entries (
  log_date   DATE         NOT NULL,
  host       TEXT         NOT NULL,
  severity   TEXT         NOT NULL,
  message    TEXT,
  PRIMARY KEY (log_date ASC, host ASC)
) SPLIT AT VALUES (
    ('2025-01-01'),
    ('2025-04-01'),
    ('2025-07-01'),
    ('2025-10-01')
);

-- Pre-creates 5 tablets: one per quarter + the leading (-∞, 2025-01-01) shard
SELECT * FROM yb_table_properties('log_entries'::regclass);

INSERT INTO log_entries (log_date, host, severity, message)
SELECT CURRENT_DATE - (random() * 364)::int,
       'host-' || (1 + (random() * 9)::int),
       (ARRAY['INFO','WARN','ERROR'])[1 + mod(i,3)],
       'Log entry ' || i
FROM generate_series(1, 1000) AS i;

-- Touches only the Q2 tablet
EXPLAIN (ANALYZE, DIST)
SELECT count(*) FROM log_entries
WHERE  log_date BETWEEN '2025-04-01' AND '2025-06-30';

-- ── 2.3  Composite range key ──────────────────────────────────────────────────
-- Multiple columns form the range key; each is sorted in sequence.
-- Prefix scan (region = X) is efficient; non-prefix (sensor_id = Y only) is not.

\echo '--- 2.3  Composite range key'

CREATE TABLE metrics (
  sensor_id   TEXT,
  ts          TIMESTAMP,
  value       FLOAT,
  unit        TEXT,
  check_status TEXT,
  PRIMARY KEY (sensor_id ASC, ts DESC)
);

INSERT INTO metrics (sensor_id, ts, value, unit, check_status)
SELECT 'S-' || lpad((1 + mod(i,20))::text, 3, '0'),
       NOW() - (i || ' minutes')::INTERVAL,
       20.0 + random() * 10,
       '°C',
       (ARRAY['OK','WARN','CRIT'])[1 + mod(i,3)]
FROM generate_series(1, 2000) AS i;

-- ✅ Prefix + time range: seeks directly to the right position
EXPLAIN (ANALYZE, DIST)
SELECT * FROM metrics
WHERE  sensor_id = 'S-005' AND ts > NOW() - '1 hour'::INTERVAL
ORDER BY ts DESC LIMIT 20;

-- ⚠️  Non-prefix: must scan all sensor_id ranges to find this ts value
EXPLAIN (ANALYZE, DIST)
SELECT * FROM metrics WHERE ts > NOW() - '30 minutes'::INTERVAL;

-- ── 2.4  ASC vs DESC range — storage order matters ────────────────────────────
-- The clustering direction determines which query pattern is "free."

\echo '--- 2.4  ASC vs DESC storage order comparison'

CREATE TABLE products_desc (
  product_id  TEXT  PRIMARY KEY DESC,
  name        TEXT,
  price       DECIMAL
);

INSERT INTO products_desc (product_id, name, price)
SELECT 'prod-' || lpad(i::text, 4, '0'),
       'Product ' || i,
       (10 + i * 9.99)::DECIMAL
FROM generate_series(1, 200) AS i;

-- DESC PK: "latest" (lexicographically largest) product IDs are first
-- → No sort step for this common pattern:
EXPLAIN (ANALYZE, DIST)
SELECT * FROM products_desc ORDER BY product_id DESC LIMIT 5;

-- vs products (ASC): requires backward scan for the same query
EXPLAIN (ANALYZE, DIST)
SELECT * FROM products ORDER BY product_id DESC LIMIT 5;


\echo ''
\echo '═══════════════════════════════════════════════════════════'
\echo '  Part 3 · Secondary Indexes'
\echo '═══════════════════════════════════════════════════════════'

-- ── 3.1  Hash index — equality lookups ───────────────────────────────────────
-- A secondary hash index is a separate tablet group keyed by the indexed column.
-- Equality lookup: 1 RPC → index tablet → get PK → 1 RPC → main table. (2 RPCs total)

\echo '--- 3.1  Hash index (equality)'

-- Seed a unique email column
ALTER TABLE users ADD COLUMN email TEXT;
UPDATE users SET email = 'user' || substr(user_id, 6) || '@example.com';

CREATE INDEX idx_users_email ON users (email HASH);
CREATE UNIQUE INDEX idx_users_email_u ON users (email HASH);

EXPLAIN (ANALYZE, DIST)
SELECT * FROM users WHERE email = 'user42@example.com';

-- ── 3.2  Range index — ordered access & range scans ──────────────────────────

\echo '--- 3.2  Range index (range scans, ordering)'

ALTER TABLE products ADD COLUMN created_at TIMESTAMP DEFAULT NOW();

CREATE INDEX idx_products_price ON products (price ASC);

-- ✅ Range scan: touches only the tablet(s) covering this price window
EXPLAIN (ANALYZE, DIST)
SELECT * FROM products WHERE price BETWEEN 200 AND 500;

-- ✅ ORDER BY price: streaming scan, no sort node
EXPLAIN (ANALYZE, DIST)
SELECT * FROM products ORDER BY price ASC LIMIT 10;

-- Pre-split the index to avoid the cold-start hotspot
CREATE INDEX idx_products_price_split ON products (price ASC)
  SPLIT AT VALUES ((100), (300), (600));

EXPLAIN (ANALYZE, DIST)
SELECT * FROM products WHERE price > 600 ORDER BY price LIMIT 10;

-- ── 3.3  Covering index (INCLUDE) ─────────────────────────────────────────────
-- Store extra columns in the index leaf so the query never needs to
-- fetch the main table. Turns a 2-RPC lookup into 1 RPC.

\echo '--- 3.3  Covering index (INCLUDE)'

CREATE INDEX idx_users_email_cover
  ON users (email HASH)
  INCLUDE (name, region);

-- ✅ Index-only scan — fetches name + region directly from the index leaf
EXPLAIN (ANALYZE, DIST)
SELECT name, region FROM users WHERE email = 'user42@example.com';

-- ❌ SELECT * still needs the main table (status is not in the index)
EXPLAIN (ANALYZE, DIST)
SELECT * FROM users WHERE email = 'user42@example.com';

-- ── 3.4  Partial index (filtered) ────────────────────────────────────────────
-- Index only the rows matching a WHERE condition.
-- Smaller index, faster writes, useful when a column is highly skewed.

\echo '--- 3.4  Partial index'

CREATE INDEX idx_active_users
  ON users (email HASH)
  WHERE status = 'Active';

-- ✅ Uses the partial index (predicate matches)
EXPLAIN (ANALYZE, DIST)
SELECT * FROM users WHERE email = 'user42@example.com' AND status = 'Active';

-- ❌ Cannot use this index (no status = 'Active' filter)
EXPLAIN (ANALYZE, DIST)
SELECT * FROM users WHERE email = 'user42@example.com';

-- ── 3.5  Expression index ─────────────────────────────────────────────────────
-- Index a function of a column. The stored key is the expression value.
-- Query WHERE clause must match the expression exactly.

\echo '--- 3.5  Expression index'

CREATE INDEX idx_lower_email ON users (lower(email) HASH);

-- ✅ Expression in WHERE matches the index definition
EXPLAIN (ANALYZE, DIST)
SELECT * FROM users WHERE lower(email) = 'user42@example.com';

-- ❌ Raw column value — cannot use the expression index
EXPLAIN (ANALYZE, DIST)
SELECT * FROM users WHERE email = 'User42@Example.COM';

-- ── 3.6  Bucket index — hot-key mitigation ────────────────────────────────────
-- A plain range index on a monotone column (timestamp, serial) creates a
-- permanent write hotspot on the "last" tablet.
-- Fix: prepend a synthetic bucket prefix to spread writes across N tablets.

\echo '--- 3.6  Bucket index (hot-key mitigation)'

CREATE TABLE events (
  event_id    TEXT PRIMARY KEY,
  ts          TIMESTAMPTZ,
  device_id   TEXT,
  metric      TEXT,
  value       DECIMAL
);

-- ❌ Avoid: monotone ts → all inserts land on one tablet
-- CREATE INDEX idx_events_ts_bad ON events (ts DESC);

-- ✅ Bucket index: 3 write-balanced tablets, ts-sorted within each
CREATE INDEX idx_events_ts ON events (
    (yb_hash_code(ts) % 3) ASC,
    ts DESC
) INCLUDE (metric, value)
  SPLIT AT VALUES ((1), (2));

INSERT INTO events (event_id, ts, device_id, metric, value)
SELECT 'ev-' || i,
       NOW() - (i * 7 || ' days')::INTERVAL,
       (ARRAY['dev-A','dev-B','dev-C'])[1 + mod(i,3)],
       (ARRAY['cpu','mem','disk','net'])[1 + mod(i,4)],
       (20 + i * 5.5)::DECIMAL
FROM generate_series(1, 500) AS i;

-- EXPLAIN shows Merge Append of 3 bucket sub-scans
EXPLAIN (ANALYZE, DIST)
SELECT event_id, ts, metric, value
FROM   events
WHERE  ts BETWEEN NOW() - '30 days'::INTERVAL AND NOW()
ORDER BY ts DESC
LIMIT 50;


\echo ''
\echo '═══════════════════════════════════════════════════════════'
\echo '  Part 4 · Observe Tablet Metadata'
\echo '═══════════════════════════════════════════════════════════'

\echo '--- Tablet properties for key tables'

SELECT * FROM yb_table_properties('users'::regclass);
SELECT * FROM yb_table_properties('tenant_logs'::regclass);
SELECT * FROM yb_table_properties('products'::regclass);
SELECT * FROM yb_table_properties('metrics'::regclass);
SELECT * FROM yb_table_properties('events'::regclass);

-- Tablet-level distribution across nodes
SELECT * FROM yb_local_tablets LIMIT 30;


\echo ''
\echo '═══════════════════════════════════════════════════════════'
\echo '  Cleanup'
\echo '═══════════════════════════════════════════════════════════'

DROP TABLE IF EXISTS
  users, tenant_logs, sensor_readings, sensor_readings_asc,
  audit_events, products, products_desc, log_entries, metrics, events
CASCADE;
