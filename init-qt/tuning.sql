-- ─────────────────────────────────────────────────────────────────────────────
-- tuning.sql  —  Setup: create and seed all query-tuning exercise tables
--
-- Run once at the start of your session, then work through the exercises
-- in README.md by selecting each SQL block and pressing the run shortcut.
--
-- Usage:
--   ysqlsh
--   \i init-qt/tuning.sql
--   \set explain 'EXPLAIN (ANALYZE, DIST, COSTS ON, BUFFERS OFF)'
-- ─────────────────────────────────────────────────────────────────────────────

-- Drop in FK-safe order so the file is idempotent (safe to re-run)
DROP TABLE IF EXISTS playlisttrack, playlist, invoiceline, invoice,
                     track, album, artist, customer, employee CASCADE;

-- ── Schema ────────────────────────────────────────────────────────────────────
-- Sharding is spelled out (HASH / ASC) on every key: the default depends on
-- yb_use_hash_splitting_by_default, so explicit DDL behaves the same everywhere.

CREATE TABLE artist (
  artistid  INT  NOT NULL,
  name      TEXT NOT NULL,
  PRIMARY KEY (artistid HASH)
);

CREATE TABLE album (
  albumid   INT  NOT NULL,
  title     TEXT NOT NULL,
  artistid  INT  NOT NULL REFERENCES artist(artistid),
  PRIMARY KEY (albumid HASH)
);

CREATE TABLE track (
  trackid      INT            NOT NULL,
  name         TEXT           NOT NULL,
  albumid      INT            NOT NULL REFERENCES album(albumid),
  milliseconds INT            NOT NULL,
  unitprice    NUMERIC(5,2)   NOT NULL DEFAULT 0.99,
  PRIMARY KEY (trackid HASH)
);

CREATE TABLE employee (
  employeeid  INT  NOT NULL,
  lastname    TEXT NOT NULL,
  firstname   TEXT NOT NULL,
  title       TEXT,
  reportsto   INT  REFERENCES employee(employeeid),
  hiredate    DATE,
  city        TEXT,
  PRIMARY KEY (employeeid HASH)
);

CREATE TABLE customer (
  customerid   INT  NOT NULL,
  firstname    TEXT NOT NULL,
  lastname     TEXT NOT NULL,
  email        TEXT NOT NULL,
  country      TEXT,
  supportrepid INT  REFERENCES employee(employeeid),
  PRIMARY KEY (customerid HASH)
);

CREATE TABLE invoice (
  invoiceid    INT           NOT NULL,
  customerid   INT           NOT NULL REFERENCES customer(customerid),
  invoicedate  DATE          NOT NULL,
  total        NUMERIC(10,2) NOT NULL,
  PRIMARY KEY (invoiceid HASH)
);

CREATE TABLE playlist (
  playlistid  INT  NOT NULL,
  name        TEXT NOT NULL,
  PRIMARY KEY (playlistid HASH)
);

CREATE TABLE playlisttrack (
  playlistid  INT NOT NULL REFERENCES playlist(playlistid),
  trackid     INT NOT NULL REFERENCES track(trackid),
  -- Child sharded by the parent's key: one playlist's rows share a tablet,
  -- and the PK's leading column doubles as the playlistid FK index.
  PRIMARY KEY (playlistid HASH, trackid ASC)
);

-- ── Foreign-key indexes ───────────────────────────────────────────────────────
-- Every FK column needs an index in the child table; without one, a DELETE or
-- key UPDATE on the parent scans the whole child table across all tablets.
-- Two are left out on purpose: the exercises build them by hand.
--   track.albumid         → Part 3.1 / 3.3 (hash index, then covering index)
--   customer.supportrepid → Part 3.5 (range index, pre-split)
CREATE INDEX idx_album_artistid        ON album         (artistid HASH);
CREATE INDEX idx_invoice_customerid    ON invoice       (customerid HASH);
CREATE INDEX idx_playlisttrack_trackid ON playlisttrack (trackid HASH);
-- Nullable FK (the top manager has no manager): index only non-NULL rows
CREATE INDEX idx_employee_reportsto    ON employee      (reportsto HASH)
  WHERE reportsto IS NOT NULL;

-- ── Seed data ─────────────────────────────────────────────────────────────────

INSERT INTO artist SELECT i, 'Artist ' || i FROM generate_series(1, 200) i;

INSERT INTO album
SELECT i, 'Album ' || i, 1 + mod(i - 1, 200) FROM generate_series(1, 400) i;

INSERT INTO track (trackid, name, albumid, milliseconds, unitprice)
SELECT i, 'Track ' || i, 1 + mod(i - 1, 400),
       180000 + (mod(i * 7, 180000)),
       CASE WHEN mod(i, 3) = 0 THEN 1.99 ELSE 0.99 END
FROM generate_series(1, 3000) i;

INSERT INTO employee VALUES
  (1,'Adams',   'Andrew',   'General Manager',    NULL,'2002-08-14','Edmonton'),
  (2,'Edwards', 'Nancy',    'Sales Manager',          1,'2002-05-01','Calgary'),
  (3,'Peacock', 'Jane',     'Sales Support Agent',    2,'2002-04-01','Calgary'),
  (4,'Park',    'Margaret', 'Sales Support Agent',    2,'2003-05-03','Calgary'),
  (5,'Johnson', 'Steve',    'Sales Support Agent',    2,'2003-10-17','Calgary'),
  (6,'Mitchell','Michael',  'IT Manager',             1,'2003-10-17','Lethbridge'),
  (7,'King',    'Robert',   'IT Staff',               6,'2004-01-02','Lethbridge'),
  (8,'Callahan','Laura',    'IT Staff',               6,'2004-03-04','Lethbridge');

INSERT INTO customer (customerid, firstname, lastname, email, country, supportrepid)
SELECT i, 'First' || i, 'Last' || i, 'user' || i || '@example.com',
       (ARRAY['USA','Canada','UK','Germany','France','Brazil','Australia','India','Japan','Portugal'])[1 + mod(i-1,10)],
       3 + mod(i-1, 3)
FROM generate_series(1, 60) i;

INSERT INTO invoice (invoiceid, customerid, invoicedate, total)
SELECT i, 1 + mod(i-1,60),
       '2009-01-01'::DATE + ((i * 3) || ' days')::INTERVAL,
       round((1 + mod(i*13,2500)/100.0)::numeric, 2)
FROM generate_series(1, 412) i;

INSERT INTO playlist SELECT i, 'Playlist ' || i FROM generate_series(1, 20) i;

INSERT INTO playlisttrack
SELECT DISTINCT 1 + mod(i*3, 20), 1 + mod(i*7+3, 3000)
FROM generate_series(1, 6000) i;

\echo ''
\echo '✅ Tables ready: artist(200) album(400) track(3000) customer(60) invoice(412)'
\echo '   employee(8) playlist(20) playlisttrack(~5000)'
\echo '   + FK indexes on album, invoice, playlisttrack, employee (track/customer: Part 3)'
\echo ''
\echo 'Set the EXPLAIN shorthand for this session:'
\echo '   \set explain '"'"'EXPLAIN (ANALYZE, DIST, COSTS ON, BUFFERS OFF)'"'"''
\echo ''
\echo 'Then work through the exercises in README.md.'
\echo 'Select any SQL block and press Ctrl+Shift+Enter (Cmd+Shift+Enter on Mac)'
\echo 'to run it in this terminal.'
