# Distributed SQL · Hash & Range Sharding

[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/srinivasa-vasu/ybdb-vanguard?devcontainer_path=.devcontainer%2Finit-dsql%2Fdevcontainer.json)

Hands-on exercises that show how YugabyteDB physically distributes data across tablets, and how your schema choices (hash vs range, clustering key direction, index type) directly affect query performance.

---

## Prerequisites

The devcontainer starts a **3-node cluster** across 3 availability zones automatically. Connect with:

```bash
ysqlsh
```

> Default connection: `yugabyte@127.0.0.1:5433` — no credentials needed.

> A **ysql** terminal opens automatically — use it directly or run `Terminal → Run Task → ysql` to open another.

---

## Running the exercises

**Option A — load the whole file and step through**

```sql
\i init-dsql/sharding.sql
```

**Option B — paste individual blocks** from `sharding.sql` to explore interactively.

---

## What's covered

### Part 1 · Hash Sharding

| Exercise | Concept |
|---|---|
| 1.1 Single-column hash | Default PK → hash-routed; point lookups 1 RPC, range scans scatter |
| 1.2 Hash + ASC clustering | Route by entity, sort by time ascending within tablet |
| 1.3 Hash + DESC clustering | Route by entity, newest rows first — no sort needed for latest-N |
| 1.4 Composite hash key | Hash on `(tenant, app_id)` together — prevents per-column hot partitions |

**Key insight:** Hash sharding gives uniform write throughput across all tablets but sacrifices ordered access. Use a clustering key (`ASC` / `DESC`) to restore order *within* a partition.

### Part 2 · Range Sharding

| Exercise | Concept |
|---|---|
| 2.1 Auto-split | `PRIMARY KEY ASC` → global sorted order; splits automatically at ~64 MB |
| 2.2 Pre-split | `SPLIT AT VALUES` — define boundaries upfront; no cold-start hotspot |
| 2.3 Composite range key | Multi-column range; prefix scans efficient, non-prefix scans are not |
| 2.4 ASC vs DESC storage | Storage direction determines which query pattern is "free" |

**Key insight:** Range sharding enables efficient range scans and streaming ORDER BY, but sequential keys (timestamps, serial IDs) create a write hotspot on the last tablet until it auto-splits. Pre-split or use hash for write-heavy sequential workloads.

### Part 3 · Secondary Indexes

| Exercise | Concept |
|---|---|
| 3.1 Hash index | Equality lookups via separate index tablet group (2-RPC path) |
| 3.2 Range index | Range scans and ordered access; pre-split to avoid cold-start hotspot |
| 3.3 Covering index (`INCLUDE`) | Store extra columns in index leaf → index-only scan (1 RPC) |
| 3.4 Partial index (`WHERE`) | Index only matching rows — smaller, faster, great for skewed predicates |
| 3.5 Expression index | `lower(email)` stored as the key; query must match the expression exactly |
| 3.6 Bucket index | `(yb_hash_code(ts) % N) + ts DESC` — spread monotone-key writes across N tablets |

### Part 4 · Observe Tablet Metadata

```sql
SELECT * FROM yb_table_properties('your_table'::regclass);
SELECT * FROM yb_local_tablets LIMIT 30;
```

---

## Useful EXPLAIN flags

```sql
-- One-time alias for your session:
\set explain 'EXPLAIN (ANALYZE, DIST, COSTS ON, BUFFERS OFF)'

:explain SELECT ...
```

The `DIST` option shows storage-layer RPCs — the key metric for distributed query performance.

---

## Quick reference: sharding cheat sheet

```sql
-- Hash (default — uniform writes, no range scans)
CREATE TABLE t (id TEXT PRIMARY KEY, ...);

-- Hash + clustering key
CREATE TABLE t (id TEXT, ts TIMESTAMPTZ, ...,
  PRIMARY KEY (id HASH, ts DESC));

-- Range (ordered — range scans, ORDER BY, but watch for hotspots)
CREATE TABLE t (id TEXT PRIMARY KEY ASC, ...);

-- Range with pre-split
CREATE TABLE t (id TEXT PRIMARY KEY ASC, ...)
  SPLIT AT VALUES (('G'), ('N'), ('T'));

-- Range split into N tablets evenly
CREATE TABLE t (id TEXT PRIMARY KEY ASC, ...)
  SPLIT INTO 4 TABLETS;

-- Composite hash key
CREATE TABLE t (a TEXT, b TEXT, c TEXT, ...,
  PRIMARY KEY ((a, b) HASH, c ASC));

-- Covering index (avoid main-table fetch for common projections)
CREATE INDEX idx ON t (email HASH) INCLUDE (name, region);

-- Partial index (only index the rows you actually query)
CREATE INDEX idx ON t (email HASH) WHERE status = 'active';

-- Bucket index (monotone-key hot-key mitigation)
CREATE INDEX idx ON t ((yb_hash_code(ts) % 4) ASC, ts DESC)
  SPLIT AT VALUES ((1), (2), (3));
```

---

## YCQL basics

Connect with `ycqlsh` and run the following:

```cql
CREATE KEYSPACE demo;
USE demo;

-- Transactions must be explicitly enabled for secondary indexes on CQL tables
CREATE TABLE events (
  k   INT,
  v   INT,
  t   TEXT,
  ts  TIMESTAMP,
  PRIMARY KEY (k, v)
) WITH transactions = { 'enabled' : true }
  AND tablets = 4;

CREATE INDEX ON events(v) WITH transactions = { 'enabled' : true };

DESC events;
```
