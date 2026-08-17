-- ─────────────────────────────────────────────────────────────────────────────
-- Pub/Sub CDC demo schema — applied to BOTH the publisher and the subscriber.
--
-- The applier replicates DATA only. It issues no DDL against the subscriber,
-- ever, so the subscriber's schema has to be created out of band — which is
-- exactly what this file does. Both sides are loaded from the same DDL so the
-- shapes are identical by construction.
--
-- Two constraints the pipeline actually depends on:
--   * every table has a PRIMARY KEY — YugabyteDB CDC does not support tables
--     without one, and the applier needs a unique constraint to target its
--     upserts (ON CONFLICT) and deletes at.
--   * no foreign keys — the initial snapshot reads tables independently, so
--     child rows can land before their parents. Referential integrity belongs
--     on the publisher; the subscriber is a replica, not a second system of
--     record.
--
-- Explicit BIGINT keys rather than SERIAL: YugabyteDB sequences cache 100
-- values per node, so a SERIAL demo table hands out id=101 where the reader
-- expects id=2. Deterministic ids keep the walkthrough readable.
-- ─────────────────────────────────────────────────────────────────────────────

DROP TABLE IF EXISTS public.orders;
DROP TABLE IF EXISTS public.products;
DROP TABLE IF EXISTS public.customers;

CREATE TABLE public.customers (
  id         BIGINT      PRIMARY KEY,
  name       TEXT        NOT NULL,
  email      TEXT,
  tier       TEXT,
  signed_up  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE public.products (
  id         BIGINT        PRIMARY KEY,
  sku        TEXT          NOT NULL,
  name       TEXT          NOT NULL,
  price      NUMERIC(10,2) NOT NULL,
  in_stock   INTEGER       NOT NULL DEFAULT 0
);

CREATE TABLE public.orders (
  id           BIGINT      PRIMARY KEY,
  customer_id  BIGINT      NOT NULL,
  product_id   BIGINT      NOT NULL,
  qty          INTEGER     NOT NULL,
  status       TEXT        NOT NULL,
  placed_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
