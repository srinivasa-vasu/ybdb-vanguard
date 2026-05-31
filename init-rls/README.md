# Row Level Security & Multi-tenancy

[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/srinivasa-vasu/ybdb-vanguard?devcontainer_path=.devcontainer%2Finit-rls%2Fdevcontainer.json)

Database-enforced tenant isolation on YugabyteDB. No application changes, no middleware — policies live in the database and cannot be bypassed by application code.

---

> **Run queries interactively**: Select any SQL block → **`Ctrl+Shift+Enter`** (Windows/Linux) or **`Cmd+Shift+Enter`** (Mac) → runs in the active terminal.

---

## Prerequisites

The devcontainer starts a **single-node cluster**. RLS is enforced at the YSQL layer — node count has no effect on policy behaviour. All exercises use `\i init-rls/rls.sql` or interactive ysqlsh.

```bash
ysqlsh
```

---

## Running the demo

| Task | What it runs |
|---|---|
| **Terminal → Run Task → `rls-demo`** | "The SaaS Tenant Isolation Problem" (`prompt.sh`) |

---

## Manual exercises

### Part 1 · Basic RLS syntax

```sql
-- Enable RLS on a table
ALTER TABLE employees ENABLE ROW LEVEL SECURITY;

-- Policy: each user sees only their own row
CREATE POLICY emp_self_policy ON employees
  FOR ALL TO PUBLIC
  USING (ename = current_user);

-- Test as a specific role
SET ROLE alice;
SELECT * FROM employees;   -- returns only alice's row
RESET ROLE;

-- Drop a policy
DROP POLICY emp_self_policy ON employees;

-- Disable RLS
ALTER TABLE employees DISABLE ROW LEVEL SECURITY;
```

---

### Part 2 · Multi-tenant isolation with a session variable

The pattern most SaaS applications use — a single shared table, rows filtered by a session variable the application sets on connection.

```sql
ALTER TABLE orders ENABLE ROW LEVEL SECURITY;

-- Policy uses current_setting() with a safe default (true = return NULL not error)
CREATE POLICY tenant_isolation ON orders
  FOR ALL
  USING      (tenant_id = current_setting('app.tenant_id', true))
  WITH CHECK (tenant_id = current_setting('app.tenant_id', true));
```

**Application sets context on every connection:**

```sql
SET app.tenant_id = 'acme';
SELECT * FROM orders;   -- only acme rows

SET app.tenant_id = 'globex';
SELECT * FROM orders;   -- only globex rows

RESET app.tenant_id;
SELECT * FROM orders;   -- zero rows (safe default)
```

**Cross-tenant insert is blocked:**

```sql
SET app.tenant_id = 'acme';
INSERT INTO orders (tenant_id, customer, amount)
VALUES ('globex', 'Attacker', 9999.99);
-- ERROR: new row violates row-level security policy
```

---

### Part 3 · Separate policies per DML operation

```sql
CREATE POLICY tenant_read   ON orders FOR SELECT USING (tenant_id = current_setting('app.tenant_id', true));
CREATE POLICY tenant_write  ON orders FOR INSERT WITH CHECK (tenant_id = current_setting('app.tenant_id', true));
CREATE POLICY tenant_modify ON orders FOR UPDATE
  USING (tenant_id = current_setting('app.tenant_id', true))
  WITH CHECK (tenant_id = current_setting('app.tenant_id', true));
CREATE POLICY tenant_delete ON orders FOR DELETE USING (tenant_id = current_setting('app.tenant_id', true));
```

---

### Part 4 · BYPASSRLS for platform admin

```sql
CREATE ROLE platform_admin LOGIN;
GRANT ALL ON orders TO platform_admin;
ALTER ROLE platform_admin BYPASSRLS;

-- platform_admin sees all rows without setting app.tenant_id
SET ROLE platform_admin;
SELECT tenant_id, COUNT(*) FROM orders GROUP BY tenant_id;
RESET ROLE;
```

Superusers and table owners have `BYPASSRLS` by default.

---

### Part 5 · SECURITY DEFINER function

Encapsulates the tenant context inside the database. Callers cannot substitute a different tenant ID.

```sql
CREATE OR REPLACE FUNCTION get_tenant_orders(p_tenant TEXT)
RETURNS TABLE (order_id INT, customer TEXT, amount NUMERIC, status TEXT)
SECURITY DEFINER STABLE LANGUAGE SQL AS $$
  SELECT order_id, customer, amount, status
  FROM orders
  WHERE tenant_id = p_tenant;
$$;

SELECT * FROM get_tenant_orders('acme');
```

---

### Part 6 · Partial index for RLS performance

Without an index, every query with a tenant filter scans the whole table.

```sql
CREATE INDEX idx_orders_tenant
  ON orders (tenant_id)
  INCLUDE (customer, amount, status);

SET app.tenant_id = 'acme';
EXPLAIN SELECT * FROM orders;
-- → Index Scan on idx_orders_tenant   (not Seq Scan)
```

The index reduces per-tenant query cost from O(all_rows) to O(tenant_rows).

---

### Part 7 · Inspect all active policies

```sql
SELECT schemaname, tablename, policyname, roles, cmd,
       qual      AS using_expr,
       with_check AS check_expr
FROM pg_policies
ORDER BY tablename, policyname;
```

---

### Part 8 · Schema-per-tenant (alternative pattern)

```sql
CREATE SCHEMA tenant_acme;
CREATE SCHEMA tenant_globex;

CREATE TABLE tenant_acme.orders  (LIKE orders INCLUDING ALL);
CREATE TABLE tenant_globex.orders (LIKE orders INCLUDING ALL);
```

| | RLS (shared table) | Schema-per-tenant |
|---|---|---|
| DDL overhead | One table | One schema + tables per tenant |
| Adding a tenant | `INSERT` | `CREATE SCHEMA` |
| Isolation strength | Policy-level | Object-level |
| Cross-tenant queries | Via BYPASSRLS function | Via `SET search_path` |
| Best for | Many small tenants | Large enterprise tenants |

---

## Key mental models

```
CREATE POLICY name ON table
  FOR { ALL | SELECT | INSERT | UPDATE | DELETE }
  TO { role | PUBLIC }
  USING      (filter expression)   -- applied to SELECT, UPDATE, DELETE
  WITH CHECK (filter expression)   -- applied to INSERT, UPDATE (new row)

current_setting('app.tenant_id', true)
  → returns NULL if not set (safe default — no rows visible)
  → SET app.tenant_id = 'acme' scopes the current session

BYPASSRLS
  → table owners and superusers bypass by default
  → ALTER ROLE name BYPASSRLS / NOBYPASSRLS to control explicitly

SECURITY DEFINER function
  → runs with the definer's privileges, not the caller's
  → prevents callers from injecting tenant context

Partial index on tenant_id
  → makes RLS O(tenant_rows) not O(total_rows) at scale
```
