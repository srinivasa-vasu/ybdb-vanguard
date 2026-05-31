-- ═════════════════════════════════════════════════════════════════════════════
-- rls.sql  —  Row Level Security & Multi-tenancy
-- Load: \i init-rls/rls.sql   (or paste blocks interactively)
-- ═════════════════════════════════════════════════════════════════════════════

\echo ''
\echo '════════════════════════════════════════════════════════════════════'
\echo ' Part 1 — Basic RLS: current_user-based row filter                   '
\echo '════════════════════════════════════════════════════════════════════'

-- ── 1.1  Setup ───────────────────────────────────────────────────────────────
\echo '-- 1.1  Create employees table and roles'
DROP TABLE IF EXISTS employees CASCADE;
CREATE TABLE employees (
    emp_id    SERIAL PRIMARY KEY,
    ename     TEXT   NOT NULL,
    salary    NUMERIC(10,2),
    dept      TEXT
);

INSERT INTO employees (ename, salary, dept) VALUES
  ('alice',   95000, 'engineering'),
  ('bob',     85000, 'sales'),
  ('carol',  110000, 'engineering'),
  ('dave',    75000, 'hr');

DROP ROLE IF EXISTS alice;
DROP ROLE IF EXISTS bob;
CREATE ROLE alice LOGIN;
CREATE ROLE bob   LOGIN;
GRANT SELECT ON employees TO alice, bob;

\echo '-- Before RLS: both roles see all rows'
SELECT * FROM employees;

-- ── 1.2  Enable RLS and add self-view policy ─────────────────────────────────
\echo '-- 1.2  Enable RLS — policy: each user sees only their own row'
ALTER TABLE employees ENABLE ROW LEVEL SECURITY;

CREATE POLICY emp_self_policy ON employees
  FOR ALL TO PUBLIC
  USING (ename = current_user);

\echo '-- Alice sees only her row'
SET ROLE alice;
SELECT * FROM employees;
RESET ROLE;

\echo '-- Bob sees only his row'
SET ROLE bob;
SELECT * FROM employees;
RESET ROLE;

\echo '-- Table owner (yugabyte) bypasses RLS by default'
SELECT * FROM employees;

-- ── 1.3  DROP policy and disable ─────────────────────────────────────────────
DROP POLICY emp_self_policy ON employees;
ALTER TABLE employees DISABLE ROW LEVEL SECURITY;


\echo ''
\echo '════════════════════════════════════════════════════════════════════'
\echo ' Part 2 — Multi-tenant isolation with session variable               '
\echo '════════════════════════════════════════════════════════════════════'

-- ── 2.1  Multi-tenant orders table ───────────────────────────────────────────
\echo '-- 2.1  Shared orders table across tenants'
DROP TABLE IF EXISTS orders CASCADE;
CREATE TABLE orders (
    order_id  SERIAL          PRIMARY KEY,
    tenant_id TEXT            NOT NULL,
    customer  TEXT            NOT NULL,
    amount    NUMERIC(10,2)   NOT NULL,
    status    TEXT            NOT NULL DEFAULT 'pending'
);

INSERT INTO orders (tenant_id, customer, amount, status) VALUES
  ('acme',    'Alice Johnson', 1250.00, 'completed'),
  ('acme',    'Bob Williams',   890.00, 'pending'),
  ('globex',  'Carol Smith',   2100.00, 'completed'),
  ('globex',  'Dave Brown',     450.00, 'pending'),
  ('initech', 'Eve Davis',     1750.00, 'completed');

-- ── 2.2  Enable RLS + tenant isolation policy ─────────────────────────────────
\echo '-- 2.2  RLS policy driven by session variable app.tenant_id'
ALTER TABLE orders ENABLE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation ON orders
  FOR ALL
  USING (tenant_id = current_setting('app.tenant_id', true));

\echo '-- Acme tenant sees only their rows'
SET app.tenant_id = 'acme';
SELECT * FROM orders;

\echo '-- Globex tenant sees only their rows'
SET app.tenant_id = 'globex';
SELECT * FROM orders;

\echo '-- No tenant set → zero rows (safe default)'
RESET app.tenant_id;
SELECT * FROM orders;

-- ── 2.3  WITH CHECK prevents cross-tenant INSERT ──────────────────────────────
\echo '-- 2.3  WITH CHECK: block cross-tenant inserts'
DROP POLICY tenant_isolation ON orders;
CREATE POLICY tenant_isolation ON orders
  FOR ALL
  USING      (tenant_id = current_setting('app.tenant_id', true))
  WITH CHECK (tenant_id = current_setting('app.tenant_id', true));

\echo '-- Attempt to insert for a different tenant (should fail)'
SET app.tenant_id = 'acme';
DO $$
BEGIN
  BEGIN
    INSERT INTO orders (tenant_id, customer, amount)
    VALUES ('globex', 'Malicious Actor', 9999.99);
    RAISE NOTICE 'ERROR: insert should have been blocked!';
  EXCEPTION
    WHEN others THEN
      RAISE NOTICE 'BLOCKED: new row violates RLS policy — %', SQLERRM;
  END;
END $$;
RESET app.tenant_id;


\echo ''
\echo '════════════════════════════════════════════════════════════════════'
\echo ' Part 3 — SELECT-only vs write policies, role-specific policies      '
\echo '════════════════════════════════════════════════════════════════════'

\echo '-- 3.1  Read-only employees can SELECT but not UPDATE across tenants'
DROP POLICY IF EXISTS tenant_isolation ON orders;

CREATE POLICY tenant_read ON orders
  FOR SELECT
  USING (tenant_id = current_setting('app.tenant_id', true));

CREATE POLICY tenant_write ON orders
  FOR INSERT
  WITH CHECK (tenant_id = current_setting('app.tenant_id', true));

CREATE POLICY tenant_modify ON orders
  FOR UPDATE
  USING      (tenant_id = current_setting('app.tenant_id', true))
  WITH CHECK (tenant_id = current_setting('app.tenant_id', true));

CREATE POLICY tenant_delete ON orders
  FOR DELETE
  USING (tenant_id = current_setting('app.tenant_id', true));

\echo '-- Each DML operation has its own enforceable policy'
SELECT policyname, cmd, qual, with_check
FROM pg_policies
WHERE tablename = 'orders'
ORDER BY policyname;

-- Consolidate back to a single policy for the rest of the exercise
DROP POLICY tenant_read   ON orders;
DROP POLICY tenant_write  ON orders;
DROP POLICY tenant_modify ON orders;
DROP POLICY tenant_delete ON orders;

CREATE POLICY tenant_isolation ON orders
  FOR ALL
  USING      (tenant_id = current_setting('app.tenant_id', true))
  WITH CHECK (tenant_id = current_setting('app.tenant_id', true));


\echo ''
\echo '════════════════════════════════════════════════════════════════════'
\echo ' Part 4 — BYPASSRLS for admin and SECURITY DEFINER functions         '
\echo '════════════════════════════════════════════════════════════════════'

\echo '-- 4.1  Admin role bypasses RLS'
DROP ROLE IF EXISTS platform_admin;
CREATE ROLE platform_admin LOGIN PASSWORD 'admin123';
GRANT ALL ON orders TO platform_admin;
ALTER ROLE platform_admin BYPASSRLS;

\echo '-- platform_admin sees all tenants without setting app.tenant_id'
SET ROLE platform_admin;
SELECT tenant_id, COUNT(*) AS orders, ROUND(SUM(amount),2) AS revenue
FROM orders GROUP BY tenant_id ORDER BY revenue DESC;
RESET ROLE;

\echo '-- 4.2  SECURITY DEFINER function: encapsulate tenant context safely'
CREATE OR REPLACE FUNCTION get_tenant_orders(p_tenant TEXT)
RETURNS TABLE (order_id INT, customer TEXT, amount NUMERIC(10,2), status TEXT)
SECURITY DEFINER
STABLE
LANGUAGE SQL AS $$
  SELECT order_id, customer, amount, status
  FROM orders
  WHERE tenant_id = p_tenant;
$$;

\echo '-- Any role can call this; the function owns the tenant context'
SELECT * FROM get_tenant_orders('acme');
SELECT * FROM get_tenant_orders('globex');


\echo ''
\echo '════════════════════════════════════════════════════════════════════'
\echo ' Part 5 — Partial index for RLS performance                          '
\echo '════════════════════════════════════════════════════════════════════'

\echo '-- 5.1  Without index: RLS predicate forces a full table scan'
SET app.tenant_id = 'acme';
EXPLAIN SELECT * FROM orders;
RESET app.tenant_id;

\echo '-- 5.2  Create covering index on tenant_id'
CREATE INDEX IF NOT EXISTS idx_orders_tenant
  ON orders (tenant_id)
  INCLUDE (customer, amount, status);

SET app.tenant_id = 'acme';
EXPLAIN SELECT * FROM orders;
RESET app.tenant_id;

\echo '-- Index Scan replaces Seq Scan — RLS at scale stays O(tenant_rows)'


\echo ''
\echo '════════════════════════════════════════════════════════════════════'
\echo ' Part 6 — Schema-per-tenant vs RLS: comparison                       '
\echo '════════════════════════════════════════════════════════════════════'

\echo '-- 6.1  Schema-per-tenant: complete isolation, harder to manage'
CREATE SCHEMA IF NOT EXISTS tenant_acme;
CREATE SCHEMA IF NOT EXISTS tenant_globex;

CREATE TABLE tenant_acme.orders  (LIKE orders INCLUDING ALL);
CREATE TABLE tenant_globex.orders (LIKE orders INCLUDING ALL);

INSERT INTO tenant_acme.orders  (tenant_id, customer, amount)
  SELECT tenant_id, customer, amount FROM orders WHERE tenant_id = 'acme';
INSERT INTO tenant_globex.orders (tenant_id, customer, amount)
  SELECT tenant_id, customer, amount FROM orders WHERE tenant_id = 'globex';

SELECT COUNT(*) AS acme_orders   FROM tenant_acme.orders;
SELECT COUNT(*) AS globex_orders FROM tenant_globex.orders;

\echo '-- 6.2  Comparison summary'
\echo '--'
\echo '--  RLS (shared table)              Schema-per-tenant'
\echo '--  ──────────────────────────────  ───────────────────────────────'
\echo '--  Simpler DDL (1 table)           Strong isolation (separate objects)'
\echo '--  Tenant added with INSERT        Tenant added with CREATE SCHEMA'
\echo '--  Index on tenant_id required     Each schema has its own indexes'
\echo '--  Risk: policy misconfiguration   Risk: schema sprawl at 1000+ tenants'
\echo '--  Best for: dynamic tenancy       Best for: large enterprise tenants'


\echo ''
\echo '════════════════════════════════════════════════════════════════════'
\echo ' Reference — inspect all RLS policies                                '
\echo '════════════════════════════════════════════════════════════════════'

SELECT schemaname, tablename, policyname, roles, cmd,
       qual      AS using_expr,
       with_check AS check_expr
FROM pg_policies
ORDER BY tablename, policyname;
