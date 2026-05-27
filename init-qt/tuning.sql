-- ============================================================
-- YugabyteDB — Query Tuning Exercises
-- ============================================================
-- Self-contained: creates and seeds all exercise tables inline.
--
-- Connect and run:
--   ysqlsh
--   \i init-qt/tuning.sql      -- run everything
--   or paste individual blocks to explore step-by-step
-- ============================================================

-- ── EXPLAIN shorthand (run once per session) ──────────────────────────────────
\set explain 'EXPLAIN (ANALYZE, DIST, COSTS ON, BUFFERS OFF)'


\echo '═══════════════════════════════════════════════════════════'
\echo '  Setup · Create and seed exercise tables'
\echo '═══════════════════════════════════════════════════════════'

-- Drop in FK-safe order so the file is idempotent (safe to re-run)
DROP TABLE IF EXISTS playlisttrack, playlist, invoiceline, invoice,
                     track, album, artist, customer, employee CASCADE;

-- ── Schema ────────────────────────────────────────────────────────────────────

CREATE TABLE artist (
  artistid  INT  PRIMARY KEY,
  name      TEXT NOT NULL
);

CREATE TABLE album (
  albumid   INT  PRIMARY KEY,
  title     TEXT NOT NULL,
  artistid  INT  NOT NULL REFERENCES artist(artistid)
);

CREATE TABLE track (
  trackid      INT            PRIMARY KEY,
  name         TEXT           NOT NULL,
  albumid      INT            NOT NULL REFERENCES album(albumid),
  milliseconds INT            NOT NULL,
  unitprice    NUMERIC(5,2)   NOT NULL DEFAULT 0.99
);

CREATE TABLE employee (
  employeeid  INT  PRIMARY KEY,
  lastname    TEXT NOT NULL,
  firstname   TEXT NOT NULL,
  title       TEXT,
  reportsto   INT  REFERENCES employee(employeeid),
  hiredate    DATE,
  city        TEXT
);

CREATE TABLE customer (
  customerid   INT  PRIMARY KEY,
  firstname    TEXT NOT NULL,
  lastname     TEXT NOT NULL,
  email        TEXT NOT NULL,
  country      TEXT,
  supportrepid INT  REFERENCES employee(employeeid)
);

CREATE TABLE invoice (
  invoiceid    INT          PRIMARY KEY,
  customerid   INT          NOT NULL REFERENCES customer(customerid),
  invoicedate  DATE         NOT NULL,
  total        NUMERIC(10,2) NOT NULL
);

CREATE TABLE playlist (
  playlistid  INT  PRIMARY KEY,
  name        TEXT NOT NULL
);

CREATE TABLE playlisttrack (
  playlistid  INT NOT NULL REFERENCES playlist(playlistid),
  trackid     INT NOT NULL REFERENCES track(trackid),
  PRIMARY KEY (playlistid, trackid)
);

-- ── Seed data ─────────────────────────────────────────────────────────────────

-- Artists (200 rows)
INSERT INTO artist
SELECT i, 'Artist ' || i FROM generate_series(1, 200) i;

-- Albums (400 rows — 2 per artist on average)
INSERT INTO album
SELECT i, 'Album ' || i, 1 + mod(i - 1, 200)
FROM generate_series(1, 400) i;

-- Tracks (3 000 rows — ~7-8 per album)
INSERT INTO track (trackid, name, albumid, milliseconds, unitprice)
SELECT i,
       'Track ' || i,
       1 + mod(i - 1, 400),
       180000 + (mod(i * 7, 180000)),
       CASE WHEN mod(i, 3) = 0 THEN 1.99 ELSE 0.99 END
FROM generate_series(1, 3000) i;

-- Employees (8 rows — real Chinook hierarchy with Calgary / Lethbridge / Edmonton cities)
INSERT INTO employee VALUES
  (1, 'Adams',    'Andrew',   'General Manager',      NULL, '2002-08-14', 'Edmonton'),
  (2, 'Edwards',  'Nancy',    'Sales Manager',            1, '2002-05-01', 'Calgary'),
  (3, 'Peacock',  'Jane',     'Sales Support Agent',      2, '2002-04-01', 'Calgary'),
  (4, 'Park',     'Margaret', 'Sales Support Agent',      2, '2003-05-03', 'Calgary'),
  (5, 'Johnson',  'Steve',    'Sales Support Agent',      2, '2003-10-17', 'Calgary'),
  (6, 'Mitchell', 'Michael',  'IT Manager',               1, '2003-10-17', 'Lethbridge'),
  (7, 'King',     'Robert',   'IT Staff',                 6, '2004-01-02', 'Lethbridge'),
  (8, 'Callahan', 'Laura',    'IT Staff',                 6, '2004-03-04', 'Lethbridge');

-- Customers (60 rows)
INSERT INTO customer (customerid, firstname, lastname, email, country, supportrepid)
SELECT i,
       'First'  || i,
       'Last'   || i,
       'user'   || i || '@example.com',
       (ARRAY['USA','Canada','UK','Germany','France','Brazil','Australia','India','Japan','Portugal'])[1 + mod(i - 1, 10)],
       3 + mod(i - 1, 3)   -- supportrepid ∈ {3, 4, 5}
FROM generate_series(1, 60) i;

-- Invoices (412 rows — spread over ~4 years)
INSERT INTO invoice (invoiceid, customerid, invoicedate, total)
SELECT i,
       1 + mod(i - 1, 60),
       '2009-01-01'::DATE + ((i * 3) || ' days')::INTERVAL,
       round((1 + mod(i * 13, 2500) / 100.0)::numeric, 2)
FROM generate_series(1, 412) i;

-- Playlists (20 rows)
INSERT INTO playlist
SELECT i, 'Playlist ' || i FROM generate_series(1, 20) i;

-- PlaylistTrack (5 000 rows, deduped)
INSERT INTO playlisttrack
SELECT DISTINCT 1 + mod(i * 3,     20),
                1 + mod(i * 7 + 3, 3000)
FROM generate_series(1, 6000) i;

\echo '✅ Exercise tables ready (artist, album, track, customer, employee, invoice, playlist, playlisttrack)'
\echo ''


\echo ''
\echo '═══════════════════════════════════════════════════════════'
\echo '  Part 1 · Query Execution Patterns'
\echo '═══════════════════════════════════════════════════════════'

-- ── 1.1  Point lookup — hash vs range ────────────────────────────────────────
-- Hash PK: hash(trackid) → 1 tablet → 1 RPC.  Always fast, O(1).
-- Range PK: binary seek on sorted key → also 1 tablet if key is known exactly.

\echo '--- 1.1  Point lookup'

-- Hash-sharded: TrackId is the hash PK
:explain SELECT * FROM track WHERE trackid = 42;

-- Hash-sharded join: each side is a point lookup
:explain
SELECT t.name AS track, a.title AS album
FROM   track t
JOIN   album a ON t.albumid = a.albumid
WHERE  t.trackid = 42;

-- ── 1.2  Range scan vs full-table scan ────────────────────────────────────────
-- Range index: seeks to the start of the range, walks forward — only reads matching tablets.
-- Full scan:   fans out to ALL tablets (scatter-gather), reads every row.

\echo '--- 1.2  Range scan vs full scan'

-- First: no range index on unitprice — full scan
:explain SELECT * FROM track WHERE unitprice > 0.99;

-- Create a range index and see the difference
CREATE INDEX IF NOT EXISTS idx_track_price ON track (unitprice ASC);

:explain SELECT * FROM track WHERE unitprice > 0.99;

-- Full scan is unavoidable for a leading-wildcard LIKE (no index helps)
:explain SELECT * FROM track WHERE name LIKE '%Love%';

-- ── 1.3  ORDER BY: hash (scatter-gather-sort) vs range (streaming) ────────────
-- Hash PK → ORDER BY PK forces a full scatter-gather then sort in memory.
-- Range PK → ORDER BY PK streams rows already in order — no sort node.

\echo '--- 1.3  ORDER BY: hash penalty vs range benefit'

-- TrackId is HASH → scatter-gather + sort
:explain SELECT * FROM track ORDER BY trackid ASC LIMIT 10;

-- InvoiceDate is a range-indexed column (see idx_invoice_date below)
CREATE INDEX IF NOT EXISTS idx_invoice_date ON invoice (invoicedate ASC);

-- ASC matches index order → streaming, no sort needed
:explain SELECT * FROM invoice ORDER BY invoicedate ASC LIMIT 10;

-- DESC on the same index → backward scan, still no sort node
:explain SELECT * FROM invoice ORDER BY invoicedate DESC LIMIT 10;

DROP INDEX IF EXISTS idx_invoice_date;

-- ── 1.4  LIMIT pushdown ───────────────────────────────────────────────────────
-- On a range-sharded table, LIMIT is pushed into the storage layer.
-- The scan stops as soon as enough rows are found — no over-read.
-- On a hash-sharded table, LIMIT cannot stop early (all tablets must reply).

\echo '--- 1.4  LIMIT pushdown'

-- Pre-split range table to make the tablet stop visible in DIST output
CREATE TABLE IF NOT EXISTS listings (
  price       DECIMAL,
  listing_id  TEXT,
  name        TEXT,
  status      TEXT,
  PRIMARY KEY (price ASC, listing_id)
) SPLIT AT VALUES ((0.99), (1.99));

INSERT INTO listings (price, listing_id, name, status)
SELECT (0.50 + (i % 3) * 0.50)::DECIMAL,
       'list-' || i,
       'Track ' || i,
       (ARRAY['available','sold','reserved'])[1 + mod(i,3)]
FROM generate_series(1, 500) AS i
ON CONFLICT DO NOTHING;

-- Range table: scan stops after 3 rows are found in the correct tablet
:explain SELECT * FROM listings ORDER BY price ASC, listing_id ASC LIMIT 3;

-- Hash table: must read ALL tablets first
:explain SELECT * FROM track ORDER BY trackid LIMIT 3;

DROP TABLE IF EXISTS listings;

-- ── 1.5  Keyset pagination (cursor) vs OFFSET pagination ─────────────────────
-- OFFSET N: DocDB reads and discards N rows before returning results.
-- Cost grows linearly with depth (page 1000 is 1000× slower than page 1).
-- Keyset (WHERE + ORDER BY on PK): constant cost at any depth.

\echo '--- 1.5  Keyset vs OFFSET pagination'

-- ❌ OFFSET — O(OFFSET) cost, gets slower every page
:explain
SELECT invoiceid, customerid, invoicedate, total
FROM   invoice
ORDER BY invoicedate ASC, invoiceid ASC
LIMIT  10 OFFSET 200;

-- ✅ Keyset — O(log N), same cost regardless of depth
-- Pass last row's (invoicedate, invoiceid) as the cursor
:explain
SELECT invoiceid, customerid, invoicedate, total
FROM   invoice
WHERE  (invoicedate, invoiceid) > ('2009-03-04'::DATE, 100)
ORDER BY invoicedate ASC, invoiceid ASC
LIMIT  10;


\echo ''
\echo '═══════════════════════════════════════════════════════════'
\echo '  Part 2 · Pushdown Operations'
\echo '═══════════════════════════════════════════════════════════'

-- YugabyteDB pushes work into the DocDB storage layer so less data travels
-- over the network between the storage and query-processing tiers.

-- ── 2.1  Aggregate pushdown ───────────────────────────────────────────────────
-- COUNT, SUM, MIN, MAX are computed per tablet in storage,
-- only partial results come back — no raw rows over the wire.

\echo '--- 2.1  Aggregate pushdown'

:explain SELECT count(1) FROM track;
:explain SELECT count(1), sum(milliseconds) FROM track;

-- Verify: look for "Partial Aggregate" in the plan — that's the pushdown

-- ── 2.2  Distinct pushdown ────────────────────────────────────────────────────
-- DISTINCT on an indexed column is resolved in storage,
-- one seek per distinct value rather than reading all duplicates.

\echo '--- 2.2  Distinct pushdown'

:explain SELECT DISTINCT albumid FROM track WHERE albumid > 0;

-- ── 2.3  Expression pushdown ──────────────────────────────────────────────────
-- WHERE predicates containing functions are evaluated at the DocDB layer.
-- Only rows that pass the predicate are returned — no post-filter in YSQL.

\echo '--- 2.3  Expression pushdown'

:explain SELECT * FROM track WHERE upper(name) LIKE 'THE TROOPER%';
:explain SELECT * FROM invoice WHERE total > 5;

-- Look for "Storage Filter:" in the plan — that confirms pushdown is active.
-- To compare without pushdown (testing only):
-- SET yb_enable_expression_pushdown = false;
-- :explain SELECT * FROM invoice WHERE total > 5;
-- SET yb_enable_expression_pushdown = true;


\echo ''
\echo '═══════════════════════════════════════════════════════════'
\echo '  Part 3 · Index Strategies'
\echo '═══════════════════════════════════════════════════════════'

-- ── 3.1  Hash index — equality lookups ───────────────────────────────────────
-- A secondary HASH index is a separate tablet group keyed by the indexed column.
-- Lookup path: hash(col) → index tablet → get PK → main tablet (2 RPCs).

\echo '--- 3.1  Hash index'

-- Before index: full scan on AlbumId
:explain SELECT * FROM track WHERE albumid = 1;

CREATE INDEX IF NOT EXISTS idx_track_albumid ON track (albumid HASH);

-- After: index scan (note "Index Scan using idx_track_albumid")
:explain SELECT * FROM track WHERE albumid = 1;

-- ── 3.2  Range index — range scans and ordering ───────────────────────────────

\echo '--- 3.2  Range index'

-- Before: full scan
:explain SELECT * FROM invoice WHERE invoicedate > '2010-01-01';

CREATE INDEX IF NOT EXISTS idx_invoice_date ON invoice (invoicedate ASC);

-- After: range index scan — only touches relevant tablets
:explain SELECT * FROM invoice WHERE invoicedate > '2010-01-01';

-- ORDER BY on the indexed column is now free (no sort node)
:explain SELECT * FROM invoice ORDER BY invoicedate ASC LIMIT 20;

-- ── 3.3  Covering index (INCLUDE) ─────────────────────────────────────────────
-- Store the projected columns inside the index leaf; avoids the second
-- main-table fetch → index-only scan (1 RPC instead of 2).

\echo '--- 3.3  Covering index (INCLUDE)'

-- With a plain hash index: 2-RPC path (index + table fetch)
:explain SELECT trackid, composer FROM track WHERE albumid = 1;

-- Covering index stores TrackId and Composer directly
CREATE INDEX IF NOT EXISTS idx_track_albumid_cover
  ON track (albumid HASH)
  INCLUDE (trackid, composer);

-- Now: index-only scan (no heap fetch)
:explain SELECT trackid, composer FROM track WHERE albumid = 1;

-- ❌ SELECT * still needs the main table (milliseconds, unitprice, etc. not in index)
:explain SELECT * FROM track WHERE albumid = 1;

-- ── 3.4  Partial index ────────────────────────────────────────────────────────
-- Only index rows matching a WHERE condition.
-- Excludes low-signal values → smaller index, faster maintenance.

\echo '--- 3.4  Partial index'

-- Index only employees NOT in the two most-common cities
CREATE INDEX IF NOT EXISTS idx_employee_city
  ON employee (city HASH)
  WHERE city NOT IN ('Lethbridge', 'Edmonton');

-- ✅ Can use index (predicate compatible)
:explain SELECT * FROM employee WHERE city = 'Calgary';

-- ❌ Cannot use this index — city IS in the excluded list
:explain SELECT * FROM employee WHERE city = 'Lethbridge';

-- ── 3.5  Index forward and backward scan ─────────────────────────────────────
-- A range index serves both ASC and DESC scans.
-- DESC is a backward scan (slightly higher cost, but still efficient).

\echo '--- 3.5  Forward and backward scan'

CREATE INDEX IF NOT EXISTS idx_customer_repid
  ON customer (supportrepid ASC);

-- Forward scan (ASC matches index direction)
:explain SELECT * FROM customer ORDER BY supportrepid ASC;

-- Backward scan (DESC reverses direction)
:explain SELECT * FROM customer ORDER BY supportrepid DESC;

-- ── 3.6  Expression index ─────────────────────────────────────────────────────
-- Index a function of a column. WHERE must use the same expression exactly.

\echo '--- 3.6  Expression index'

CREATE INDEX IF NOT EXISTS idx_customer_lower_email
  ON customer (lower(email) HASH);

-- ✅ Expression matches — uses the index
:explain SELECT * FROM customer WHERE lower(email) = 'luisg@embraer.com.br';

-- ❌ Raw column — cannot use the expression index
:explain SELECT * FROM customer WHERE email = 'luisg@embraer.com.br';


\echo ''
\echo '═══════════════════════════════════════════════════════════'
\echo '  Part 4 · Join Optimization'
\echo '═══════════════════════════════════════════════════════════'

-- ── 4.1  Join order hints ─────────────────────────────────────────────────────
-- Leading() controls which tables are joined first.
-- Choosing a selective table first reduces intermediate row counts.

\echo '--- 4.1  Join order hints'

-- Default join order chosen by the planner
:explain
SELECT t.trackid,
       t.name        AS track_name,
       a.title       AS album_title,
       ar.name       AS artist_name
FROM   track t
JOIN   album  a  ON t.albumid   = a.albumid
JOIN   artist ar ON a.artistid  = ar.artistid
WHERE  t.trackid = 5;

-- Force a specific join order: (track ⋈ album) ⋈ artist
:explain
/*+Leading ( ( ( t a ) ar ) ) */
SELECT t.trackid,
       t.name        AS track_name,
       a.title       AS album_title,
       ar.name       AS artist_name
FROM   track t
JOIN   album  a  ON t.albumid   = a.albumid
JOIN   artist ar ON a.artistid  = ar.artistid
WHERE  t.trackid = 5;

-- Force alternate order: artist ⋈ (album ⋈ track)
:explain
/*+Leading ( ( ar ( a t ) ) ) */
SELECT t.trackid,
       t.name        AS track_name,
       a.title       AS album_title,
       ar.name       AS artist_name
FROM   track t
JOIN   album  a  ON t.albumid   = a.albumid
JOIN   artist ar ON a.artistid  = ar.artistid
WHERE  t.trackid = 5;

-- ── 4.2  Batch Nested Loop (BNL) ─────────────────────────────────────────────
-- BNL batches multiple inner-side keys into a single storage RPC.
-- Dramatically reduces round-trips for multi-table joins.
-- Tune yb_bnl_batch_size (default 1024) for your workload.

\echo '--- 4.2  Batch Nested Loop'

SET yb_bnl_batch_size = 1;    -- baseline: 1 row per RPC (slowest)

:explain
SELECT p.playlistid,
       p.name       AS playlist_name,
       t.name       AS track_name,
       ar.name      AS artist_name
FROM   playlist      p
JOIN   playlisttrack pt ON  p.playlistid  = pt.playlistid
JOIN   track         t  ON pt.trackid     = t.trackid
JOIN   album         a  ON  t.albumid     = a.albumid
JOIN   artist       ar  ON  a.artistid    = ar.artistid
WHERE  p.playlistid = 3;

SET yb_bnl_batch_size = 1024; -- batch: 1024 keys per RPC (much faster)

:explain
SELECT p.playlistid,
       p.name       AS playlist_name,
       t.name       AS track_name,
       ar.name      AS artist_name
FROM   playlist      p
JOIN   playlisttrack pt ON  p.playlistid  = pt.playlistid
JOIN   track         t  ON pt.trackid     = t.trackid
JOIN   album         a  ON  t.albumid     = a.albumid
JOIN   artist       ar  ON  a.artistid    = ar.artistid
WHERE  p.playlistid = 3;

RESET yb_bnl_batch_size;


\echo ''
\echo '═══════════════════════════════════════════════════════════'
\echo '  Part 5 · Advanced SQL'
\echo '═══════════════════════════════════════════════════════════'

-- ── 5.1  Prepared statements ─────────────────────────────────────────────────
-- PREPARE parses and plans once; EXECUTE reuses the plan.
-- Eliminates per-query planning overhead for repeated queries.

\echo '--- 5.1  Prepared statements'

PREPARE tracks_by_artist(text) AS
  SELECT t.name AS track, t.milliseconds, t.unitprice
  FROM   track t
  JOIN   album  a  ON t.albumid  = a.albumid
  JOIN   artist ar ON a.artistid = ar.artistid
  WHERE  ar.name = $1
  ORDER BY t.name;

EXECUTE tracks_by_artist('AC/DC');
EXECUTE tracks_by_artist('Metallica');

DEALLOCATE tracks_by_artist;

-- ── 5.2  Common Table Expressions (CTE) ──────────────────────────────────────

\echo '--- 5.2  CTE'

-- Customers who spent more than their country's average — two-pass with CTEs
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
SELECT cs.country,
       cs.name,
       round(cs.total_spend::numeric, 2) AS total_spend,
       round(ca.avg_spend::numeric,   2) AS country_avg
FROM   customer_spend cs
JOIN   country_avg    ca USING (country)
WHERE  cs.total_spend > ca.avg_spend
ORDER BY cs.country, cs.total_spend DESC;

-- ── 5.3  Recursive CTE ───────────────────────────────────────────────────────
-- Walk a self-referential hierarchy without application-side looping.
-- Chinook's employee table has a ReportsTo (self-FK) column — a real org chart.

\echo '--- 5.3  Recursive CTE (org chart)'

WITH RECURSIVE org_tree AS (
  -- Anchor: top-level employees (no manager)
  SELECT employeeid,
         firstname || ' ' || lastname           AS name,
         title,
         reportsto,
         firstname || ' ' || lastname           AS path,
         0                                      AS depth
  FROM   employee
  WHERE  reportsto IS NULL

  UNION ALL

  -- Recursive: each employee reports to a node already in the tree
  SELECT e.employeeid,
         e.firstname || ' ' || e.lastname,
         e.title,
         e.reportsto,
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

-- ── 5.4  Window functions ─────────────────────────────────────────────────────
-- OVER() defines a logical window (partition + order) for each row.
-- LAG peeks at the previous row without a self-join.

\echo '--- 5.4  Window functions'

-- Invoice delta per customer: how much more/less than the previous invoice?
SELECT customerid,
       invoicedate,
       total,
       LAG(total) OVER per_customer_date         AS prev_invoice,
       total - LAG(total) OVER per_customer_date AS delta
FROM   invoice
WINDOW per_customer_date AS (
  PARTITION BY customerid ORDER BY invoicedate
)
ORDER BY customerid, invoicedate
LIMIT 30;

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

-- ── 5.5  GROUP BY with NTILE ──────────────────────────────────────────────────

\echo '--- 5.5  GROUP BY + NTILE'

-- Bucket customers into 3 spend tiers (Low / Mid / High)
WITH spend AS (
  SELECT customerid, SUM(total) AS total_spend
  FROM   invoice
  GROUP BY customerid
),
tiered AS (
  SELECT customerid,
         ntile(3) OVER (ORDER BY total_spend) AS tier,
         round(total_spend::numeric, 2)        AS total_spend
  FROM   spend
)
SELECT tier,
       CASE tier WHEN 1 THEN 'Low' WHEN 2 THEN 'Mid' ELSE 'High' END AS label,
       count(*)                           AS customers,
       round(min(total_spend)::numeric,2) AS min_spend,
       round(max(total_spend)::numeric,2) AS max_spend
FROM   tiered
GROUP BY tier
ORDER BY tier;


\echo ''
\echo '═══════════════════════════════════════════════════════════'
\echo '  Part 6 · Programmability'
\echo '═══════════════════════════════════════════════════════════'

-- ── 6.1  Stored procedure with transaction control ────────────────────────────
-- Apply a price adjustment to a track; raise an exception if not found.
-- Demonstrates BEGIN/COMMIT inside a procedure and RAISE EXCEPTION.

\echo '--- 6.1  Procedure'

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

-- ✅ Valid adjustment
SELECT trackid, name, unitprice FROM track WHERE trackid = 1;
CALL adjust_track_price(1, 0.10);
SELECT trackid, name, unitprice FROM track WHERE trackid = 1;

-- ❌ Non-existent track → exception (transaction rolls back)
CALL adjust_track_price(999999, 0.10);

-- ── 6.2  Trigger ─────────────────────────────────────────────────────────────
-- Automatically record when a track's price was last changed.
-- WHEN clause: fire only when unitprice actually changes.

\echo '--- 6.2  Trigger (price audit timestamp)'

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

-- Before: price_updated_at is NULL
SELECT trackid, name, unitprice, price_updated_at FROM track WHERE trackid IN (1, 2, 3);

CALL adjust_track_price(1, 0.05);
CALL adjust_track_price(2, 0.05);

-- After: only updated tracks have price_updated_at set
SELECT trackid, name, unitprice, price_updated_at FROM track WHERE trackid IN (1, 2, 3);

-- ── 6.3  Materialized view ────────────────────────────────────────────────────
-- Precomputes an expensive aggregation and stores the result as a table.
-- Refresh explicitly; can be indexed just like a regular table.

\echo '--- 6.3  Materialized view'

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

-- Index scan on the materialized view
:explain
SELECT * FROM mv_revenue_by_country
WHERE  total_revenue > 50
ORDER BY total_revenue DESC;

SELECT * FROM mv_revenue_by_country LIMIT 10;


\echo ''
\echo '✅  All exercises complete.'
\echo '   To reset: reconnect and re-run, or drop the indexes/objects created above.'
