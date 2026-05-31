# Time Travel — `yb_read_time`

[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/srinivasa-vasu/ybdb-vanguard?devcontainer_path=.devcontainer%2Finit-tt%2Fdevcontainer.json)

Read historical snapshots of your database by setting a session-level read timestamp. `SET yb_read_time` moves all subsequent reads in the session to a specific point in the past — the live data is never modified. Use it for compliance audits, forensic investigation, and before/after comparisons.

---

> **Run queries interactively**: Select any SQL block → **`Ctrl+Shift+Enter`** (Windows/Linux) or **`Cmd+Shift+Enter`** (Mac) → runs in the active terminal.

---

## Prerequisites

The devcontainer starts a **single-node cluster**. No PITR snapshot schedule is required — time travel uses the cluster's built-in MVCC history.

**Default flashback window**: 900 seconds (15 minutes).  
Controlled by the tserver flag `timestamp_history_retention_interval_sec`.  
For lookbacks beyond 15 minutes, use the PITR exercise (`init-pitr`).

Connect with:

```bash
ysqlsh
```

---

## Running the demo

| Task | What it runs |
|---|---|
| **Terminal → Run Task → `tt-demo`** | "The Compliance Audit" (`prompt.sh`) |

The demo walks through a forensic investigation scenario:

1. Seed a `payments` table with 1,000 accounts
2. Capture the audit timestamp in Unix microseconds
3. Simulate two suspicious events: 50 accounts drained to 10% + 15 accounts deleted
4. **Query 1** — `SET yb_read_time` to the audit timestamp → count and sum before the incident
5. **Query 2** — compare specific drained accounts before vs after
6. **Query 3** — read deleted accounts from the past; confirm they are gone now
7. Reset and summary

---

## How it works

YugabyteDB time travel is session-scoped. Set `yb_read_time` to a Unix timestamp in **microseconds** and every subsequent `SELECT` in that session reads from that point in time.

```sql
-- 1. Capture the current moment as microseconds
SELECT (EXTRACT(EPOCH FROM CURRENT_TIMESTAMP) * 1000000)::bigint AS ts_us;
-- example output: 1748808600123456

-- 2. Travel to that moment in a later query
SET yb_read_time TO 1748808600123456;

-- 3. All reads now come from that past snapshot
SELECT COUNT(*), ROUND(SUM(balance), 2) FROM payments;

-- 4. Return to the present
SET yb_read_time TO 0;
```

> **Key constraint**: `INSERT`, `UPDATE`, `DELETE`, and DDL are **rejected** when `yb_read_time` is set to a past timestamp. The session is effectively read-only until you reset it.

---

## Manual exercises

### Setup

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

### Part 1 · Capturing a read timestamp

Always capture the timestamp **before** making the changes you want to look back past.

```sql
-- Capture as microseconds (required by yb_read_time)
SELECT (EXTRACT(EPOCH FROM CURRENT_TIMESTAMP) * 1000000)::bigint AS ts_us;

-- Also handy: capture a human-readable form alongside
SELECT
  (EXTRACT(EPOCH FROM CURRENT_TIMESTAMP) * 1000000)::bigint          AS ts_us,
  to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS UTC')     AS ts_human;
```

---

### Part 2 · Basic point-in-time reads

```sql
-- Travel to the captured timestamp
SET yb_read_time TO 1748808600123456;   -- replace with your value

-- How many accounts existed then?
SELECT COUNT(*), ROUND(SUM(balance), 2) AS total_funds FROM payments;

-- Was this specific account modified?
SELECT id, customer, balance FROM payments WHERE id = 42;

-- Return to the present
SET yb_read_time TO 0;

-- Same queries at current time for comparison
SELECT COUNT(*), ROUND(SUM(balance), 2) FROM payments;
SELECT id, customer, balance FROM payments WHERE id = 42;
```

---

### Part 3 · Before/after comparison for changed rows

Because `yb_read_time` makes the session read-only, compare past and present using two separate queries:

```sql
-- Step 1: note the current timestamp in microseconds
SELECT (EXTRACT(EPOCH FROM CURRENT_TIMESTAMP) * 1000000)::bigint AS ts_us;
-- → 1748808600123456

-- Step 2: make some changes
UPDATE payments SET balance = balance * 0.10 WHERE id % 20 = 0;
DELETE FROM payments WHERE balance > 9500 AND id <= 100;

-- Step 3a: read balances from the past (before the changes)
SET yb_read_time TO 1748808600123456;
SELECT id, customer, balance AS balance_before
FROM payments
WHERE id % 20 = 0
ORDER BY id
LIMIT 10;
SET yb_read_time TO 0;

-- Step 3b: read the same rows now
SELECT id, customer, balance AS balance_after
FROM payments
WHERE id % 20 = 0
ORDER BY id
LIMIT 10;
```

---

### Part 4 · Reading deleted rows

Rows deleted after the captured timestamp are still visible when `yb_read_time` points to before the delete.

```sql
-- Step 1: set the read time to before the deletes
SET yb_read_time TO 1748808600123456;

-- Step 2: these rows exist in the past snapshot
SELECT id, customer, balance AS last_known_balance
FROM payments
WHERE balance > 9500 AND id <= 100
ORDER BY balance DESC;

-- Step 3: reset and confirm they are gone now
SET yb_read_time TO 0;

SELECT COUNT(*) AS count_now
FROM payments
WHERE balance > 9500 AND id <= 100;
-- → 0
```

---

### Part 5 · Aggregate audit at a past timestamp

```sql
SET yb_read_time TO 1748808600123456;

SELECT
  COUNT(*)                                AS total_accounts,
  ROUND(SUM(balance), 2)                  AS total_funds,
  ROUND(AVG(balance), 2)                  AS avg_balance,
  ROUND(MIN(balance), 2)                  AS min_balance,
  ROUND(MAX(balance), 2)                  AS max_balance
FROM payments;

SET yb_read_time TO 0;
```

---

### Part 6 · Checking the current read time setting

```sql
-- Returns 0 if reading from the present, or the microsecond timestamp if in the past
SHOW yb_read_time;
```

---

### Part 7 · Retention window and limitations

#### Default window

The flashback window is controlled by the tserver flag `timestamp_history_retention_interval_sec` (default **900 seconds / 15 minutes**). Reads beyond this window return:

```
ERROR:  Read query with old read point ...
```

For longer lookbacks, use PITR (`restore_snapshot_schedule`) from the `init-pitr` exercise or DB Clone from `init-clone`.

#### Constraints when `yb_read_time` is set to the past

| Operation | Allowed? |
|---|---|
| `SELECT` | ✅ Yes |
| `INSERT` / `UPDATE` / `DELETE` | ❌ Rejected |
| `CREATE` / `ALTER` / `DROP` | ❌ Rejected |
| Reads on temp tables | ❌ Not supported |
| Reads past a DDL change | ❌ Read time must be after the last schema change |

Always reset with `SET yb_read_time TO 0` before running any writes.

---

## Comparison: time travel vs PITR vs Clone

| | `yb_read_time` | PITR restore | DB Clone |
|---|---|---|---|
| Changes live DB | No — read-only | Yes — overwrites | No — new database |
| Flashback window | ~15 min (MVCC) | Any (retention) | Any (retention) |
| PITR schedule required | No | Yes | Yes |
| Writes allowed during | No | N/A | Yes (on the clone) |
| Best for | Audit, investigate | Disaster recovery | Dev/test copies |

---

## Key mental models

```
yb_read_time
  session-scoped   → only affects the current YSQL session
  microseconds     → Unix timestamp × 1,000,000
  read-only        → writes are rejected when set to a past time
  reset            → SET yb_read_time TO 0 returns to the present
  window           → default 900 s; controlled by timestamp_history_retention_interval_sec
  no schedule      → uses MVCC history; no PITR setup needed
```

---

## Useful commands

```bash
# Connect to YSQL
ysqlsh
```

```sql
-- Capture the current timestamp in microseconds
SELECT (EXTRACT(EPOCH FROM CURRENT_TIMESTAMP) * 1000000)::bigint AS ts_us;

-- Travel to a past timestamp
SET yb_read_time TO <microseconds>;

-- Run read queries at that point in time
SELECT ... FROM table;

-- Return to the present
SET yb_read_time TO 0;

-- Check the current session read time (0 = present)
SHOW yb_read_time;

-- Capture both forms at once
SELECT
  (EXTRACT(EPOCH FROM CURRENT_TIMESTAMP) * 1000000)::bigint        AS ts_us,
  to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS UTC')   AS ts_human;
```
