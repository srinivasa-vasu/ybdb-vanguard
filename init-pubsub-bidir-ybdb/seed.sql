-- ─────────────────────────────────────────────────────────────────────────────
-- Seed data — loaded IDENTICALLY into both sites.
--
-- Both lanes run with snapshot-mode: never, so neither applier copies
-- pre-existing rows; they stream changes only, from the moment their slot is
-- created. The two sites therefore have to start out already converged, which
-- is how a real two-way topology is bootstrapped: seed (or restore a backup) on
-- both sides while nothing is writing, then start replication.
--
-- Using snapshot-mode: initial here would be worse than unnecessary. A snapshot
-- reads current table state rather than WAL, so the rows it emits carry no
-- replication origin — the loop filter cannot recognise them, and each site
-- would echo the other's snapshot straight back.
--
-- The timestamps are FIXED rather than now(). The two sites are seeded by
-- separate statements a moment apart, so now() would give the "identical" rows
-- different versions on each side — harmless here, but it would mean the sites
-- did not literally start equal, and under last-writer-wins the starting
-- version is exactly what the first real update is compared against.
--
-- Id ranges are disjoint so the sites can never collide on an order:
--   site A owns orders 1000-1999
--   site B owns orders 2000-2999
-- The seed uses 1-20, which is neither site's live range.
-- ─────────────────────────────────────────────────────────────────────────────

INSERT INTO public.orders (id, item, qty, status, last_modified)
SELECT g,
       'Widget ' || g,
       1 + (g % 5),
       'delivered',
       TIMESTAMPTZ '2026-01-01 00:00:00+00'
FROM generate_series(1, 20) AS g;

INSERT INTO public.stock (sku, qty, updated_at) VALUES
  ('SKU-001', 500, TIMESTAMPTZ '2026-01-01 00:00:00+00'),
  ('SKU-002', 500, TIMESTAMPTZ '2026-01-01 00:00:00+00'),
  ('SKU-003', 500, TIMESTAMPTZ '2026-01-01 00:00:00+00'),
  ('SKU-004', 500, TIMESTAMPTZ '2026-01-01 00:00:00+00'),
  ('SKU-005', 500, TIMESTAMPTZ '2026-01-01 00:00:00+00');
