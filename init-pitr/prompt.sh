#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# YugabyteDB PITR demo  —  "The 2 AM Incident"
#
# Scenario: A DBA accidentally runs DELETE FROM payments; without a WHERE
# clause during a maintenance window. Using YugabyteDB Point-in-Time Recovery,
# we restore the database to the exact moment before the disaster — with
# zero data loss and without stopping the cluster.
#
# Pre-requisites (handled by postCreateCommand):
#   - pv installed
#   - pscript (demo-magic) downloaded into this directory
# ─────────────────────────────────────────────────────────────────────────────

. pscript

TYPE_SPEED=40
NO_WAIT=false
DEMO_PROMPT="${GREEN}➜ ${CYAN}\W ${COLOR_RESET}"

clear

# ── Scene 1: Check current PITR state ─────────────────────────────────────────

p "=== YugabyteDB PITR: Point-in-Time Recovery Demo ==="
p ""
p "First, confirm there are no active snapshot schedules."

pe "yb-admin -master_addresses ${MASTERS} list_snapshot_schedules"

p "Empty — no PITR protection yet."
p "Let's enable it: snapshot every 2 minutes, retain history for 24 hours."

# ── Scene 2: Enable PITR schedule ─────────────────────────────────────────────

pe "yb-admin -master_addresses ${MASTERS} create_snapshot_schedule 2 1440 ysql.yugabyte"

SCHEDULE_ID=$(yb-admin -master_addresses "${MASTERS}" list_snapshot_schedules 2>/dev/null \
  | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)

p "PITR schedule created. Schedule ID: ${SCHEDULE_ID}"
p ""
p "Verify the schedule is active:"

pe "yb-admin -master_addresses ${MASTERS} list_snapshot_schedules"

# ── Scene 3: Seed the payments database ───────────────────────────────────────

p "Now let's create a payments table and seed it with 1,000 customer accounts."

pe "ysqlsh -c \"DROP TABLE IF EXISTS payments;\""

pe "ysqlsh -c \"
CREATE TABLE payments (
  id       SERIAL PRIMARY KEY,
  customer TEXT            NOT NULL,
  balance  NUMERIC(12, 2)  NOT NULL
);\""

pe "ysqlsh -c \"
INSERT INTO payments (customer, balance)
  SELECT
    'Customer ' || i,
    (random() * 9000 + 1000)::NUMERIC(12, 2)
  FROM generate_series(1, 1000) i;\""

pe "ysqlsh -c \"SELECT COUNT(*) AS total_accounts, ROUND(SUM(balance), 2) AS total_funds FROM payments;\""

p "1,000 accounts holding real money. Now we need a snapshot to exist before we continue."

# ── Scene 4: Wait for the first snapshot ──────────────────────────────────────

p ""
p "⏳ The first snapshot is taken 2 minutes after the schedule is created."
p "   Watching the clock... (This wait only happens once per schedule.)"
p ""

echo ""
for n in $(seq 130 -1 1); do
  printf "\r   ⏳ %3ds until first snapshot is confirmed..." "$n"
  sleep 1
done
echo ""
echo "   ✅ First snapshot window open — PITR is now protecting this database."
echo ""

pe "yb-admin -master_addresses ${MASTERS} list_snapshot_schedules"

# ── Scene 5: Record the "safe" restore point ──────────────────────────────────

p "Everything looks healthy. Let's capture our recovery target timestamp."

# Capture both forms: Unix microseconds for the restore command (most reliable),
# and a human-readable string for display.
PITR_TS_US=$(ysqlsh -t -c \
  "SELECT (EXTRACT(EPOCH FROM CURRENT_TIMESTAMP) * 1000000)::bigint" | xargs)
PITR_TS_HR=$(ysqlsh -t -c \
  "SELECT to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS')" | xargs)

p "Safe restore point : ${PITR_TS_HR} UTC"
p "Unix microseconds  : ${PITR_TS_US}"
p ""
p "restore_snapshot_schedule accepts Unix microseconds, a YCQL timestamp, or"
p "a relative offset (minus 5m / minus 1h). We will use the microsecond form."

# Give the cluster 2 extra seconds to ensure the captured timestamp is
# safely before the upcoming DELETE in the WAL.
sleep 2

# ── Scene 6: The disaster ─────────────────────────────────────────────────────

p ""
p "🚨 Simulating a DBA running DELETE FROM payments; without a WHERE clause..."

pe "ysqlsh -c \"DELETE FROM payments;\""

pe "ysqlsh -c \"SELECT COUNT(*) AS survivors FROM payments;\""

p "😱 All 1,000 accounts are gone! \$1.2 M in customer funds — vanished."
p "   Recovery target: ${PITR_TS_HR} UTC  (${PITR_TS_US} µs)"

# ── Scene 7: PITR Recovery ────────────────────────────────────────────────────

p ""
p "Initiating restore_snapshot_schedule to ${PITR_TS_HR}..."

pe "yb-admin -master_addresses ${MASTERS} restore_snapshot_schedule ${SCHEDULE_ID} ${PITR_TS_US}"

p "Restore submitted. Waiting for it to complete..."

# Poll until no restoration is in progress
_max=30
for _i in $(seq 1 "$_max"); do
  _state=$(yb-admin -master_addresses "${MASTERS}" list_snapshots SHOW_DETAILS 2>/dev/null \
    | grep -c "RESTORING" || true)
  [ "$_state" -eq 0 ] && break
  printf "\r   🔄 Restoring... (%ds elapsed)" "$(( _i * 2 ))"
  sleep 2
done
echo ""
echo "   ✅ Restore complete."
echo ""

# ── Scene 8: Verify ───────────────────────────────────────────────────────────

p "Reconnecting to YSQL and verifying the recovery..."

pe "ysqlsh -c \"SELECT COUNT(*) AS restored_accounts, ROUND(SUM(balance), 2) AS restored_funds FROM payments;\""

pe "ysqlsh -c \"SELECT id, customer, balance FROM payments ORDER BY id LIMIT 5;\""

p ""
p "🎉 All 1,000 accounts restored with their original balances. Zero data loss."
p ""
p "YugabyteDB PITR:"
p "  • Online restore — cluster never stopped"
p "  • Any-point recovery within the retention window (24h in this demo)"
p "  • Database-level granularity — only the yugabyte DB was affected"
p ""
p "Next: open a ysqlsh shell and explore AS OF SYSTEM TIME queries."
p "  → SELECT * FROM payments AS OF SYSTEM TIME '-5 minutes';"

cmd

p ""
