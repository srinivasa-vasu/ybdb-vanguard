-- ─────────────────────────────────────────────────────────────────────────────
-- Seed data — loaded into the PUBLISHER only.
--
-- The subscriber starts with the same tables and zero rows. That gap is what
-- the initial snapshot closes: when the applier creates its replication slot,
-- it reads every existing row of every captured table and applies it, before a
-- single streamed change is processed.
--
-- Ids start at 1 and are contiguous, so the live INSERT/UPDATE/DELETE steps
-- later in the walkthrough can use ids well above these ranges without
-- colliding.
-- ─────────────────────────────────────────────────────────────────────────────

INSERT INTO public.customers (id, name, email, tier)
SELECT g,
       'Customer ' || g,
       'customer' || g || '@example.com',
       (ARRAY['free', 'standard', 'premium'])[1 + (g % 3)]
FROM generate_series(1, 200) AS g;

INSERT INTO public.products (id, sku, name, price, in_stock)
SELECT g,
       'SKU-' || lpad(g::text, 5, '0'),
       'Product ' || g,
       round((9.99 + (g * 7.31))::numeric, 2),
       100 + (g % 50)
FROM generate_series(1, 50) AS g;

INSERT INTO public.orders (id, customer_id, product_id, qty, status)
SELECT g,
       1 + (g % 200),
       1 + (g % 50),
       1 + (g % 4),
       (ARRAY['placed', 'shipped', 'delivered'])[1 + (g % 3)]
FROM generate_series(1, 500) AS g;
