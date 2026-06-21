# PITR — Point-in-Time Recovery

[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/srinivasa-vasu/ybdb-vanguard?devcontainer_path=.devcontainer%2Finit-pitr%2Fdevcontainer.json)

Online, any-point database recovery on a YugabyteDB single-node cluster. Create a snapshot schedule, simulate accidental data loss (DELETE without WHERE, DROP TABLE), and restore the database to the exact second before the disaster — without stopping the cluster.

> **Related exercises**
> - DB Clone (`init-clone`) — instant copy-on-write database copies built on PITR snapshots
> - Time Travel (`init-tt`) — read-only flashback queries with `SET yb_read_time`

---

> **Run queries interactively**: Select any SQL block → **`Ctrl+Shift+Enter`** (Windows/Linux) or **`Cmd+Shift+Enter`** (Mac) → runs in the active terminal.

---

## Prerequisites

The devcontainer starts a **single-node cluster**. All exercises are self-contained — no external datasets needed.

Connect with:

```bash
ysqlsh -h 127.0.0.1
```

---

## Running the demo

| Task | What it runs |
|---|---|
| **Terminal → Run Task → `pitr-demo`** | "The 2 AM Incident" (`prompt.sh`) |
| **Terminal → Run Task → `pitr-ws`** | Workshop shell for manual commands below |

The demo walks through a realistic disaster-recovery scenario:

1. Confirm no active snapshot schedules
2. Enable PITR: snapshot every 2 minutes, retain 24 hours
3. Seed a `payments` table with 1,000 customer accounts
4. Wait for the first snapshot window to open (~2 min)
5. Record a safe restore point
6. Simulate a runaway `DELETE FROM payments;` — all 1,000 accounts gone
7. Restore the database online to the pre-delete timestamp
8. Verify all accounts are back with zero data loss

---

## Workshop

> Use the **`pitr-ws`** terminal — it opens automatically when the container starts. The **`pitr-demo`** terminal is for the guided walkthrough.

### Part 1 · Snapshot Schedules

A snapshot schedule defines the **interval** between automatic WAL compactions and the **retention** window during which you can restore to any second.

#### 1.1 Create a schedule

```bash
# Testing: snapshot every 2 minutes, keep history for 24 hours (1440 minutes)
yb-admin -master_addresses 127.0.0.1:7100 \
  create_snapshot_schedule 2 1440 ysql.yugabyte
```

Production guidance:

| Use case | Interval | Retention |
|---|---|---|
| **Production (recommended)** | **6 h (360 min)** | **24 h (1440 min)** |
| Dev / testing | 2 min | 24 h (1440 min) |

#### 1.2 Inspect the schedule

```bash
yb-admin -master_addresses 127.0.0.1:7100 list_snapshot_schedules
```

Output includes: schedule ID (UUID), interval, retention, and every snapshot taken so far.

#### 1.3 Delete a schedule

```bash
yb-admin -master_addresses 127.0.0.1:7100 \
  delete_snapshot_schedule <schedule_id>
```

---

### Part 2 · Recovering from Accidental DML

**Scenario**: `DELETE FROM payments;` with no `WHERE` clause.

#### Seed data

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

#### Enable PITR and wait for the first snapshot

```bash
yb-admin -master_addresses 127.0.0.1:7100 \
  create_snapshot_schedule 2 1440 ysql.yugabyte
```

Wait ~2 minutes. Confirm the first snapshot appears in the schedule output:

```bash
yb-admin -master_addresses 127.0.0.1:7100 list_snapshot_schedules
```

#### Record the safe restore point

```sql
-- Capture as Unix microseconds (most reliable restore format)
SELECT (EXTRACT(EPOCH FROM CURRENT_TIMESTAMP) * 1000000)::bigint AS pitr_ts_us;

-- Also handy: human-readable form alongside
SELECT
  (EXTRACT(EPOCH FROM CURRENT_TIMESTAMP) * 1000000)::bigint        AS pitr_ts_us,
  to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS UTC')   AS pitr_ts_human;
```

Note the microsecond value — you will pass it directly to `restore_snapshot_schedule`.

#### Simulate the disaster

```sql
DELETE FROM payments;
SELECT COUNT(*) FROM payments;   -- 0
```

#### Restore

Three accepted formats for the restore timestamp:

```bash
# 1. Get the schedule ID
yb-admin -master_addresses 127.0.0.1:7100 list_snapshot_schedules

# 2a. Restore using Unix microseconds (recommended — unambiguous)
yb-admin -master_addresses 127.0.0.1:7100 \
  restore_snapshot_schedule <schedule_id> 1748808600123456

# 2b. Restore using a YCQL timestamp string (with timezone offset)
yb-admin -master_addresses 127.0.0.1:7100 \
  restore_snapshot_schedule <schedule_id> "2025-06-01 14:30:00+0000"

# 2c. Restore relative to now (no timestamp capture needed)
yb-admin -master_addresses 127.0.0.1:7100 \
  restore_snapshot_schedule <schedule_id> minus 5m

yb-admin -master_addresses 127.0.0.1:7100 \
  restore_snapshot_schedule <schedule_id> minus 1h
```

The restore is **online** — the cluster stays up. Reconnect after a moment (the YSQL layer resets existing connections).

#### Verify

```sql
SELECT COUNT(*) AS restored_accounts FROM payments;           -- 1000
SELECT ROUND(SUM(balance), 2) AS restored_funds FROM payments;
SELECT id, customer, balance FROM payments ORDER BY id LIMIT 5;
```

---

### Part 3 · Recovering from Accidental DDL

**Scenario**: `DROP TABLE payments;` — PITR recovers schema and data in one atomic operation.

```sql
DROP TABLE payments;
\dt payments    -- no results
```

Run the same `restore_snapshot_schedule` command from Part 2. Both schema and data are restored together.

```sql
\dt payments
SELECT COUNT(*) FROM payments;    -- 1000
```

> PITR restores **schema + data together** — it is a full database-level point-in-time restore.

---

### Part 4 · PITR for YCQL Keyspaces

PITR works identically for YCQL using the `ycql.` prefix:

```bash
# Create a schedule for a YCQL keyspace
yb-admin -master_addresses 127.0.0.1:7100 \
  create_snapshot_schedule 2 1440 ycql.my_keyspace

# Restore a YCQL keyspace
yb-admin -master_addresses 127.0.0.1:7100 \
  restore_snapshot_schedule <schedule_id> "2025-06-01 14:30:00"
```

---

## Key mental models

```
PITR schedule
  interval   → how often a new snapshot is taken (1 min – hours)
  retention  → how far back in time you can restore (hours or days)
  scope      → one schedule per YSQL database or YCQL keyspace

restore_snapshot_schedule
  online     → cluster stays up; no downtime required
  atomic     → schema + data restored together in one operation
  any-point  → restore to ANY second within retention (not just snapshot boundaries)
  reconnect  → YSQL connections reset after restore; clients must reconnect
```

---

## Useful commands

```bash
# Create schedule (interval and retention both in MINUTES)
yb-admin -master_addresses 127.0.0.1:7100 \
  create_snapshot_schedule <interval_min> <retention_min> ysql.<dbname>

# List schedules (ID, last snapshot time, next snapshot time)
yb-admin -master_addresses 127.0.0.1:7100 list_snapshot_schedules

# Restore — Unix microseconds (recommended)
yb-admin -master_addresses 127.0.0.1:7100 \
  restore_snapshot_schedule <schedule_id> <unix_microseconds>

# Restore — YCQL timestamp string (with timezone offset)
yb-admin -master_addresses 127.0.0.1:7100 \
  restore_snapshot_schedule <schedule_id> "2025-06-01 14:30:00+0000"

# Restore — relative offset
yb-admin -master_addresses 127.0.0.1:7100 \
  restore_snapshot_schedule <schedule_id> minus 5m

yb-admin -master_addresses 127.0.0.1:7100 \
  restore_snapshot_schedule <schedule_id> minus 1h

# Check restore progress
yb-admin -master_addresses 127.0.0.1:7100 list_snapshots SHOW_DETAILS

# Delete a schedule
yb-admin -master_addresses 127.0.0.1:7100 \
  delete_snapshot_schedule <schedule_id>

# Capture the current time as Unix microseconds (for use in restore command)
ysqlsh -h 127.0.0.1 -c "SELECT (EXTRACT(EPOCH FROM CURRENT_TIMESTAMP) * 1000000)::bigint AS ts_us;"

# Connect to YSQL
ysqlsh -h 127.0.0.1
```
