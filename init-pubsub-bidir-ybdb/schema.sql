-- ─────────────────────────────────────────────────────────────────────────────
-- Two-way pub/sub demo schema — applied identically to BOTH sites.
--
-- Neither applier issues DDL, so both schemas are created out of band from this
-- one file. In a two-way topology that is not just convenient, it is required:
-- each site is simultaneously a publisher and a subscriber, so a column that
-- exists on only one side breaks replication in one direction.
--
-- ── No "which site wrote this" column ────────────────────────────────────────
-- There isn't one, deliberately. Tagging every row with its writer would mean
-- changing every table in the database to suit the replication topology, and
-- the application would have to maintain it on every write. Write ownership is
-- a routing rule that lives OUTSIDE the data — here, each site owns a disjoint
-- range of order ids. Nothing in the schema encodes it.
--
-- ── The timestamp column is different ───────────────────────────────────────
-- `last_modified` / `updated_at` are not replication metadata; they are columns
-- these tables would carry anyway. That is exactly why last-writer-wins can use
-- them: the column is IN THE ROW, so a local write maintains it just as a
-- replicated write does, and the comparison always reads the row's real current
-- version. A version store the pipeline owned on the side would be blind to
-- direct local writes and would need a trigger on every table to close the gap.
--
-- The two tables name it differently on purpose. `consumer.conflict-columns`
-- lists the candidates and each table is matched independently, so the applier
-- logs one line per table naming the column that guards it.
--
--   orders  — append-mostly, each site inserting into its OWN id range.
--             Disjoint ownership means the sites cannot write the same row, so
--             they converge without conflict resolution ever being consulted.
--
--   stock   — a small shared set of rows that BOTH sites update. This is where
--             the topology gets interesting, and where the timestamp guard
--             earns its place.
--
-- Primary keys are mandatory (YugabyteDB CDC requires them, and the appliers
-- upsert/delete by key). No foreign keys: each site applies the other's changes
-- independently, so referential order across tables is not guaranteed.
-- ─────────────────────────────────────────────────────────────────────────────

DROP TABLE IF EXISTS public.orders;
DROP TABLE IF EXISTS public.stock;

CREATE TABLE public.orders (
  id             BIGINT      PRIMARY KEY,
  item           TEXT        NOT NULL,
  qty            INTEGER     NOT NULL,
  status         TEXT        NOT NULL,
  last_modified  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE public.stock (
  sku         TEXT        PRIMARY KEY,
  qty         INTEGER     NOT NULL,
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
