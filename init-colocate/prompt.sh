#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# YugabyteDB Colocation demo  —  "The SaaS Catalog"
#
# Scenario: A SaaS platform has small reference tables (tenants, products,
# categories) that are joined constantly, plus a high-volume orders table
# that must scale independently.
#
# Without colocation: every table gets its own tablets → cross-shard joins,
# wasted resources even for tiny lookup tables.
#
# With colocation: small tables share ONE parent tablet. Joins between them
# are local. The orders table opts out to distribute across all nodes.
#
# Key APIs (all GA):
#   CREATE DATABASE ... WITH COLOCATION = true   -- colocated DB
#   CREATE TABLE   ... WITH (COLOCATION = false) -- opt a table out
#   yb_table_properties(relid)                   -- inspect tablets per table
#   yb_is_database_colocated()                   -- check DB colocation status
# ─────────────────────────────────────────────────────────────────────────────

. pscript

TYPE_SPEED=40
NO_WAIT=false
DEMO_PROMPT="${GREEN}➜ ${CYAN}\W ${COLOR_RESET}"

clear

# ── Quiet setup: drop any leftover databases from a previous run ──────────────
ysqlsh -h 127.0.0.1 -c "DROP DATABASE IF EXISTS saas_standard;"  2>/dev/null || true
ysqlsh -h 127.0.0.1 -c "DROP DATABASE IF EXISTS saas_colocated;" 2>/dev/null || true

p "=== YugabyteDB Colocation: Co-locate Small, Distribute Large ==="
p ""
p "Cluster: 3 nodes  |  RF = 3"
p "Goal: show the tablet-count difference and join behaviour."

# ─────────────────────────────────────────────────────────────────────────────
# PART 1: Non-colocated baseline
# ─────────────────────────────────────────────────────────────────────────────

p ""
p "━━━ Part 1: Without Colocation (standard distributed database) ━━━"
p ""
p "Every table — no matter how small — gets its own tablet set."

pe "ysqlsh -h 127.0.0.1 -c \"CREATE DATABASE saas_standard;\""

pe "ysqlsh -h 127.0.0.1 -d saas_standard -c \"
CREATE TABLE tenants (
  id   SERIAL PRIMARY KEY,
  name TEXT   NOT NULL,
  plan TEXT
);
CREATE TABLE products (
  id       SERIAL  PRIMARY KEY,
  name     TEXT    NOT NULL,
  category TEXT,
  price    NUMERIC
);
CREATE TABLE orders (
  id         BIGSERIAL PRIMARY KEY,
  tenant_id  INT REFERENCES tenants(id),
  product_id INT REFERENCES products(id),
  qty        INT,
  total      NUMERIC,
  created_at TIMESTAMPTZ DEFAULT NOW()
);\""

p ""
p "--- Is this database colocated? ---"

pe "ysqlsh -h 127.0.0.1 -d saas_standard -c \"SELECT yb_is_database_colocated();\""

p ""
p "--- Tablets per table (standard database, RF=3) ---"

pe "ysqlsh -h 127.0.0.1 -d saas_standard -c \"
SELECT c.relname    AS table_name,
       p.num_tablets,
       p.is_colocated
FROM   pg_class c,
       yb_table_properties(c.oid) p
WHERE  c.relnamespace = 'public'::regnamespace
  AND  c.relkind = 'r'
ORDER  BY c.relname;\""

p ""
p "3 tables × 3 tablets each = 9 tablets for a tiny SaaS catalog."
p "Every join between tenants and products crosses tablet boundaries."

# ─────────────────────────────────────────────────────────────────────────────
# PART 2: Colocated database — default colocation
# ─────────────────────────────────────────────────────────────────────────────

p ""
p "━━━ Part 2: Colocated Database ━━━"
p ""
p "CREATE DATABASE ... WITH COLOCATION = true"
p "All tables share a single parent tablet by default."

pe "ysqlsh -h 127.0.0.1 -c \"CREATE DATABASE saas_colocated WITH COLOCATION = true;\""

pe "ysqlsh -h 127.0.0.1 -d saas_colocated -c \"SELECT yb_is_database_colocated();\""

p ""
p "--- Create the same tables. No extra clause needed — they are colocated. ---"

pe "ysqlsh -h 127.0.0.1 -d saas_colocated -c \"
CREATE TABLE tenants (
  id   SERIAL PRIMARY KEY,
  name TEXT   NOT NULL,
  plan TEXT
);
CREATE TABLE products (
  id       SERIAL  PRIMARY KEY,
  name     TEXT    NOT NULL,
  category TEXT,
  price    NUMERIC
);\""

p ""
p "--- Tablets per table (colocated database) ---"

pe "ysqlsh -h 127.0.0.1 -d saas_colocated -c \"
SELECT c.relname    AS table_name,
       p.num_tablets,
       p.is_colocated,
       p.colocation_id
FROM   pg_class c,
       yb_table_properties(c.oid) p
WHERE  c.relnamespace = 'public'::regnamespace
  AND  c.relkind = 'r'
ORDER  BY c.relname;\""

p ""
p "tenants and products: 1 tablet, colocated = true."
p "Joins between them are local — zero cross-node I/O."

# ─────────────────────────────────────────────────────────────────────────────
# PART 3: Opt-out — high-volume table stays distributed
# ─────────────────────────────────────────────────────────────────────────────

p ""
p "━━━ Part 3: Opting Out — WITH (COLOCATION = false) ━━━"
p ""
p "The orders table grows fast and needs to scale across all nodes."
p "Use WITH (COLOCATION = false) to keep it distributed."

pe "ysqlsh -h 127.0.0.1 -d saas_colocated -c \"
CREATE TABLE orders (
  id         BIGSERIAL PRIMARY KEY,
  tenant_id  INT REFERENCES tenants(id),
  product_id INT REFERENCES products(id),
  qty        INT,
  total      NUMERIC,
  created_at TIMESTAMPTZ DEFAULT NOW()
) WITH (COLOCATION = false);\""

p ""
p "--- Full picture: colocated reference tables + distributed orders ---"

pe "ysqlsh -h 127.0.0.1 -d saas_colocated -c \"
SELECT c.relname    AS table_name,
       p.num_tablets,
       p.is_colocated
FROM   pg_class c,
       yb_table_properties(c.oid) p
WHERE  c.relnamespace = 'public'::regnamespace
  AND  c.relkind = 'r'
ORDER  BY c.relname;\""

p ""
p "tenants  → 1 tablet  (colocated: local joins, minimal overhead)"
p "products → 1 tablet  (colocated: local joins, minimal overhead)"
p "orders   → 3 tablets (distributed: scales out with writes)"

# ─────────────────────────────────────────────────────────────────────────────
# PART 4: Seed data and compare join plans
# ─────────────────────────────────────────────────────────────────────────────

p ""
p "━━━ Part 4: Query Comparison ━━━"

pe "ysqlsh -h 127.0.0.1 -d saas_colocated -c \"
INSERT INTO tenants(name, plan) VALUES
  ('Acme Corp','pro'), ('Globex','starter'), ('Initech','enterprise');
INSERT INTO products(name, category, price) VALUES
  ('Laptop','Electronics',999.00), ('Phone','Electronics',599.00),
  ('T-Shirt','Clothing',19.99),   ('Novel','Books',12.99);\""

(set -f; pe "ysqlsh -h 127.0.0.1 -d saas_colocated -c \"
INSERT INTO orders(tenant_id, product_id, qty, total)
SELECT 1 + mod(i,3), 1 + mod(i,4), 1 + mod(i,5),
       ((1 + mod(i,5)) * 9.99)::numeric(10,2)
FROM generate_series(1,10000) i;\"")

p ""
p "--- EXPLAIN: join between colocated tenants + products ---"
p "    Both live on the same tablet → YugabyteDB does NOT need to scatter"
p "    the join across nodes."

pe "ysqlsh -h 127.0.0.1 -d saas_colocated -c \"
EXPLAIN (COSTS OFF)
SELECT t.name AS tenant, p.name AS product, COUNT(*) AS order_count
FROM   orders o
JOIN   tenants  t ON o.tenant_id  = t.id
JOIN   products p ON o.product_id = p.id
GROUP  BY t.name, p.name
ORDER  BY order_count DESC;\""

p ""
p "--- Result ---"

pe "ysqlsh -h 127.0.0.1 -d saas_colocated -c \"
SELECT t.name AS tenant, p.name AS product, COUNT(*) AS order_count
FROM   orders o
JOIN   tenants  t ON o.tenant_id  = t.id
JOIN   products p ON o.product_id = p.id
GROUP  BY t.name, p.name
ORDER  BY order_count DESC;\""

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────

p ""
p "━━━ Summary ━━━"
p ""
p "  Without colocation  Every table → own tablets → cross-shard joins"
p "  With colocation     Small tables share ONE parent tablet → local joins"
p "  Opt-out             WITH (COLOCATION = false) → table stays distributed"
p ""
p "  Inspect:  SELECT * FROM yb_table_properties('table'::regclass);"
p "  Check DB: SELECT yb_is_database_colocated();"
p ""
p "  Rule of thumb:"
p "  • Small / frequently joined / rarely full-scanned  →  colocate"
p "  • High write throughput / large range scans        →  opt out (distribute)"

cmd

p ""
