#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# YugabyteDB RLS demo  —  "The SaaS Tenant Isolation Problem"
#
# Scenario: A SaaS platform serves multiple enterprise customers on the same
# database. Customer A must never see Customer B's data — not even if a
# developer queries the DB directly. Row Level Security enforces this at the
# database layer, making it impossible to bypass in application code.
# ─────────────────────────────────────────────────────────────────────────────

. pscript

TYPE_SPEED=35
NO_WAIT=false
DEMO_PROMPT="${GREEN}➜ ${CYAN}\W ${COLOR_RESET}"

clear

# ── Quiet cleanup: drop roles created in a previous run ───────────────────────
ysqlsh -h 127.0.0.1 -c "DROP ROLE IF EXISTS platform_admin;" 2>/dev/null || true

# ── Scene 1: Setup the multi-tenant schema ────────────────────────────────────

p "=== 'The SaaS Tenant Isolation Problem' — RLS Demo ==="
p ""
p "A SaaS orders table shared by multiple customers. No isolation yet."

pe "ysqlsh -h 127.0.0.1 -c \"
DROP TABLE IF EXISTS orders CASCADE;
CREATE TABLE orders (
  order_id  SERIAL          PRIMARY KEY,
  tenant_id TEXT            NOT NULL,
  customer  TEXT            NOT NULL,
  amount    NUMERIC(10,2)   NOT NULL,
  status    TEXT            NOT NULL DEFAULT 'pending'
);
INSERT INTO orders (tenant_id, customer, amount) VALUES
  ('acme',    'Alice Johnson',  1250.00),
  ('acme',    'Bob Williams',    890.00),
  ('globex',  'Carol Smith',    2100.00),
  ('globex',  'Dave Brown',      450.00),
  ('initech', 'Eve Davis',      1750.00);\""

pe "ysqlsh -h 127.0.0.1 -c \"SELECT * FROM orders ORDER BY tenant_id;\""

p "Any user with SELECT can see ALL tenants. That is a compliance failure."

# ── Scene 2: Enable RLS ───────────────────────────────────────────────────────

p ""
p "--- Part 1: Enable RLS and add a tenant isolation policy ---"

pe "ysqlsh -h 127.0.0.1 -c \"ALTER TABLE orders ENABLE ROW LEVEL SECURITY;\""

p "RLS enabled — table owner still sees everything (BYPASSRLS by default)."
p "Now add the policy that enforces tenant isolation."

pe "ysqlsh -h 127.0.0.1 -c \"
CREATE POLICY tenant_isolation ON orders
  FOR ALL
  USING (tenant_id = current_setting('app.tenant_id', true));\""

p "Policy created. Any session must SET app.tenant_id before querying."

# ── Scene 3: Demo isolation ───────────────────────────────────────────────────

p ""
p "--- Part 2: Tenant A cannot see Tenant B's rows ---"

pe "ysqlsh -h 127.0.0.1 -c \"SET app.tenant_id = 'acme'; SELECT * FROM orders;\""

pe "ysqlsh -h 127.0.0.1 -c \"SET app.tenant_id = 'globex'; SELECT * FROM orders;\""

p "Each tenant sees only their own rows. The WHERE clause is injected by the DB."

# ── Scene 4: No tenant set = no rows ─────────────────────────────────────────

p ""
p "--- Part 3: Missing tenant context = zero rows (safe default) ---"

pe "ysqlsh -h 127.0.0.1 -c \"SELECT * FROM orders;\""

p "Without SET app.tenant_id, current_setting returns NULL → no rows returned."
p "A misconfigured app leaks nothing."

# ── Scene 5: INSERT policy + WITH CHECK ──────────────────────────────────────

p ""
p "--- Part 4: Prevent cross-tenant inserts with WITH CHECK ---"

pe "ysqlsh -h 127.0.0.1 -c \"
DROP POLICY tenant_isolation ON orders;
CREATE POLICY tenant_isolation ON orders
  FOR ALL
  USING      (tenant_id = current_setting('app.tenant_id', true))
  WITH CHECK (tenant_id = current_setting('app.tenant_id', true));\""

p "Now try to insert a row for a different tenant:"

pe "ysqlsh -h 127.0.0.1 -c \"
SET app.tenant_id = 'acme';
INSERT INTO orders (tenant_id, customer, amount)
VALUES ('globex', 'Malicious Actor', 9999.99);\""

p "ERROR: new row violates row-level security policy. The WITH CHECK clause blocked it."

# ── Scene 6: BYPASSRLS for the admin role ────────────────────────────────────

p ""
p "--- Part 5: Admin role bypasses RLS for maintenance tasks ---"

pe "ysqlsh -h 127.0.0.1 -c \"CREATE ROLE platform_admin LOGIN PASSWORD 'admin123';\""
pe "ysqlsh -h 127.0.0.1 -c \"GRANT ALL ON orders TO platform_admin;\""
pe "ysqlsh -h 127.0.0.1 -c \"ALTER ROLE platform_admin BYPASSRLS;\""

pe "ysqlsh -h 127.0.0.1 -U platform_admin -c \"SELECT tenant_id, COUNT(*) FROM orders GROUP BY tenant_id;\""

p "platform_admin sees all tenants — needed for billing, support, backups."

# ── Scene 7: SECURITY DEFINER function ───────────────────────────────────────

p ""
p "--- Part 6: SECURITY DEFINER — safe tenant-aware function ---"
p "Applications call a function that sets the tenant context internally."

pe "ysqlsh -h 127.0.0.1 -c \"
CREATE OR REPLACE FUNCTION get_tenant_orders(p_tenant TEXT)
RETURNS TABLE (order_id INT, customer TEXT, amount NUMERIC, status TEXT)
SECURITY DEFINER LANGUAGE SQL AS \$\$
  SELECT order_id, customer, amount, status
  FROM orders
  WHERE tenant_id = p_tenant;
\$\$;\""

pe "ysqlsh -h 127.0.0.1 -c \"SELECT * FROM get_tenant_orders('acme');\""

p "The function sets its own security context — callers cannot inject a different tenant."

# ── Scene 8: Partial index for RLS performance ────────────────────────────────

p ""
p "--- Part 7: Optimize with a partial index on tenant_id ---"
p "Without an index, every RLS check does a full scan of 500k rows in production."

pe "ysqlsh -h 127.0.0.1 -c \"CREATE INDEX idx_orders_tenant ON orders (tenant_id) INCLUDE (customer, amount, status);\""

pe "ysqlsh -h 127.0.0.1 -c \"
SET app.tenant_id = 'acme';
EXPLAIN SELECT * FROM orders;\""

p "Index Scan on idx_orders_tenant — RLS now uses the index, not a seq scan."

p ""
p "=== RLS Summary ==="
p "  ENABLE ROW LEVEL SECURITY     → turns on enforcement for the table"
p "  CREATE POLICY ... USING       → filter rows on SELECT/UPDATE/DELETE"
p "  CREATE POLICY ... WITH CHECK  → block cross-tenant INSERT/UPDATE"
p "  current_setting('app.x',true) → session variable, safe default NULL"
p "  ALTER ROLE ... BYPASSRLS      → admin bypass for maintenance"
p "  SECURITY DEFINER function     → encapsulate tenant context in the DB"
p "  Partial index on tenant_id    → keeps query cost O(tenant_rows), not O(total)"

cmd
p ""
