# Query Tuning Tips & Tricks

Hands-on exercises covering the full query optimisation stack in YugabyteDB — storage-layer pushdowns, index strategies, join optimisation, advanced SQL, and programmability.

---

> **How to run queries from this README**
> Select any SQL block → **`Ctrl+Shift+Enter`** (Windows/Linux) or **`Cmd+Shift+Enter`** (Mac) → runs in the active `ysqlsh` terminal.
> The shortcut is pre-configured in the devcontainer — no setup needed.

---

## Setup

Seed the exercise tables and set the EXPLAIN shorthand — run these once per session:

```sql
\i init-qt/tuning.sql
```

```sql
\set explain 'EXPLAIN (ANALYZE, DIST, COSTS ON, BUFFERS OFF)'
```

The `:explain` shorthand is used throughout. `DIST` exposes storage-layer RPC counts — the primary signal for distributed query cost.

---

## Part 1 · Query Execution Patterns

### 1.1 Point lookup

Hash PK: `hash(trackid)` maps to exactly one tablet → one RPC. Always O(1) regardless of table size.

```sql
:explain SELECT * FROM track WHERE trackid = 42;
```

> Look for `Index Scan using track_pkey` with **Storage Table Read Requests: 1** — one tablet, no scatter-gather.

A hash-join where both sides are point lookups is equally fast:

```sql
:explain
SELECT t.name AS track, a.title AS album
FROM   track t
JOIN   album a ON t.albumid = a.albumid
WHERE  t.trackid = 42;
```

---

### 1.2 Range scan vs full-table scan

A range index seeks to the start of the range and walks forward, touching only relevant tablets. A full scan fans out to every tablet (scatter-gather).

```sql
-- Full scan (no index on unitprice yet)
:explain SELECT * FROM track WHERE unitprice > 0.99;
```

```sql
CREATE INDEX IF NOT EXISTS idx_track_price ON track (unitprice ASC);

-- Range scan after index creation
:explain SELECT * FROM track WHERE unitprice > 0.99;
```

> Before: `Seq Scan`, high `Storage Table Rows Scanned`.
> After: `Index Scan`, rows scanned ≈ rows returned.

Leading-wildcard LIKE cannot use any index — always a full scan:

```sql
:explain SELECT * FROM track WHERE name LIKE '%Love%';
```

---

### 1.3 ORDER BY: hash penalty vs range benefit

Hash PK → ORDER BY requires a full scatter-gather across all tablets then an in-memory sort.
Range PK → rows already arrive in order from storage — no sort node needed.

```sql
-- Hash PK: scatter-gather + Sort node
:explain SELECT * FROM track ORDER BY trackid ASC LIMIT 10;
```

```sql
CREATE INDEX IF NOT EXISTS idx_invoice_date ON invoice (invoicedate ASC);

-- Range index: streaming scan, no Sort node
:explain SELECT * FROM invoice ORDER BY invoicedate ASC LIMIT 10;

-- Backward scan on the same index (no separate index needed)
:explain SELECT * FROM invoice ORDER BY invoicedate DESC LIMIT 10;

DROP INDEX IF EXISTS idx_invoice_date;
```

> Look for the presence or absence of a `Sort` node in the plan.

---

### 1.4 LIMIT pushdown

On a range-sharded table, LIMIT is pushed into storage — the scan stops as soon as enough rows are found. On a hash-sharded table, all tablets must respond before LIMIT can be applied.

```sql
CREATE TABLE IF NOT EXISTS listings (
  price      DECIMAL,
  listing_id TEXT,
  name       TEXT,
  PRIMARY KEY (price ASC, listing_id)
) SPLIT AT VALUES ((0.99), (1.99));

INSERT INTO listings
SELECT (0.50 + (i % 3) * 0.50)::DECIMAL, 'list-' || i, 'Track ' || i
FROM generate_series(1, 500) AS i
ON CONFLICT DO NOTHING;

-- Range table: scan stops after 3 rows
:explain SELECT * FROM listings ORDER BY price ASC, listing_id ASC LIMIT 3;

-- Hash table: must read ALL tablets first
:explain SELECT * FROM track ORDER BY trackid LIMIT 3;

DROP TABLE IF EXISTS listings;
```

> Range table shows **Rows Scanned ≈ LIMIT**. Hash table shows much higher Rows Scanned.

---

### 1.5 Keyset pagination vs OFFSET

OFFSET N: DocDB reads and discards N rows. Cost is O(OFFSET) — page 1000 is 1000× slower than page 1.
Keyset cursor: always O(log N) — same cost at any depth.

```sql
-- ❌ OFFSET — cost grows with every page
:explain
SELECT invoiceid, customerid, invoicedate, total
FROM   invoice
ORDER BY invoicedate ASC, invoiceid ASC
LIMIT 10 OFFSET 200;
```

```sql
-- ✅ Keyset — constant cost, pass last row's values as cursor
:explain
SELECT invoiceid, customerid, invoicedate, total
FROM   invoice
WHERE  (invoicedate, invoiceid) > ('2009-03-04'::DATE, 100)
ORDER BY invoicedate ASC, invoiceid ASC
LIMIT 10;
```

> OFFSET plan shows high `Storage Table Rows Scanned`. Keyset plan scans ≈ LIMIT rows.

---

## Part 2 · Pushdown Operations

YugabyteDB evaluates work inside the DocDB storage layer so less data travels between storage and the YSQL tier.

### 2.1 Aggregate pushdown

`COUNT`, `SUM`, `MIN`, `MAX` are computed per-tablet in storage. Only partial results travel the network — no raw rows.

```sql
:explain SELECT count(1) FROM track;
:explain SELECT count(1), sum(milliseconds) FROM track;
```

> Look for `Partial Aggregate` nodes — these execute inside DocDB, not in YSQL.

---

### 2.2 Distinct pushdown

`DISTINCT` on an indexed column: one seek per distinct value rather than reading all duplicates.

```sql
:explain SELECT DISTINCT albumid FROM track WHERE albumid > 0;
```

> Look for `Distinct Index Scan` — storage returns one row per unique key.

---

### 2.3 Expression pushdown

WHERE predicates containing functions are evaluated at DocDB — only rows that pass the predicate are returned.

```sql
:explain SELECT * FROM track WHERE upper(name) LIKE 'TRACK 1%';
:explain SELECT * FROM invoice WHERE total > 5;
```

> Look for `Storage Filter:` in the plan — that line confirms the predicate executes in storage, not in YSQL.

Compare without pushdown (educational only):

```sql
SET yb_enable_expression_pushdown = false;
:explain SELECT * FROM invoice WHERE total > 5;
SET yb_enable_expression_pushdown = true;
```

> Without pushdown: `Filter:` appears in YSQL tier — all rows transferred, then filtered.

---

## Part 3 · Index Strategies

### 3.1 Hash index — equality lookups

A secondary HASH index is a separate tablet group keyed by the indexed column. Lookup: `hash(col)` → index tablet → get PK → main tablet (2 RPCs).

```sql
-- Before: full scan
:explain SELECT * FROM track WHERE albumid = 1;

CREATE INDEX IF NOT EXISTS idx_track_albumid ON track (albumid HASH);

-- After: 2-RPC index scan
:explain SELECT * FROM track WHERE albumid = 1;
```

---

### 3.2 Range index — range scans and streaming ORDER BY

```sql
-- Before: full scan
:explain SELECT * FROM invoice WHERE invoicedate > '2010-01-01';

CREATE INDEX IF NOT EXISTS idx_invoice_date ON invoice (invoicedate ASC);

-- After: range scan (only touches relevant tablets)
:explain SELECT * FROM invoice WHERE invoicedate > '2010-01-01';

-- ORDER BY on the indexed column is now free (no Sort node)
:explain SELECT * FROM invoice ORDER BY invoicedate ASC LIMIT 20;
```

---

### 3.3 Covering index (`INCLUDE`) — 1 RPC instead of 2

Store projected columns inside the index leaf to avoid the second main-table fetch.

```sql
-- Plain hash index: 2-RPC path (index + table fetch)
:explain SELECT trackid, name FROM track WHERE albumid = 1;

CREATE INDEX IF NOT EXISTS idx_track_albumid_cover
  ON track (albumid HASH)
  INCLUDE (trackid, name);

-- Covering index: index-only scan (1 RPC, no heap fetch)
:explain SELECT trackid, name FROM track WHERE albumid = 1;

-- SELECT * still needs the main table (milliseconds, unitprice not in INCLUDE)
:explain SELECT * FROM track WHERE albumid = 1;
```

> `Index Only Scan` confirms the second RPC was eliminated.

---

### 3.4 Partial index — index only the rows you need

Index only rows matching a WHERE condition — smaller, faster, lower write amplification.

```sql
-- Index only Calgary employees (most common query target)
CREATE INDEX IF NOT EXISTS idx_employee_city
  ON employee (city HASH)
  WHERE city = 'Calgary';

-- ✅ Predicate-compatible — uses the index
:explain SELECT * FROM employee WHERE city = 'Calgary';

-- ❌ Predicate not compatible — falls back to full scan
:explain SELECT * FROM employee WHERE city = 'Lethbridge';
```

---

### 3.5 Forward and backward scan

A single range index serves both ASC and DESC queries efficiently.

```sql
CREATE INDEX IF NOT EXISTS idx_customer_repid ON customer (supportrepid ASC);

-- Forward scan (matches index direction)
:explain SELECT * FROM customer ORDER BY supportrepid ASC;

-- Backward scan (no separate DESC index needed)
:explain SELECT * FROM customer ORDER BY supportrepid DESC;
```

> Both plans show `Index Scan` — no `Sort` node in either direction.

---

### 3.6 Expression index

Index a function of a column. The WHERE clause must use the exact same expression.

```sql
CREATE INDEX IF NOT EXISTS idx_customer_lower_email
  ON customer (lower(email) HASH);

-- ✅ Expression matches — uses the index
:explain SELECT * FROM customer WHERE lower(email) = 'user1@example.com';

-- ❌ Raw column — expression index cannot help
:explain SELECT * FROM customer WHERE email = 'user1@example.com';
```

---

## Part 4 · Join Optimisation

### 4.1 Join order hints

`Leading()` controls which tables are joined first. Placing the most selective table first reduces intermediate row counts.

```sql
-- Default planner choice
:explain
SELECT t.name AS track, a.title AS album, ar.name AS artist
FROM   track t
JOIN   album  a  ON t.albumid  = a.albumid
JOIN   artist ar ON a.artistid = ar.artistid
WHERE  t.trackid = 5;
```

```sql
-- Force (track ⋈ album) ⋈ artist
:explain
/*+Leading ( ( ( t a ) ar ) ) */
SELECT t.name AS track, a.title AS album, ar.name AS artist
FROM   track t
JOIN   album  a  ON t.albumid  = a.albumid
JOIN   artist ar ON a.artistid = ar.artistid
WHERE  t.trackid = 5;
```

```sql
-- Force artist ⋈ (album ⋈ track) — least selective side first
:explain
/*+Leading ( ( ar ( a t ) ) ) */
SELECT t.name AS track, a.title AS album, ar.name AS artist
FROM   track t
JOIN   album  a  ON t.albumid  = a.albumid
JOIN   artist ar ON a.artistid = ar.artistid
WHERE  t.trackid = 5;
```

> Compare `Storage Table Rows Scanned` across the three plans. The best order scans the fewest rows.

---

### 4.2 Batch Nested Loop (BNL)

BNL batches multiple inner-side keys into a single storage RPC. Dramatically reduces round-trips for multi-table joins. Default batch size: 1024.

```sql
SET yb_bnl_batch_size = 1;    -- 1 row per RPC (worst case baseline)

:explain
SELECT p.name AS playlist, t.name AS track, ar.name AS artist
FROM   playlist      p
JOIN   playlisttrack pt ON  p.playlistid = pt.playlistid
JOIN   track         t  ON pt.trackid    = t.trackid
JOIN   album         a  ON  t.albumid    = a.albumid
JOIN   artist       ar  ON  a.artistid   = ar.artistid
WHERE  p.playlistid = 3;
```

```sql
SET yb_bnl_batch_size = 1024; -- 1024 keys per RPC (much faster)

:explain
SELECT p.name AS playlist, t.name AS track, ar.name AS artist
FROM   playlist      p
JOIN   playlisttrack pt ON  p.playlistid = pt.playlistid
JOIN   track         t  ON pt.trackid    = t.trackid
JOIN   album         a  ON  t.albumid    = a.albumid
JOIN   artist       ar  ON  a.artistid   = ar.artistid
WHERE  p.playlistid = 3;

RESET yb_bnl_batch_size;
```

> Compare `Storage Table Read Requests` — batch=1024 should show dramatically fewer RPCs.

---

## Part 5 · Advanced SQL

### 5.1 Prepared statements

`PREPARE` parses and plans once. `EXECUTE` reuses the cached plan — no planning overhead on subsequent calls.

```sql
PREPARE tracks_by_artist(text) AS
  SELECT t.name AS track, t.milliseconds, t.unitprice
  FROM   track t
  JOIN   album  a  ON t.albumid  = a.albumid
  JOIN   artist ar ON a.artistid = ar.artistid
  WHERE  ar.name = $1
  ORDER BY t.name;

EXECUTE tracks_by_artist('Artist 1');
EXECUTE tracks_by_artist('Artist 50');

DEALLOCATE tracks_by_artist;
```

---

### 5.2 CTE — readable sub-query factoring

`WITH` names a sub-query so it can be referenced multiple times. Useful for multi-step aggregations.

```sql
-- Customers who spent more than their country's average
WITH customer_spend AS (
  SELECT c.customerid,
         c.firstname || ' ' || c.lastname AS name,
         c.country,
         SUM(i.total) AS total_spend
  FROM   customer c
  JOIN   invoice  i USING (customerid)
  GROUP BY c.customerid, c.firstname, c.lastname, c.country
),
country_avg AS (
  SELECT country, AVG(total_spend) AS avg_spend
  FROM   customer_spend
  GROUP BY country
)
SELECT cs.country, cs.name,
       round(cs.total_spend::numeric, 2) AS spend,
       round(ca.avg_spend::numeric,   2) AS country_avg
FROM   customer_spend cs
JOIN   country_avg    ca USING (country)
WHERE  cs.total_spend > ca.avg_spend
ORDER BY cs.country, cs.total_spend DESC;
```

---

### 5.3 Recursive CTE — walk a hierarchy

Walk a self-referential table (the `employee` org chart) without application-side loops.

```sql
WITH RECURSIVE org_tree AS (
  -- Anchor: top-level employees (no manager)
  SELECT employeeid,
         firstname || ' ' || lastname AS name,
         title, reportsto,
         firstname || ' ' || lastname AS path,
         0 AS depth
  FROM   employee WHERE reportsto IS NULL

  UNION ALL

  -- Recursive: employees who report to a node already in the tree
  SELECT e.employeeid, e.firstname || ' ' || e.lastname,
         e.title, e.reportsto,
         ot.path || ' → ' || e.firstname || ' ' || e.lastname,
         ot.depth + 1
  FROM   employee e
  JOIN   org_tree ot ON e.reportsto = ot.employeeid
)
SELECT depth,
       repeat('  ', depth) || name AS org_chart,
       title
FROM   org_tree
ORDER BY path;
```

---

### 5.4 Window functions — per-row analytics

`OVER()` defines a logical window (partition + ordering) per row. `LAG` peeks at the previous row without a self-join. `RANK` assigns a position within a partition.

```sql
-- Invoice delta per customer: how much more/less than the previous invoice?
SELECT customerid, invoicedate, total,
       LAG(total) OVER per_customer    AS prev_invoice,
       total - LAG(total) OVER per_customer AS delta
FROM   invoice
WINDOW per_customer AS (PARTITION BY customerid ORDER BY invoicedate)
ORDER BY customerid, invoicedate
LIMIT 30;
```

```sql
-- Revenue rank per customer within each country
SELECT c.country,
       c.firstname || ' ' || c.lastname AS customer,
       round(SUM(i.total)::numeric, 2)  AS lifetime_value,
       RANK() OVER (
         PARTITION BY c.country
         ORDER BY SUM(i.total) DESC
       ) AS rank_in_country
FROM   customer c
JOIN   invoice  i USING (customerid)
GROUP BY c.country, c.customerid, c.firstname, c.lastname
ORDER BY c.country, rank_in_country;
```

---

### 5.5 GROUP BY + NTILE

`NTILE(N)` divides ordered rows into N equal-size buckets — useful for spend tiers, percentile bands, etc.

```sql
WITH spend AS (
  SELECT customerid, SUM(total) AS total_spend
  FROM   invoice GROUP BY customerid
),
tiered AS (
  SELECT customerid,
         ntile(3) OVER (ORDER BY total_spend) AS tier,
         round(total_spend::numeric, 2)        AS total_spend
  FROM   spend
)
SELECT tier,
       CASE tier WHEN 1 THEN 'Low' WHEN 2 THEN 'Mid' ELSE 'High' END AS label,
       count(*)                             AS customers,
       round(min(total_spend)::numeric, 2)  AS min_spend,
       round(max(total_spend)::numeric, 2)  AS max_spend
FROM   tiered
GROUP BY tier ORDER BY tier;
```

---

## Part 6 · Programmability

### 6.1 Stored procedure — transaction control and exceptions

A procedure can manage its own transaction and raise typed exceptions for business-rule violations.

```sql
CREATE OR REPLACE PROCEDURE adjust_track_price(
  p_trackid    INT,
  p_adjustment NUMERIC
) LANGUAGE plpgsql AS $$
BEGIN
  UPDATE track SET unitprice = unitprice + p_adjustment
  WHERE  trackid = p_trackid;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Track % not found', p_trackid;
  END IF;
END;
$$;
```

```sql
-- ✅ Valid adjustment
SELECT trackid, name, unitprice FROM track WHERE trackid = 1;
CALL adjust_track_price(1, 0.10);
SELECT trackid, name, unitprice FROM track WHERE trackid = 1;
```

```sql
-- ❌ Non-existent track — exception rolls back the transaction
CALL adjust_track_price(999999, 0.10);
```

---

### 6.2 Trigger — automatic audit timestamp

A `BEFORE UPDATE` trigger fires only when `unitprice` actually changes (`WHEN` clause prevents spurious fires on unrelated column updates).

```sql
ALTER TABLE track ADD COLUMN IF NOT EXISTS price_updated_at TIMESTAMPTZ;

CREATE OR REPLACE FUNCTION trg_track_price_audit()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.price_updated_at := transaction_timestamp();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_track_price ON track;

CREATE TRIGGER trg_track_price
  BEFORE UPDATE ON track
  FOR EACH ROW
  WHEN (OLD.unitprice IS DISTINCT FROM NEW.unitprice)
  EXECUTE FUNCTION trg_track_price_audit();
```

```sql
-- Before: price_updated_at is NULL
SELECT trackid, name, unitprice, price_updated_at FROM track WHERE trackid IN (1, 2, 3);

CALL adjust_track_price(1, 0.05);
CALL adjust_track_price(2, 0.05);

-- After: only updated rows have price_updated_at set
SELECT trackid, name, unitprice, price_updated_at FROM track WHERE trackid IN (1, 2, 3);
```

---

### 6.3 Materialized view — pre-computed aggregates

A materialised view stores the result of an expensive aggregation as a table. Can be indexed and refreshed on demand.

```sql
CREATE MATERIALIZED VIEW IF NOT EXISTS mv_revenue_by_country AS
SELECT c.country,
       count(DISTINCT c.customerid)   AS customers,
       count(i.invoiceid)             AS invoices,
       round(SUM(i.total)::numeric,2) AS total_revenue,
       round(AVG(i.total)::numeric,2) AS avg_invoice
FROM   customer c
JOIN   invoice  i USING (customerid)
GROUP BY c.country
ORDER BY total_revenue DESC;

CREATE INDEX IF NOT EXISTS idx_mv_revenue
  ON mv_revenue_by_country (total_revenue DESC);

REFRESH MATERIALIZED VIEW mv_revenue_by_country;
```

```sql
-- Index scan on the materialised view — no aggregation at query time
:explain
SELECT * FROM mv_revenue_by_country
WHERE  total_revenue > 50
ORDER BY total_revenue DESC;

SELECT * FROM mv_revenue_by_country LIMIT 10;
```

---

## Key mental models

```
Hash PK  → uniform writes, O(1) point lookup, scatter-gather for ORDER BY / range scan
Range PK → ordered writes, efficient range scan + streaming ORDER BY, hotspot risk on sequential keys

Index Scan      → 2 RPCs  (index tablet → main tablet)
Index Only Scan → 1 RPC   (INCLUDE covers all projected columns — no main table fetch)
Full Scan       → N RPCs  (one per tablet, in parallel)

Storage Filter  → predicate evaluated in DocDB, only matching rows transferred to YSQL
Partial Aggregate → COUNT/SUM computed per tablet, only partial results cross the network

BNL batch 1    → 1 RPC per inner row  (worst case)
BNL batch 1024 → 1 RPC per 1024 rows  (much faster for multi-table joins)
```
