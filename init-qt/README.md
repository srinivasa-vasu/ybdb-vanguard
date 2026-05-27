# Query Tuning Tips & Tricks

Hands-on exercises covering the full query optimisation stack in YugabyteDB — from storage-layer pushdowns and index selection through join strategies, advanced SQL, and programmability.

---

## Prerequisites

The devcontainer starts a **3-node cluster**. `tuning.sql` is fully self-contained — it creates and seeds all exercise tables when you run it, no external datasets needed.

Connect with:

```bash
ysqlsh
```

---

## Running the exercises

**Option A — load the whole file**

```sql
\i init-qt/tuning.sql
```

**Option B — paste individual blocks** from `tuning.sql` to explore interactively.

**EXPLAIN shorthand** (set once per session):

```sql
\set explain 'EXPLAIN (ANALYZE, DIST, COSTS ON, BUFFERS OFF)'
:explain SELECT ...
```

The `DIST` flag exposes storage-layer RPC counts — the primary signal for distributed query cost.

---

## What's covered

### Part 1 · Query Execution Patterns

| Exercise | Concept |
|---|---|
| 1.1 Point lookup | Hash PK → 1 RPC; always O(1) regardless of table size |
| 1.2 Range scan vs full scan | Range index prunes tablets; leading-wildcard LIKE must full-scan |
| 1.3 ORDER BY: hash vs range | Hash → scatter-gather + sort; range → streaming (no sort node) |
| 1.4 LIMIT pushdown | Range table: scan stops early in storage; hash: must read all tablets |
| 1.5 Keyset vs OFFSET pagination | OFFSET grows linearly; keyset cursor is constant-cost at any depth |

### Part 2 · Pushdown Operations

| Exercise | Concept |
|---|---|
| 2.1 Aggregate pushdown | `COUNT`, `SUM` computed per tablet — only partial results travel the network |
| 2.2 Distinct pushdown | `DISTINCT` on an indexed column resolved in storage |
| 2.3 Expression pushdown | WHERE predicates with functions evaluated at DocDB layer (Storage Filter) |

### Part 3 · Index Strategies

| Exercise | Concept |
|---|---|
| 3.1 Hash index | Equality lookup (2-RPC path: index tablet → main tablet) |
| 3.2 Range index | Range scan + streaming ORDER BY; pre-split to avoid cold-start hotspot |
| 3.3 Covering index (`INCLUDE`) | Store projected columns in index leaf → 1-RPC index-only scan |
| 3.4 Partial index | Index only rows matching a WHERE condition — smaller, faster |
| 3.5 Forward & backward scan | Single range index serves both ASC and DESC efficiently |
| 3.6 Expression index | `lower(email)` as index key — query must match the exact expression |

### Part 4 · Join Optimization

| Exercise | Concept |
|---|---|
| 4.1 Join order hints | `/*+Leading(...)*/` forces join order; pick the most selective side first |
| 4.2 Batch Nested Loop | `yb_bnl_batch_size` — batch inner-side keys into fewer storage RPCs |

### Part 5 · Advanced SQL

| Exercise | Concept |
|---|---|
| 5.1 Prepared statements | Plan once, execute many times — eliminates per-query planning overhead |
| 5.2 CTE | `WITH` — readable sub-query factoring; overlapping period detection |
| 5.3 Recursive CTE | Walk org-chart hierarchies without application loops |
| 5.4 Window functions | `LAG`, `RANK`, `PARTITION BY` — per-row analytics without self-joins |
| 5.5 GROUP BY + NTILE | Equal-size bucketing with `ntile(N)` |

### Part 6 · Programmability

| Exercise | Concept |
|---|---|
| 6.1 Stored procedure | Transaction control + `RAISE EXCEPTION` for business-rule enforcement |
| 6.2 Trigger | `BEFORE UPDATE` trigger for audit timestamps |
| 6.3 Materialized view | Pre-compute expensive aggregates; index and refresh on demand |

---

## Key mental models

```
Hash PK  → uniform writes, O(1) point lookup, scatter-gather for ORDER BY / range scan
Range PK → ordered writes, efficient range scan + streaming ORDER BY, hotspot risk on sequential keys

Index Scan    → 2 RPCs  (index tablet → main tablet)
Index Only    → 1 RPC   (INCLUDE covers all projected columns)
Full Scan     → N RPCs  (one per tablet, in parallel)

Pushdown (Storage Filter) → predicate evaluated in storage, only matching rows transferred
Aggregate Pushdown        → partial aggregates per tablet, merged in YSQL

BNL batch size 1    → 1 RPC per inner row  (baseline)
BNL batch size 1024 → 1 RPC per 1024 inner rows  (much faster for multi-table joins)
```
