# DB Clone

[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/srinivasa-vasu/ybdb-vanguard?devcontainer_path=.devcontainer%2Finit-clone%2Fdevcontainer.json)

Instant database copies from any point in time — using a single SQL statement. No dump, no separate environment, no extra storage for unchanged data. Clone production to test a migration, create an isolated rollback baseline, or reproduce a past state for debugging.

---

## Prerequisites

The devcontainer starts a **single-node cluster** with `enable_db_clone=true`. All exercises are self-contained — the demo script seeds its own data and creates a PITR snapshot schedule if one is not already active.

> Point-in-time clones (`AS OF`) require an active PITR snapshot schedule on the source database. The demo handles this automatically. For current-state clones (no `AS OF`), no schedule is needed.

Connect with:

```bash
ysqlsh            # default yugabyte database
ysqlsh -d <db>    # connect to a cloned database
```

---

## Running the demo

| Task | What it runs |
|---|---|
| **Terminal → Run Task → `clone-demo`** | "The Safe Migration Runway" (`prompt.sh`) |
| **Terminal → Run Task → `ysql`** | YSQL shell for SQL commands in Workshop below |
| **Terminal → Run Task → `clone-ws`** | Workshop shell for `yb-admin` commands below |

The demo walks through a schema-migration scenario:

1. Verify (or create) a PITR schedule on the `yugabyte` database
2. Seed a `payments` table with 1,000 customer accounts
3. Apply a production upgrade — Premier enrollments + 20 corporate accounts
4. **Current-state clone** → `payments_dev` (`CREATE DATABASE payments_dev TEMPLATE yugabyte`)
5. Apply migration on the clone: `ALTER TABLE payments ADD COLUMN tier TEXT`
6. Verify production schema is untouched
7. **Point-in-time clone** → `payments_baseline` (`CREATE DATABASE payments_baseline TEMPLATE yugabyte AS OF '<timestamp>'`)
8. Three-way comparison: production vs dev-clone vs baseline-clone

---

## Workshop

> Use the **`ysql`** terminal for SQL commands. For `yb-admin` commands, use the **`clone-ws`** terminal — both open automatically when the container starts.

### Step 0: Enable PITR on the source database

Required only for point-in-time clones. Skip for current-state clones.

```bash
yb-admin -master_addresses 127.0.0.1:7100 \
  create_snapshot_schedule 2 1440 ysql.yugabyte
```

Wait ~2 minutes for the first snapshot, then confirm:

```bash
yb-admin -master_addresses 127.0.0.1:7100 list_snapshot_schedules
```

### Step 1: Seed data

```sql
DROP TABLE IF EXISTS payments;

CREATE TABLE payments (
  id       SERIAL          PRIMARY KEY,
  customer TEXT            NOT NULL,
  balance  NUMERIC(12, 2)  NOT NULL
);

INSERT INTO payments (customer, balance)
  SELECT 'Customer ' || i, (random() * 9000 + 1000)::NUMERIC(12, 2)
  FROM generate_series(1, 1000) i;

SELECT COUNT(*) AS total, ROUND(SUM(balance), 2) AS total_funds FROM payments;
```

---

### Part 1 · Current-state clone

Clone the database as it is right now — no PITR schedule required.

#### 1.1 Create the clone

```sql
CREATE DATABASE payments_dev TEMPLATE yugabyte;
```

#### 1.2 Monitor clone status

```sql
SELECT db_name AS target_db_name, parent_db_name AS source_db_name, state, as_of_time, failed_reason
FROM yb_database_clones();
```

#### 1.3 Connect and verify

```bash
ysqlsh -d payments_dev -c "SELECT COUNT(*), ROUND(SUM(balance), 2) FROM payments;"
```

#### 1.4 Modify the clone — production stays unchanged

```sql
-- Connect to the clone
\c payments_dev

ALTER TABLE payments ADD COLUMN tier TEXT;

UPDATE payments SET tier =
  CASE
    WHEN balance >= 20000 THEN 'corporate'
    WHEN balance >= 8000  THEN 'premier'
    ELSE                       'standard'
  END;

SELECT tier, COUNT(*) AS accounts, ROUND(AVG(balance), 2) AS avg_balance
FROM payments
GROUP BY tier ORDER BY avg_balance DESC;
```

#### 1.5 Verify production is unchanged

```sql
\c yugabyte
\d payments              -- no tier column
SELECT COUNT(*) FROM payments;   -- still 1000
```

---

### Part 2 · Point-in-time clone

Clone the database to a specific moment in the past.

#### 2.1 Capture a baseline timestamp

```sql
-- Capture with microsecond precision (matching the AS OF format)
SELECT to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS.US') AS baseline_ts;
-- example: 2024-08-08 19:51:43.674480
```

#### 2.2 Make production changes after the baseline

```sql
UPDATE payments SET customer = customer || ' (Premier)' WHERE balance > 8000;

INSERT INTO payments (customer, balance)
  SELECT 'Corp Account ' || i, (random() * 50000 + 20000)::NUMERIC(12,2)
  FROM generate_series(1, 20) i;

SELECT COUNT(*) FROM payments;   -- 1020
```

#### 2.3 Clone to the baseline (before changes)

```sql
-- Using a PostgreSQL timestamp string
CREATE DATABASE payments_baseline
  TEMPLATE yugabyte
  AS OF '2024-08-08 19:51:43.674480';

-- Or using Unix microseconds
CREATE DATABASE payments_baseline
  TEMPLATE yugabyte
  AS OF 1723146703674480;
```

#### 2.4 Verify the baseline clone

```sql
\c payments_baseline

SELECT COUNT(*) FROM payments;                                   -- 1000 (pre-upgrade)
SELECT COUNT(*) FROM payments WHERE customer LIKE '%Premier%';   -- 0
```

---

### Part 3 · Cross-database comparison

Query all three databases in a single statement using `<db>.<schema>.<table>` notation:

```sql
SELECT 'yugabyte (production)'  AS database, COUNT(*) AS accounts FROM yugabyte.public.payments
UNION ALL
SELECT 'payments_dev',                        COUNT(*) FROM payments_dev.public.payments
UNION ALL
SELECT 'payments_baseline',                   COUNT(*) FROM payments_baseline.public.payments;
```

---

### Part 4 · Clone a YCQL keyspace

YCQL cloning uses `yb-admin` with a Unix microsecond timestamp:

```bash
# Clone to current state (omit timestamp)
yb-admin --master_addresses 127.0.0.1:7100 \
  clone_namespace ycql.my_keyspace my_keyspace_dev

# Clone to a specific point in time (Unix microseconds)
yb-admin --master_addresses 127.0.0.1:7100 \
  clone_namespace ycql.my_keyspace my_keyspace_baseline 1723146703674480
```

---

### Part 5 · Monitor and manage clones

```sql
-- List all clones (source, target, state, timestamp)
SELECT * FROM yb_database_clones();

-- Drop a clone when done
DROP DATABASE payments_dev;
DROP DATABASE payments_baseline;
```

---

## Key mental models

```
CREATE DATABASE clone TEMPLATE source
  current state    → no AS OF; copies the live database right now
  point-in-time    → AS OF '<timestamp>' or AS OF <unix_microseconds>
  copy-on-write    → only diverging blocks use additional storage
  isolated         → writes to the clone never affect the source (and vice versa)
  requires         → enable_db_clone=true master flag
  AS OF requires   → an active PITR snapshot schedule on the source

yb_database_clones()
  monitors         → shows source_db_name, target_db_name, state, clone_time
  state values     → INITIATED → CLONING → COMPLETE (or FAILED)

clone vs PITR restore
  PITR restore     → overwrites the live database; destructive
  clone            → creates a new independent database; non-destructive
```

---

## Useful commands

```sql
-- Current-state clone (no PITR schedule needed)
CREATE DATABASE <target_db> TEMPLATE <source_db>;

-- Point-in-time clone — PostgreSQL timestamp format
CREATE DATABASE <target_db> TEMPLATE <source_db> AS OF '2024-08-08 19:51:43.674480';

-- Point-in-time clone — Unix microseconds
CREATE DATABASE <target_db> TEMPLATE <source_db> AS OF 1723146703674480;

-- Monitor clone progress
SELECT source_db_name, target_db_name, state, clone_time FROM yb_database_clones();

-- Connect to a clone
\c <target_db>

-- Drop a clone when done
DROP DATABASE <target_db>;

-- Capture current timestamp with microsecond precision
SELECT to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS.US') AS ts;
```

```bash
# YCQL clone (yb-admin, Unix microseconds)
yb-admin --master_addresses 127.0.0.1:7100 \
  clone_namespace ycql.<source_keyspace> <target_keyspace> [<unix_microseconds>]

# Create a PITR schedule (required for AS OF clones)
yb-admin -master_addresses 127.0.0.1:7100 \
  create_snapshot_schedule <interval_min> <retention_min> ysql.<dbname>
```
