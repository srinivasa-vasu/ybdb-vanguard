# xCluster Replication — Automatic Transactional Mode

[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/srinivasa-vasu/ybdb-vanguard?devcontainer_path=.devcontainer%2Finit-xcluster%2Fdevcontainer.json)

Set up transactional xCluster replication with **automatic DDL propagation** between two universes. Schema changes (CREATE TABLE, ALTER TABLE, DROP TABLE) run only on the primary — the standby receives them automatically. No manual DDL on the standby ever needed.

**Requires YugabyteDB v2025.2.1+** (this devcontainer runs v2025.2.x ✓)

**Quick start:** Two terminals open automatically:
- **`xcluster-demo`** — guided demo: run `bash prompt.sh` for the full walkthrough
- **`xcluster-ws`** — Workshop shell for the manual commands below

---

> **Run queries interactively**: Select any SQL block → **`Ctrl+Shift+Enter`** (Windows/Linux) or **`Cmd+Shift+Enter`** (Mac) → runs in the active terminal.

---

## Cluster layout

| | Primary | Standby (DR) |
|---|---|---|
| Role | Active, writable | Replica, read-only |
| YSQL | `ysqlsh -h 127.0.0.1` | `ysqlsh -h 127.0.0.11` |
| Masters | `127.0.0.1:7100` | `127.0.0.11:7100` |

## Setup workflow (all `yb-admin`, no YBA required)

```bash
# Step 1 — Checkpoint on PRIMARY (marks WAL start position)
yb-admin --master_addresses 127.0.0.1:7100 \
  create_xcluster_checkpoint demo yugabyte automatic_ddl_mode

# Step 2 — Distributed snapshot: full copy primary → standby
yb-admin --master_addresses 127.0.0.1:7100 create_database_snapshot ysql.yugabyte
# (list_snapshots → note SNAP_ID, then:)
yb-admin --master_addresses 127.0.0.1:7100 export_snapshot <SNAP_ID> /tmp/snapshot.json
ysqlsh -h 127.0.0.11 -c "CREATE TABLE ..."   # recreate schema on standby
yb-admin --master_addresses 127.0.0.11:7100 import_snapshot /tmp/snapshot.json yugabyte
# (note NEW ID from import output, copy tablet SST dirs, then:)
yb-admin --master_addresses 127.0.0.11:7100 restore_snapshot <NEW_SNAP_ID>

# Step 3 — PITR on STANDBY (required for failover consistency)
yb-admin --master_addresses 127.0.0.11:7100 \
  create_snapshot_schedule 2 30 ysql.yugabyte

# Step 4 — Setup replication (runs on PRIMARY, points to standby)
yb-admin --master_addresses 127.0.0.1:7100 \
  setup_xcluster_replication demo 127.0.0.11:7100
```

### `yugabyted` equivalents (simpler syntax)

```bash
# Checkpoint
yugabyted xcluster create_checkpoint \
  --replication_id demo --databases yugabyte --automatic_mode

# Set up replication
yugabyted xcluster set_up \
  --replication_id demo --target_address 127.0.0.11 --bootstrap_done
```

---

## Workshop

> Use the **`xcluster-ws`** terminal — it opens automatically when the container starts. The **`xcluster-demo`** terminal is for the guided walkthrough.

These exercises walk through every setup and validation step by hand — no `prompt.sh` required. Run each command in the terminal that matches the note (primary or standby).

---

### Step 1: Start both clusters and verify connectivity

Confirm both clusters are up and reachable before touching any replication commands.

```bash
# Primary cluster
ysqlsh -h 127.0.0.1 -c "SELECT version();"
```

Expected — PostgreSQL-compatible version string from the primary:

```
                                    version
--------------------------------------------------------------------------------
 PostgreSQL 11.2-YB-2025.2.x.x-b0 on x86_64-pc-linux-gnu, compiled by gcc ...
(1 row)
```

```bash
# Standby cluster
ysqlsh -h 127.0.0.11 -c "SELECT version();"
```

Expected — same version string from the standby:

```
                                    version
--------------------------------------------------------------------------------
 PostgreSQL 11.2-YB-2025.2.x.x-b0 on x86_64-pc-linux-gnu, compiled by gcc ...
(1 row)
```

Both clusters must report the same YugabyteDB version. Mixed-version xCluster replication is not supported.

---

### Step 2: Create a checkpoint on the primary

The checkpoint marks the exact WAL position where replication will begin. It also declares which databases will be replicated and enables `automatic_ddl_mode` so schema changes flow to the standby without manual intervention.

```bash
yb-admin --master_addresses 127.0.0.1:7100 \
  create_xcluster_checkpoint demo yugabyte automatic_ddl_mode
```

What this does:
- Creates a replication group named **`demo`**
- Declares the **`yugabyte`** database for replication
- Enables **`automatic_ddl_mode`** — DDL changes on the primary are captured and replayed on the standby automatically
- Records the current WAL sequence number so the standby knows where to start consuming changes

> **Important:** DDL statements (CREATE TABLE, ALTER TABLE, DROP TABLE) must be **paused on the primary** from this point until Step 5 (`setup_xcluster_replication`) completes. Any DDL executed between Steps 2 and 5 will not be replicated — it must be captured in the Step 3 snapshot instead.

---

### Step 3: Bootstrap — full copy primary → standby

Before connecting the replication stream, the standby must hold an identical copy of the primary's database state. A distributed snapshot is the required mechanism — running the same DDL statements on the standby is **not** sufficient, because the snapshot also copies internal Postgres OIDs and tablet metadata that xCluster uses to match table identities.

**Seed data on the primary** so the backup is meaningful:

```bash
ysqlsh -h 127.0.0.1 -c "
  CREATE TABLE products (id SERIAL PRIMARY KEY, name TEXT, price NUMERIC(10,2));
  INSERT INTO products VALUES (1,'Widget',9.99),(2,'Gadget',24.99),(3,'Doohickey',4.99);
"
```

**Create a distributed snapshot on the primary:**

```bash
yb-admin --master_addresses 127.0.0.1:7100 create_database_snapshot ysql.yugabyte
```

**List snapshots — wait until `State` shows `COMPLETE`, then note the UUID:**

```bash
yb-admin --master_addresses 127.0.0.1:7100 list_snapshots
```

Expected:

```
Snapshot UUID                          State
a1b2c3d4-e5f6-7890-abcd-ef1234567890  COMPLETE
```

**Export the snapshot metadata to a file:**

```bash
yb-admin --master_addresses 127.0.0.1:7100 \
  export_snapshot <SNAPSHOT_UUID> /tmp/yugabyte_snapshot.json
```

**Back up schema from primary** (`import_snapshot` maps tablets by table name — schema must match before import):

```bash
ysql_dump -h 127.0.0.1 --include-yb-metadata --serializable-deferrable \
  --schema-only --dbname yugabyte --file /tmp/yugabyte_schema.sql
```

> `ysql_dump` ships with YugabyteDB at `/usr/local/yugabyte/postgres/bin/ysql_dump`. If it is not in your `$PATH`, run: `export PATH="/usr/local/yugabyte/postgres/bin:$PATH"` first.

**Restore schema on standby:**

```bash
ysqlsh -h 127.0.0.11 -d yugabyte --file /tmp/yugabyte_schema.sql
```

**Import the snapshot on the standby:**

```bash
yb-admin --master_addresses 127.0.0.11:7100 \
  import_snapshot /tmp/yugabyte_snapshot.json yugabyte
```

The output shows the tablet ID mapping and the restored snapshot's `NEW ID` — note it:

```
Table 0: OLD ID: <src-table-id>  NEW ID: <tgt-table-id>
Tablet 0: OLD ID: <src-tablet-id>  NEW ID: <tgt-tablet-id>
Restored: OLD ID: <original-snap-uuid>  NEW ID: <new-snap-uuid>
```

**Copy tablet snapshot SST files from primary to standby:**

In a multi-host deployment you would transfer files via S3 or GCS. In this devcontainer both clusters share the same filesystem — use the table/tablet ID mapping from `import_snapshot` output to copy the directories:

```bash
# Replace placeholders with the actual IDs from the import_snapshot output above.
cp -r ybdb/source/data/yb-data/tserver/data/rocksdb/table-<SRC_TABLE>/tablet-<SRC_TABLET>.snapshots/<SNAPSHOT_UUID>/. \
      ybdb/target/data/yb-data/tserver/data/rocksdb/table-<TGT_TABLE>/tablet-<TGT_TABLET>.snapshots/<SNAPSHOT_UUID>/
```

Repeat for each `Tablet N:` line in the import output. The demo script (`bash prompt.sh`) handles this copy automatically.

**Restore the snapshot on the standby** (use the `NEW ID` from `import_snapshot` output):

```bash
yb-admin --master_addresses 127.0.0.11:7100 restore_snapshot <NEW_SNAPSHOT_UUID>
```

**Verify the data arrived on the standby:**

```bash
ysqlsh -h 127.0.0.11 -c "SELECT * FROM products ORDER BY id;"
```

Expected:

```
 id |   name    | price
----+-----------+-------
  1 | Widget    |  9.99
  2 | Gadget    | 24.99
  3 | Doohickey |  4.99
(3 rows)
```

The standby now holds an identical copy of the primary's database state. Proceed to enable PITR before connecting the replication stream.

---

### Step 4: Enable PITR on the standby

Point-in-time recovery (PITR) must be active on the standby before replication is connected. PITR provides a consistent recovery point that the failover process uses to roll the standby back to a safe transactional boundary.

```bash
yb-admin --master_addresses 127.0.0.11:7100 \
  create_snapshot_schedule 2 30 ysql.yugabyte
```

Parameters:
- `2` — snapshot interval in minutes (a snapshot is taken every 2 minutes)
- `30` — retention window in minutes (snapshots are kept for 30 minutes)
- `ysql.yugabyte` — the YSQL database to protect

Verify the schedule was created:

```bash
yb-admin --master_addresses 127.0.0.11:7100 list_snapshot_schedules
```

Expected output:

```json
{
  "schedules": [
    {
      "id": "...",
      "options": {
        "filter": "ysql.yugabyte",
        "interval": "2 min",
        "retention": "30 min"
      },
      "snapshots": [...]
    }
  ]
}
```

Wait approximately 2 minutes for at least one snapshot to appear in the `snapshots` list before proceeding to Step 4. PITR without at least one snapshot cannot be used for failover.

---

### Step 5: Set up replication

This command runs on the **primary** and connects it to the standby. It streams all changes — both data (DML) and schema (DDL) — from the primary to the standby.

```bash
yb-admin --master_addresses 127.0.0.1:7100 \
  setup_xcluster_replication demo 127.0.0.11:7100
```

Parameters:
- `demo` — the replication group ID created in Step 2
- `127.0.0.11:7100` — the master address of the standby cluster

Verify the replication role on each cluster:

```bash
echo 'SELECT yb_xcluster_ddl_replication.get_replication_role();' | ysqlsh -h 127.0.0.1
echo 'SELECT yb_xcluster_ddl_replication.get_replication_role();' | ysqlsh -h 127.0.0.11
```

Expected output: `source` on the primary, `subscriber` on the standby. This confirms replication is active and DDL can now be resumed on the primary.

---

### Step 6: Check replication role on each cluster

Each cluster knows its own role. Confirm the primary reports `source` and the standby reports `subscriber`.

```bash
# Primary — expect: source
echo 'SELECT yb_xcluster_ddl_replication.get_replication_role();' \
  | ysqlsh -h 127.0.0.1
```

Expected:

```
 get_replication_role
----------------------
 source
(1 row)
```

```bash
# Standby — expect: subscriber
echo 'SELECT yb_xcluster_ddl_replication.get_replication_role();' \
  | ysqlsh -h 127.0.0.11
```

Expected:

```
 get_replication_role
----------------------
 subscriber
(1 row)
```

- **`source`** — this cluster originates changes; writes are accepted
- **`subscriber`** — this cluster receives changes; direct writes to replicated tables are blocked

---

### Step 7: DDL replication — CREATE TABLE on primary only

With `automatic_ddl_mode` active, DDL runs only on the primary. The standby receives and replays the DDL automatically.

Create a table on the **primary**:

```bash
ysqlsh -h 127.0.0.1 -c "
  CREATE TABLE employees (
    id     SERIAL PRIMARY KEY,
    name   TEXT        NOT NULL,
    department TEXT,
    salary NUMERIC(12,2)
  );
"
```

Wait 3 seconds for DDL propagation:

```bash
sleep 3
```

Verify the table appeared on the **standby** — no DDL was run there:

```bash
ysqlsh -h 127.0.0.11 -c "\dt"
```

Expected — `employees` is listed:

```
          List of relations
 Schema |   Name    | Type  |  Owner
--------+-----------+-------+----------
 public | employees | table | yugabyte
(1 row)
```

The DDL travelled from primary to standby through the replication channel. Nothing was executed on the standby directly.

---

### Step 8: Data replication

INSERT rows on the **primary**, then read them from the **standby**.

```bash
ysqlsh -h 127.0.0.1 -c "
  INSERT INTO employees (name, department, salary) VALUES
    ('Alice',   'Engineering', 120000),
    ('Bob',     'Marketing',    95000),
    ('Charlie', 'Engineering', 110000),
    ('Diana',   'Finance',     105000),
    ('Eve',     'Engineering', 130000);
"
```

Wait 3 seconds:

```bash
sleep 3
```

Read from the **standby**:

```bash
ysqlsh -h 127.0.0.11 -c "SELECT id, name, department, salary FROM employees ORDER BY id;"
```

Expected — all 5 rows present on the standby:

```
 id |  name   | department  |  salary
----+---------+-------------+---------
  1 | Alice   | Engineering | 120000
  2 | Bob     | Marketing   |  95000
  3 | Charlie | Engineering | 110000
  4 | Diana   | Finance     | 105000
  5 | Eve     | Engineering | 130000
(5 rows)
```

---

### Step 9: ALTER TABLE replication

Schema changes propagate just like DDL from Step 6. Run `ALTER TABLE` on the **primary only**.

```bash
ysqlsh -h 127.0.0.1 -c "
  ALTER TABLE employees ADD COLUMN email TEXT;
"
```

Wait 3 seconds:

```bash
sleep 3
```

Verify the new column is present on the **standby**:

```bash
ysqlsh -h 127.0.0.11 -c "\d employees"
```

Expected — `email` column appears:

```
                              Table "public.employees"
 Column |         Type          | Collation | Nullable |      Default
--------+-----------------------+-----------+----------+--------------------
 id     | integer               |           | not null | nextval(...)
 name   | text                  |           | not null |
 department | text               |           |          |
 salary | numeric(12,2)         |           |          |
 email  | text                  |           |          |
```

The column was added to the standby automatically — no manual `ALTER TABLE` was needed there.

---

### Step 10: Monitor replication lag

Replication lag is exposed as a Prometheus metric on the source TServer. Near-zero lag means the standby is caught up with the primary.

```bash
curl -s http://127.0.0.1:9000/prometheus-metrics \
  | grep async_replication_committed_lag_micros
```

Sample output:

```
# HELP async_replication_committed_lag_micros Replication lag in microseconds
# TYPE async_replication_committed_lag_micros gauge
async_replication_committed_lag_micros{...} 1234
```

What the metric means:
- **`async_replication_committed_lag_micros`** — the age of the oldest committed transaction on the primary that has not yet been applied on the standby, measured in microseconds
- Value of `0` or a few thousand microseconds = standby is fully caught up
- Sustained high values (millions of microseconds) indicate the standby is falling behind
- This is your **RPO proxy** — in a failover you would lose at most this many microseconds of committed data

Monitor it continuously during load testing:

```bash
watch -n 2 'curl -s http://127.0.0.1:9000/prometheus-metrics \
  | grep async_replication_committed_lag_micros'
```

---

### Step 11: Add a database to the replication group

A replication group can cover multiple databases. Adding a new database requires three steps: create it on both clusters, add it to the checkpoint, then add it to the live replication group.

**Create the database on both clusters:**

```bash
# Primary
ysqlsh -h 127.0.0.1 -c "CREATE DATABASE new_db;"

# Standby
ysqlsh -h 127.0.0.11 -c "CREATE DATABASE new_db;"
```

**Add to the checkpoint on the primary:**

```bash
yb-admin --master_addresses 127.0.0.1:7100 \
  add_namespace_to_xcluster_checkpoint demo new_db
```

**Add to the live replication group:**

```bash
yb-admin --master_addresses 127.0.0.1:7100 \
  add_namespace_to_xcluster_replication demo new_db 127.0.0.11:7100
```

Verify the replication role on the primary to confirm `new_db` is active:

```bash
echo 'SELECT yb_xcluster_ddl_replication.get_replication_role();' | ysqlsh -h 127.0.0.1
```

Expected output: `source` — confirms the primary is still replicating after the namespace addition.

Test replication on the new database:

```bash
ysqlsh -h 127.0.0.1 -d new_db -c "
  CREATE TABLE config (key TEXT PRIMARY KEY, value TEXT);
  INSERT INTO config VALUES ('env', 'production');
"
sleep 3
ysqlsh -h 127.0.0.11 -d new_db -c "SELECT * FROM config;"
```

Expected — row present on standby:

```
 key |   value
-----+------------
 env | production
(1 row)
```

---

### Step 12: Planned failover

A planned failover (also called a switchover) promotes the standby to primary with zero data loss. The sequence is: drain lag to zero → tear down replication → write to former standby.

**1. Drain the replication lag to zero.**

Stop all writes on the primary and wait for lag to reach 0:

```bash
# Poll until lag is zero
watch -n 1 'curl -s http://127.0.0.1:9000/prometheus-metrics \
  | grep async_replication_committed_lag_micros'
```

Wait until the metric reads `0` (or is absent). This confirms every committed transaction has been applied on the standby.

**2. Drop the replication group.**

Run on the **primary**:

```bash
yb-admin --master_addresses 127.0.0.1:7100 \
  drop_xcluster_replication demo 127.0.0.11:7100
```

This severs the replication link. Both clusters are now independent. The former standby is no longer in `subscriber` mode.

**3. Verify the former standby is now independent.**

Check the role on the former standby — it should return no role (or `none`):

```bash
echo 'SELECT yb_xcluster_ddl_replication.get_replication_role();' \
  | ysqlsh -h 127.0.0.11
```

Expected:

```
 get_replication_role
----------------------
 none
(1 row)
```

**4. Write to the former standby.**

The former standby now accepts writes:

```bash
ysqlsh -h 127.0.0.11 -c "
  INSERT INTO employees (name, department, salary, email)
  VALUES ('Frank', 'Operations', 98000, 'frank@example.com');
"

ysqlsh -h 127.0.0.11 -c "SELECT COUNT(*) FROM employees;"
```

Expected — 6 rows (5 replicated + 1 new write):

```
 count
-------
     6
(1 row)
```

**5. Verify the former primary no longer receives these writes.**

```bash
ysqlsh -h 127.0.0.1 -c "SELECT COUNT(*) FROM employees;"
```

Expected — still 5 rows (replication is severed):

```
 count
-------
     5
(1 row)
```

The two clusters are now fully independent. To re-establish replication in the reverse direction (new primary → new standby), repeat Steps 2–5 with the host addresses swapped.

---

## What the demo shows

| Part | What it covers |
|---|---|
| **1 — Checkpoint** | `create_xcluster_checkpoint` with `automatic_ddl_mode` |
| **2 — Bootstrap** | Seed `products` table → `create_database_snapshot` → `export_snapshot` → create schema on standby → `import_snapshot` → copy SST files → `restore_snapshot` → verify data on standby |
| **3 — PITR** | `create_snapshot_schedule` on standby (required for failover) |
| **4 — Setup** | `setup_xcluster_replication` — database-level, not table-level |
| **5 — Role check** | `SELECT yb_xcluster_ddl_replication.get_replication_role()` |
| **6 — DDL replication** | `CREATE TABLE` on primary → appears on standby automatically |
| **7 — Data replication** | `INSERT` on primary → standby receives rows |
| **8 — ALTER TABLE** | `ALTER TABLE ADD COLUMN` on primary → schema auto-propagates |
| **9 — Lag** | `async_replication_committed_lag_micros` from TServer metrics |
| **10 — Add DB** | `add_namespace_to_xcluster_replication` |
| **11 — Failover** | Manual: drain lag → `drop_xcluster_replication` → promote standby |

## Key commands reference

```bash
# Check replication role (on primary → source, on standby → subscriber)
echo 'SELECT yb_xcluster_ddl_replication.get_replication_role();' | ysqlsh -h 127.0.0.1

# Add a database to an existing group
yb-admin --master_addresses 127.0.0.1:7100 \
  add_namespace_to_xcluster_checkpoint demo new_db

yb-admin --master_addresses 127.0.0.1:7100 \
  add_namespace_to_xcluster_replication demo new_db 127.0.0.11:7100

# Remove a database
yb-admin --master_addresses 127.0.0.1:7100 \
  remove_namespace_from_xcluster_replication demo new_db 127.0.0.11:7100

# Tear down replication
yb-admin --master_addresses 127.0.0.1:7100 \
  drop_xcluster_replication demo 127.0.0.11:7100

# Check role (run in YSQL on each cluster)
SELECT yb_xcluster_ddl_replication.get_replication_role();
-- source      → this is the primary
-- subscriber  → this is the standby
```

## Replication lag

```bash
# Prometheus-format metrics on the SOURCE TServer
curl -s http://127.0.0.1:9000/prometheus-metrics \
  | grep async_replication_committed_lag_micros

# async_replication_committed_lag_micros — your RPO proxy
# Near-zero = standby is caught up
```

## xCluster Replication vs xCluster DR

| | xCluster Replication (this demo) | xCluster DR |
|---|---|---|
| Management | `yb-admin` / `yugabyted` | **YBA only** |
| DDL replication | ✓ Automatic (v2025.2.1+) | ✓ |
| Switchover/Failover | Manual (as shown in Part 11) | One-click |
| PITR integration | Manual (`create_snapshot_schedule`) | Automated |
| Requires YBA | No | Yes |

## Important notes

- **DDL must be paused on primary** during the setup process (Steps 1–4)
- **Backup/restore is always required** before `setup_xcluster_replication` — even for empty databases (internal metadata must match)
- **Not all DDLs are replicated yet** — see [xCluster Limitations](https://docs.yugabyte.com/stable/deploy/multi-dc/async-replication/async-replication-limitations/)
- xCluster replicates **data and DDL** — users, roles, tablespaces still require manual sync

---

> **Related exercises**
> - PITR (`init-pitr`) — point-in-time recovery (required by xCluster DR for failover)
> - Geo-distribution (`init-geo`) — tablespace-based placement across regions
