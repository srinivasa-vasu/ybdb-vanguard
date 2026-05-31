#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# YugabyteDB DB Clone demo  —  "The Safe Migration Runway"
#
# Scenario: The team wants to test a risky schema migration — adding a
# customer tier column and reclassifying 1,000 accounts — without ever
# touching the production database. Using CREATE DATABASE ... TEMPLATE,
# they create instant copies: one at current state for migration testing
# and one point-in-time clone as a rollback baseline. Production is never
# touched.
#
# Syntax:
#   CREATE DATABASE clone_db TEMPLATE source_db;                  -- current state
#   CREATE DATABASE clone_db TEMPLATE source_db AS OF '<ts>';     -- past timestamp
#   SELECT * FROM yb_database_clones();                           -- monitor status
#
# Requires: enable_db_clone=true master flag (set via MASTER_FLAGS in devcontainer)
#           + an active PITR schedule on the source database (for AS OF clones)
# ─────────────────────────────────────────────────────────────────────────────

. pscript

TYPE_SPEED=40
NO_WAIT=false
DEMO_PROMPT="${GREEN}➜ ${CYAN}\W ${COLOR_RESET}"

clear

# ── Quiet setup: ensure prerequisites are in place ────────────────────────────

# Drop any leftover clone databases from a previous run
ysqlsh -c "DROP DATABASE IF EXISTS payments_dev;"       2>/dev/null || true
ysqlsh -c "DROP DATABASE IF EXISTS payments_baseline;"  2>/dev/null || true

# Ensure payments table exists with 1,000 rows
_count=$(ysqlsh -t -c "SELECT COUNT(*) FROM payments;" 2>/dev/null | xargs)
if [ -z "$_count" ] || [ "$_count" -lt 100 ]; then
  ysqlsh -c "
    DROP TABLE IF EXISTS payments;
    CREATE TABLE payments (
      id       SERIAL          PRIMARY KEY,
      customer TEXT            NOT NULL,
      balance  NUMERIC(12, 2)  NOT NULL
    );
    INSERT INTO payments (customer, balance)
      SELECT 'Customer ' || i, (random() * 9000 + 1000)::NUMERIC(12, 2)
      FROM generate_series(1, 1000) i;
  " 2>/dev/null
fi

# Ensure a PITR schedule exists on yugabyte (required for point-in-time clones)
SCHEDULE_ID=$(yb-admin -master_addresses "${MASTERS}" list_snapshot_schedules 2>/dev/null \
  | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)

if [ -z "$SCHEDULE_ID" ]; then
  echo "No PITR schedule found — creating one and waiting for the first snapshot (~70s)..."
  yb-admin -master_addresses "${MASTERS}" create_snapshot_schedule 2 1440 ysql.yugabyte >/dev/null 2>&1
  for n in $(seq 130 -1 1); do printf "\r   ⏳ %3ds remaining..." "$n"; sleep 1; done
  echo ""
  echo "   ✅ Schedule ready."
fi

# ── Scene 1: Show production state ────────────────────────────────────────────

p "=== YugabyteDB DB Clone: Safe Migration Runway ==="
p ""
p "Current production database — 1,000 customer accounts:"

pe "ysqlsh -c \"SELECT COUNT(*) AS accounts, ROUND(SUM(balance), 2) AS total_funds, ROUND(AVG(balance), 2) AS avg_balance FROM payments;\""

pe "ysqlsh -c \"SELECT id, customer, balance FROM payments ORDER BY balance DESC LIMIT 5;\""

# ── Scene 2: Record baseline and apply production changes ──────────────────────

p "Recording the pre-upgrade baseline timestamp (with microsecond precision)..."

BASELINE_TS=$(ysqlsh -t -c \
  "SELECT to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS.US')" | xargs)

p "Baseline: ${BASELINE_TS} UTC"

sleep 3

p ""
p "Production upgrade: high-value accounts enrolled in the Premier program."

pe "ysqlsh -c \"UPDATE payments SET customer = customer || ' (Premier)' WHERE balance > 8000;\""

pe "ysqlsh -c \"INSERT INTO payments (customer, balance) SELECT 'Corp Account ' || i, (random() * 50000 + 20000)::NUMERIC(12,2) FROM generate_series(1, 20) i;\""

pe "ysqlsh -c \"SELECT COUNT(*) AS total_accounts, ROUND(SUM(balance), 2) AS total_funds FROM payments;\""

p "Production: 1,020 accounts after Premier upgrades and new corporate accounts."

# ── Scene 3: Clone current production state (pure SQL) ────────────────────────

p ""
p "The team needs to test a tier-classification migration."
p "Clone production to a new database with a single SQL statement:"

pe "ysqlsh -c \"CREATE DATABASE payments_dev TEMPLATE yugabyte;\""

p "Clone created. Checking status..."

pe "ysqlsh -c \"SELECT source_db_name, target_db_name, state, clone_time FROM yb_database_clones();\""

p "Connecting to the clone..."

pe "ysqlsh -d payments_dev -c \"SELECT COUNT(*) AS accounts, ROUND(SUM(balance), 2) AS total_funds FROM payments;\""

p "Identical copy — same 1,020 accounts, same balances. Now test the migration."

# ── Scene 4: Apply migration to clone only ────────────────────────────────────

p ""
p "Applying the tier migration to the CLONE only:"

pe "ysqlsh -d payments_dev -c \"ALTER TABLE payments ADD COLUMN tier TEXT;\""

pe "ysqlsh -d payments_dev -c \"UPDATE payments SET tier = CASE WHEN balance >= 20000 THEN 'corporate' WHEN balance >= 8000 THEN 'premier' ELSE 'standard' END;\""

pe "ysqlsh -d payments_dev -c \"SELECT tier, COUNT(*) AS accounts, ROUND(AVG(balance), 2) AS avg_balance FROM payments GROUP BY tier ORDER BY avg_balance DESC;\""

p "Migration successful on the clone. Confirming production is untouched..."

# ── Scene 5: Verify production isolation ──────────────────────────────────────

pe "ysqlsh -c \"\d payments\""

p "Production schema unchanged — no tier column. The clone is fully isolated."

# ── Scene 6: Clone to the pre-upgrade baseline ────────────────────────────────

p ""
p "Need a rollback target? Clone to before the Premier upgrade — same SQL, add AS OF:"

pe "ysqlsh -c \"CREATE DATABASE payments_baseline TEMPLATE yugabyte AS OF '${BASELINE_TS}';\""

pe "ysqlsh -c \"SELECT source_db_name, target_db_name, state, clone_time FROM yb_database_clones();\""

pe "ysqlsh -d payments_baseline -c \"SELECT COUNT(*) AS accounts, ROUND(SUM(balance), 2) AS total_funds FROM payments;\""

pe "ysqlsh -d payments_baseline -c \"SELECT COUNT(*) AS premier_count FROM payments WHERE customer LIKE '%Premier%';\""

p "Baseline clone: 1,000 accounts, no Premier upgrades, no corporate accounts."
p "That is the production state at ${BASELINE_TS} UTC, exactly preserved."

# ── Scene 7: Three-way comparison ─────────────────────────────────────────────

p ""
p "Three independent databases from the same cluster:"

pe "ysqlsh -c \"
SELECT 'yugabyte (production)' AS database, COUNT(*) AS accounts FROM yugabyte.public.payments
UNION ALL
SELECT 'payments_dev',                      COUNT(*) FROM payments_dev.public.payments
UNION ALL
SELECT 'payments_baseline',                 COUNT(*) FROM payments_baseline.public.payments;\""

p ""
p "✅ DB Clone in YugabyteDB:"
p "  • SQL syntax: CREATE DATABASE clone TEMPLATE source [AS OF '<timestamp>']"
p "  • Instant copy — no dump/restore, no extra storage for unchanged blocks"
p "  • Requires a PITR schedule on the source for point-in-time (AS OF) clones"
p "  • Fully isolated — changes to the clone never affect production"
p "  • Monitor with: SELECT * FROM yb_database_clones();"

cmd

p ""
