-- ─────────────────────────────────────────────────────────────────────────────
-- setup.sql  —  one-time bootstrap for the Observability exercise
-- Run automatically by postStartCommand; do not run manually.
-- ─────────────────────────────────────────────────────────────────────────────

DROP DATABASE IF EXISTS obs_demo;
CREATE DATABASE obs_demo;
\c obs_demo

-- ── pg_stat_statements ───────────────────────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- Enable DocDB RPC columns (docdb_rows_scanned, docdb_wait_time, etc.)
-- and extend query text capture for pg_stat_activity
ALTER SYSTEM SET yb_enable_pg_stat_statements_rpc_stats = true;
ALTER SYSTEM SET track_activity_query_size = 4096;
SELECT pg_reload_conf();

-- Clear any prior stats from other exercises
SELECT pg_stat_statements_reset();

-- ── Schema  ───────────────────────────────────────────────────────────────────
-- orders: hash-sharded (intentionally missing index on customer_id + status)
CREATE TABLE orders (
    order_id    BIGSERIAL       PRIMARY KEY,
    customer_id INT             NOT NULL,
    product_id  INT             NOT NULL,
    amount      NUMERIC(10, 2)  NOT NULL,
    status      TEXT            NOT NULL DEFAULT 'pending',
    created_at  TIMESTAMPTZ     NOT NULL DEFAULT now()
);

-- customers: range-sharded on customer_id (sequential inserts → first-tablet hotspot)
CREATE TABLE customers (
    customer_id INT             PRIMARY KEY ASC,
    email       TEXT            NOT NULL,
    region      TEXT            NOT NULL,
    created_at  TIMESTAMPTZ     NOT NULL DEFAULT now()
);

-- products: hash-sharded, small table, fast lookups
CREATE TABLE products (
    product_id  INT             PRIMARY KEY,
    name        TEXT            NOT NULL,
    category    TEXT            NOT NULL,
    price       NUMERIC(10, 2)  NOT NULL
);

-- ── Seed data ─────────────────────────────────────────────────────────────────
INSERT INTO products
SELECT g,
       'Product-' || g,
       CASE g % 5
           WHEN 0 THEN 'electronics'
           WHEN 1 THEN 'clothing'
           WHEN 2 THEN 'books'
           WHEN 3 THEN 'food'
           ELSE        'home'
       END,
       (random() * 490 + 10)::NUMERIC(10, 2)
FROM generate_series(1, 1000) g;

INSERT INTO customers
SELECT g,
       'user' || g || '@example.com',
       CASE g % 4
           WHEN 0 THEN 'us-east'
           WHEN 1 THEN 'us-west'
           WHEN 2 THEN 'eu-west'
           ELSE        'ap-south'
       END,
       now() - (random() * 365 || ' days')::interval
FROM generate_series(1, 10000) g;

-- 500k orders: 70% skewed to customer_id 1–100 (creates a hot shard scenario)
INSERT INTO orders (customer_id, product_id, amount, status)
SELECT
    CASE WHEN random() < 0.7
         THEN (random() * 99 + 1)::int      -- hot 100 customers
         ELSE (random() * 9899 + 101)::int  -- cold 9900 customers
    END,
    (random() * 999 + 1)::int,
    (random() * 995 + 5)::NUMERIC(10, 2),
    CASE WHEN random() < 0.80 THEN 'completed'
         WHEN random() < 0.95 THEN 'pending'
         ELSE 'cancelled'
    END
FROM generate_series(1, 500000);

ANALYZE orders, customers, products;

\echo ''
\echo '✅ obs_demo ready — 500k orders seeded across 10k customers and 1k products.'
\echo '   Run: \i init-obs/obs.sql   to start the exercises.'
\echo '   Or:  Terminal → Run Task → obs-demo   for the guided demo.'
