# Colocation & Distributed Tables

[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/srinivasa-vasu/ybdb-vanguard?devcontainer_path=.devcontainer%2Finit-colocate%2Fdevcontainer.json)

Co-locate small reference tables on a single shared tablet for local joins, while keeping high-volume tables distributed across all nodes — in the same database.

---

> **Run queries interactively**: Select any SQL block → **`Ctrl+Shift+Enter`** (Windows/Linux) or **`Cmd+Shift+Enter`** (Mac) → runs in the active `ysql` terminal.

---

## Prerequisites

The devcontainer starts a **3-node cluster** (RF=3). Three nodes make the tablet-count difference visible: colocated tables show `num_tablets = 1`, distributed tables show `num_tablets = 3`.

Connect with:

```bash
ysqlsh -h 127.0.0.1           # yugabyte database (default)
ysqlsh -h 127.0.0.1 -d <db>   # connect to a specific database
```

---

## Running the demo

| Task | What it runs |
|---|---|
| **Terminal → Run Task → `colocate-demo`** | "The SaaS Catalog" (`prompt.sh`) |
| **Terminal → Run Task → `ysql`** | YSQL shell for the Workshop section below |

The demo walks through:
1. Baseline — standard non-colocated database: every table gets 3 tablets
2. Colocated database — small tables share 1 tablet
3. Opt-out — `WITH (COLOCATION = false)` keeps the orders table distributed (3 tablets)
4. Inspect with `yb_table_properties()` and `yb_is_database_colocated()`
5. EXPLAIN plan showing local vs distributed join behaviour

---

## Workshop

> Use the **`ysql`** terminal — it opens automatically when the container starts.

### Part 1: Non-colocated baseline

Create a standard database and see the default tablet allocation.

```sql
CREATE DATABASE saas_standard;
\c saas_standard

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
);
```

Check whether the database is colocated:

```sql
SELECT yb_is_database_colocated();
-- false
```

Inspect tablet counts:

```sql
SELECT c.relname       AS table_name,
       p.num_tablets,
       p.is_colocated
FROM   pg_class c,
       yb_table_properties(c.oid) p
WHERE  c.relnamespace = 'public'::regnamespace
  AND  c.relkind = 'r'
ORDER  BY c.relname;
```

Expected result (3-node, RF=3):

| table_name | num_tablets | is_colocated |
|---|---|---|
| orders | 3 | false |
| products | 3 | false |
| tenants | 3 | false |

→ 9 tablets total for 3 small tables.

---

### Part 2: Colocated database — default colocation

```sql
CREATE DATABASE saas_colocated WITH COLOCATION = true;
\c saas_colocated

SELECT yb_is_database_colocated();
-- true
```

Create the same tables. **No extra clause needed** — they are colocated by default in a colocated database.

```sql
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
```

Inspect:

```sql
SELECT c.relname       AS table_name,
       p.num_tablets,
       p.is_colocated,
       p.colocation_id
FROM   pg_class c,
       yb_table_properties(c.oid) p
WHERE  c.relnamespace = 'public'::regnamespace
  AND  c.relkind = 'r'
ORDER  BY c.relname;
```

Expected result:

| table_name | num_tablets | is_colocated | colocation_id |
|---|---|---|---|
| products | 1 | true | 20001 (auto) |
| tenants | 1 | true | 20002 (auto) |

→ Both tables share the **same parent tablet**. Joins between them never cross a tablet boundary.

---

### Part 3: Opt-out — high-volume table stays distributed

The orders table grows fast and needs to scale across all nodes. Use `WITH (COLOCATION = false)` to keep it distributed.

```sql
-- Still connected to saas_colocated

CREATE TABLE orders (
  id         BIGSERIAL PRIMARY KEY,
  tenant_id  INT REFERENCES tenants(id),
  product_id INT REFERENCES products(id),
  qty        INT,
  total      NUMERIC,
  created_at TIMESTAMPTZ DEFAULT NOW()
) WITH (COLOCATION = false);
```

Inspect all three tables together:

```sql
SELECT c.relname       AS table_name,
       p.num_tablets,
       p.is_colocated
FROM   pg_class c,
       yb_table_properties(c.oid) p
WHERE  c.relnamespace = 'public'::regnamespace
  AND  c.relkind = 'r'
ORDER  BY c.relname;
```

Expected result:

| table_name | num_tablets | is_colocated |
|---|---|---|
| orders | 3 | false |
| products | 1 | true |
| tenants | 1 | true |

→ `tenants` and `products` colocated (local joins), `orders` distributed (independent scale-out).

---

### Part 4: Seed data and compare query plans

```sql
INSERT INTO tenants(name, plan)
VALUES ('Acme Corp','pro'), ('Globex','starter'), ('Initech','enterprise');

INSERT INTO products(name, category, price)
VALUES ('Laptop','Electronics',999.00), ('Phone','Electronics',599.00),
       ('T-Shirt','Clothing',19.99),    ('Novel','Books',12.99);

INSERT INTO orders(tenant_id, product_id, qty, total)
SELECT 1 + mod(i,3), 1 + mod(i,4), 1 + mod(i,5),
       ((1 + mod(i,5)) * 9.99)::numeric(10,2)
FROM generate_series(1, 10000) i;
```

EXPLAIN a join between colocated tables:

```sql
EXPLAIN (COSTS OFF)
SELECT t.name AS tenant, p.name AS product, COUNT(*) AS order_count
FROM   orders o
JOIN   tenants  t ON o.tenant_id  = t.id
JOIN   products p ON o.product_id = p.id
GROUP  BY t.name, p.name
ORDER  BY order_count DESC;
```

Run the query:

```sql
SELECT t.name AS tenant, p.name AS product, COUNT(*) AS order_count
FROM   orders o
JOIN   tenants  t ON o.tenant_id  = t.id
JOIN   products p ON o.product_id = p.id
GROUP  BY t.name, p.name
ORDER  BY order_count DESC;
```

The join between `tenants` and `products` executes locally — both are on the same tablet. Only the join with `orders` (distributed) involves cross-tablet access.

---

### Part 5: Inspect individual tables

```sql
-- Single table
SELECT * FROM yb_table_properties('tenants'::regclass);
SELECT * FROM yb_table_properties('orders'::regclass);

-- All user tables at once
SELECT c.relname       AS table_name,
       p.num_tablets,
       p.is_colocated,
       p.colocation_id
FROM   pg_class c,
       yb_table_properties(c.oid) p
WHERE  c.relnamespace = 'public'::regnamespace
  AND  c.relkind = 'r'
ORDER  BY c.relname;
```

`colocation_id` is non-zero for colocated tables and identifies which parent tablet they share. All tables with the same `colocation_id` are on the same tablet.

---

## Key API reference

| Syntax | What it does |
|---|---|
| `CREATE DATABASE d WITH COLOCATION = true` | All tables colocated by default |
| `CREATE TABLE t (...) WITH (COLOCATION = false)` | Opt out: table gets its own distributed tablets |
| `yb_is_database_colocated()` | Returns `true`/`false` for the current database |
| `yb_table_properties(relid)` | Returns `num_tablets`, `is_colocated`, `colocation_id` |

## Decision guide

| Situation | Recommendation |
|---|---|
| Table < ~500 MB, read-heavy, frequently joined | Colocate (default in colocated DB) |
| High write throughput or large range scans | Opt out: `WITH (COLOCATION = false)` |
| Table needs `SPLIT INTO` pre-splitting | Cannot colocate — use distributed |
| Multi-tenant app with small per-tenant schema | One colocated DB per tenant |

> **Note:** `SPLIT INTO` and colocated tables are incompatible in YugabyteDB. If a table requires pre-split tablets, create it with `WITH (COLOCATION = false)`.

---

> **Related exercises**
> - Distributed SQL & Sharding (`init-dsql`) — hash and range sharding, pre-splitting
> - Geo-distribution (`init-geo`) — tablespace-based data placement across regions
> - Tablespaces (`init-tablespace`) — moving data between placement zones online
