# Tablespaces & Online Data Migration

[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/srinivasa-vasu/ybdb-vanguard?devcontainer_path=.devcontainer%2Finit-tablespace%2Fdevcontainer.json)

Create placement-aware tablespaces, pin tables and indexes to specific regions, and migrate data between tablespaces online — without stopping the cluster.

**Quick start:** The `tablespace-demo` terminal opens automatically — run `bash prompt.sh` for the guided demo.

---

> **Run queries interactively**: Select any SQL block → **`Ctrl+Shift+Enter`** (Windows/Linux) or **`Cmd+Shift+Enter`** (Mac) → runs in the active terminal.

---

## What are tablespaces in YugabyteDB?

A tablespace controls **where tablets are placed** — which cloud provider, region, and availability zone. Each tablespace carries a `replica_placement` JSON that specifies the placement constraints for all tables and indexes assigned to it.

This is useful for:
- **Data sovereignty**: keep EU customer data in EU nodes
- **Latency pinning**: put hot tables in the closest region
- **Tiered storage**: age cold data to cheaper/distant nodes
- **Online migration**: move existing tables between regions without downtime

## Key API (all GA)

```sql
-- Create a tablespace pinned to a region
CREATE TABLESPACE us_east_ts WITH (
  replica_placement = '{
    "num_replicas": 1,
    "placement_blocks": [{
      "cloud": "ybcloud", "region": "us-east",
      "zone": "us-east-az1", "min_num_replicas": 1
    }]
  }'
);

-- Pin a table at creation time
CREATE TABLE orders ( ... ) TABLESPACE us_east_ts;

-- Move an existing table online (non-blocking; tablets rebalance in background)
ALTER TABLE orders SET TABLESPACE eu_west_ts;

-- Move an index to match
ALTER INDEX orders_pkey SET TABLESPACE eu_west_ts;

-- Session default: all new tables go to this tablespace
SET default_tablespace TO us_east_ts;
RESET default_tablespace;  -- restore to pg_default
```

## What the demo shows

| Part | What it covers |
|---|---|
| **1 — Cluster labels** | `yb_servers()` shows cloud/region/zone per node |
| **2 — Create tablespaces** | 3 tablespaces, one per region (us-east, eu-west, ap-south) |
| **3 — Pin tables at creation** | `CREATE TABLE ... TABLESPACE` for orders, archive, products |
| **4 — Seed data** | Insert sample rows |
| **5 — Online migration** | `ALTER TABLE ... SET TABLESPACE` — live move, no downtime |
| **6 — Session default** | `SET default_tablespace` makes subsequent creates land on a region |

## Inspect tablespace assignments

```sql
-- Tables and their tablespace
SELECT tablename, tablespace
FROM   pg_tables
WHERE  schemaname = 'public'
ORDER  BY tablename;

-- Indexes and their tablespace
SELECT indexname, tablespace
FROM   pg_indexes
WHERE  schemaname = 'public'
ORDER  BY indexname;

-- All user-defined tablespaces and placement JSON
SELECT spcname, spcoptions
FROM   pg_tablespace
WHERE  spcname NOT IN ('pg_default', 'pg_global');
```

---

## Manual exercises

Connect to the cluster before starting:

```bash
ysqlsh   # opens a YSQL shell on 127.0.0.1:5433
```

---

### Part 1: Check cluster node placement labels

Every node in a YugabyteDB cluster is stamped with a `cloud`, `region`, and `zone` label at startup. Tablespace placement policies reference these exact labels — the JSON you write in `replica_placement` must match what the nodes report.

```sql
SELECT host, port, cloud, region, zone
FROM   yb_servers()
ORDER  BY region;
```

Expected output (3-node cluster):

```
     host    | port |  cloud  |  region  |     zone
-------------+------+---------+----------+--------------
 127.0.0.3   | 5433 | ybcloud | ap-south | ap-south-az1
 127.0.0.2   | 5433 | ybcloud | eu-west  | eu-west-az1
 127.0.0.1   | 5433 | ybcloud | us-east  | us-east-az1
(3 rows)
```

Key fields:
- **cloud** — cloud provider label (e.g. `ybcloud`, `aws`, `gcp`)
- **region** — region label (e.g. `us-east`, `eu-west`, `ap-south`)
- **zone** — availability zone label (e.g. `us-east-az1`)

These labels are set with `--placement_cloud`, `--placement_region`, and `--placement_zone` flags when starting `yugabyted`. All three fields together form the placement key used in tablespace `replica_placement` JSON.

---

### Part 2: Create tablespaces

Create one tablespace per region. Each tablespace pins its tablets to a single node in the matching zone.

```sql
-- US East tablespace
CREATE TABLESPACE us_east_ts WITH (
  replica_placement = '{
    "num_replicas": 1,
    "placement_blocks": [{
      "cloud": "ybcloud",
      "region": "us-east",
      "zone": "us-east-az1",
      "min_num_replicas": 1
    }]
  }'
);

-- EU West tablespace
CREATE TABLESPACE eu_west_ts WITH (
  replica_placement = '{
    "num_replicas": 1,
    "placement_blocks": [{
      "cloud": "ybcloud",
      "region": "eu-west",
      "zone": "eu-west-az1",
      "min_num_replicas": 1
    }]
  }'
);

-- AP South tablespace
CREATE TABLESPACE ap_south_ts WITH (
  replica_placement = '{
    "num_replicas": 1,
    "placement_blocks": [{
      "cloud": "ybcloud",
      "region": "ap-south",
      "zone": "ap-south-az1",
      "min_num_replicas": 1
    }]
  }'
);
```

Verify all three were created:

```sql
SELECT spcname, spcoptions
FROM   pg_tablespace
WHERE  spcname NOT IN ('pg_default', 'pg_global');
```

Expected output:

```
   spcname    |                                              spcoptions
--------------+-------------------------------------------------------------------------------------------------------
 ap_south_ts  | {replica_placement={"num_replicas":1,"placement_blocks":[{"cloud":"ybcloud","region":"ap-south",...}]}}
 eu_west_ts   | {replica_placement={"num_replicas":1,"placement_blocks":[{"cloud":"ybcloud","region":"eu-west",...}]}}
 us_east_ts   | {replica_placement={"num_replicas":1,"placement_blocks":[{"cloud":"ybcloud","region":"us-east",...}]}}
(3 rows)
```

---

### Part 3: Create tables pinned to tablespaces

Specify `TABLESPACE` at the end of `CREATE TABLE`. The primary key index inherits the same tablespace automatically.

```sql
-- orders table pinned to US East
CREATE TABLE orders (
  id         SERIAL PRIMARY KEY,
  customer   TEXT        NOT NULL,
  amount     NUMERIC(12,2),
  created_at TIMESTAMPTZ DEFAULT now()
) TABLESPACE us_east_ts;

-- orders_archive pinned to EU West
CREATE TABLE orders_archive (
  id         BIGINT PRIMARY KEY,
  customer   TEXT        NOT NULL,
  amount     NUMERIC(12,2),
  archived_at TIMESTAMPTZ DEFAULT now()
) TABLESPACE eu_west_ts;

-- products pinned to AP South
CREATE TABLE products (
  id    SERIAL PRIMARY KEY,
  name  TEXT   NOT NULL,
  price NUMERIC(10,2)
) TABLESPACE ap_south_ts;
```

Verify table placement:

```sql
SELECT tablename, tablespace
FROM   pg_tables
WHERE  schemaname = 'public'
ORDER  BY tablename;
```

Expected output:

```
    tablename     |  tablespace
------------------+-------------
 orders           | us_east_ts
 orders_archive   | eu_west_ts
 products         | ap_south_ts
(3 rows)
```

Verify that primary key indexes inherited the same tablespace:

```sql
SELECT indexname, tablespace
FROM   pg_indexes
WHERE  schemaname = 'public'
ORDER  BY indexname;
```

Expected output:

```
       indexname        |  tablespace
------------------------+-------------
 orders_archive_pkey    | eu_west_ts
 orders_pkey            | us_east_ts
 products_pkey          | ap_south_ts
(3 rows)
```

Insert some sample rows so there is data to move in later parts:

```sql
INSERT INTO orders (customer, amount)
  SELECT 'Customer ' || i, (random() * 500 + 10)::NUMERIC(12,2)
  FROM generate_series(1, 50) i;

INSERT INTO products (name, price)
  SELECT 'Product ' || i, (random() * 200 + 5)::NUMERIC(10,2)
  FROM generate_series(1, 20) i;

SELECT COUNT(*) FROM orders;    -- 50
SELECT COUNT(*) FROM products;  -- 20
```

---

### Part 4: Move a table online — ALTER TABLE SET TABLESPACE

`ALTER TABLE SET TABLESPACE` updates the placement config immediately and then rebalances tablets in the background. The table remains fully readable and writable during the move.

Move `products` from `ap_south_ts` to `us_east_ts`:

```sql
ALTER TABLE products SET TABLESPACE us_east_ts;
```

The catalog is updated instantly. Verify:

```sql
SELECT tablename, tablespace
FROM   pg_tables
WHERE  schemaname = 'public'
ORDER  BY tablename;
```

Expected — `products` now shows `us_east_ts`:

```
    tablename     |  tablespace
------------------+-------------
 orders           | us_east_ts
 orders_archive   | eu_west_ts
 products         | us_east_ts
(3 rows)
```

The primary key index does **not** move automatically — move it separately:

```sql
ALTER INDEX products_pkey SET TABLESPACE us_east_ts;
```

Verify indexes:

```sql
SELECT indexname, tablespace
FROM   pg_indexes
WHERE  schemaname = 'public'
ORDER  BY indexname;
```

Expected — `products_pkey` now shows `us_east_ts`:

```
       indexname        |  tablespace
------------------------+-------------
 orders_archive_pkey    | eu_west_ts
 orders_pkey            | us_east_ts
 products_pkey          | us_east_ts
(3 rows)
```

> **Note:** The move is asynchronous. The catalog change is instantaneous but the underlying tablet data rebalances in the background via the YugabyteDB load balancer. Open the yugabyted UI (`PORTS → 15433`) to watch tablet movement progress. Reads and writes continue uninterrupted during rebalancing.

---

### Part 5: Move an index independently

An index can live in a different tablespace from its parent table. This is valid and useful — for example, keep the table in a low-cost region but put a hot index in a fast region.

Create a secondary index on `orders` and place it in `eu_west_ts`:

```sql
CREATE INDEX orders_customer_idx
  ON orders (customer)
  TABLESPACE eu_west_ts;
```

Verify — the table is in `us_east_ts` but the new index is in `eu_west_ts`:

```sql
SELECT tablename, tablespace
FROM   pg_tables
WHERE  schemaname = 'public' AND tablename = 'orders';
```

```
 tablename | tablespace
-----------+------------
 orders    | us_east_ts
(1 row)
```

```sql
SELECT indexname, tablespace
FROM   pg_indexes
WHERE  schemaname = 'public' AND tablename = 'orders'
ORDER  BY indexname;
```

```
       indexname        |  tablespace
------------------------+-------------
 orders_customer_idx    | eu_west_ts
 orders_pkey            | us_east_ts
(2 rows)
```

Table and indexes can be in different tablespaces — the query planner handles this transparently.

---

### Part 6: Session default_tablespace

`SET default_tablespace` tells YSQL which tablespace to use for any `CREATE TABLE` or `CREATE INDEX` statement in the current session that does not specify a tablespace explicitly.

```sql
SET default_tablespace TO eu_west_ts;
```

Create a table without specifying a tablespace:

```sql
CREATE TABLE session_test (
  id   SERIAL PRIMARY KEY,
  note TEXT
);
```

Verify it landed on `eu_west_ts`:

```sql
SELECT tablename, tablespace
FROM   pg_tables
WHERE  schemaname = 'public' AND tablename = 'session_test';
```

Expected:

```
  tablename   | tablespace
--------------+------------
 session_test | eu_west_ts
(1 row)
```

Reset the session default back to the cluster default:

```sql
RESET default_tablespace;
```

Create another table — this time it uses the cluster default (`pg_default`), which means no pinning:

```sql
CREATE TABLE session_test2 (
  id   SERIAL PRIMARY KEY,
  note TEXT
);

SELECT tablename, tablespace
FROM   pg_tables
WHERE  schemaname = 'public' AND tablename = 'session_test2';
```

Expected — `tablespace` is NULL, meaning the cluster-level default placement applies:

```
   tablename   | tablespace
---------------+------------
 session_test2 |
(1 row)
```

Clean up:

```sql
DROP TABLE session_test, session_test2;
```

---

## Limitations

- `ALTER TABLE SET TABLESPACE` is **asynchronous**: the config updates immediately but tablet rebalancing happens in the background via the YugabyteDB load balancer. Use the yugabyted UI (`PORTS → 15433`) to monitor tablet movement.
- **Colocation + tablespace** is an Early Access feature (disabled by default). Enable with master flag `--ysql_enable_colocated_tables_with_tablespaces=true`.

---

> **Related exercises**
> - Geo-distribution (`init-geo`) — geo-partitioned tables, follower reads, tablespace-based routing
> - Colocation (`init-colocate`) — colocating small tables on a shared tablet
