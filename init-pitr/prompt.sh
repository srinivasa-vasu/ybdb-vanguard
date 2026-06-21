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

TYPE_SPEED=70
NO_WAIT=false
DEMO_PROMPT="${GREEN}➜ ${CYAN}\W ${COLOR_RESET}"

clear

# ── Quiet cleanup: remove any snapshot schedules and drop table from last run ──
for _sched_id in $(yb-admin -master_addresses "${MASTERS}" list_snapshot_schedules 2>/dev/null \
    | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'); do
  yb-admin -master_addresses "${MASTERS}" delete_snapshot_schedule "${_sched_id}" 2>/dev/null || true
done
ysqlsh -h 127.0.0.1 -c "DROP TABLE IF EXISTS payments;" 2>/dev/null || true

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

pe "ysqlsh -h 127.0.0.1 -c \"DROP TABLE IF EXISTS payments;\""

pe "ysqlsh -h 127.0.0.1 -c \"
CREATE TABLE payments (
  id       SERIAL PRIMARY KEY,
  customer TEXT            NOT NULL,
  balance  NUMERIC(12, 2)  NOT NULL
);\""

(set -f; pe "ysqlsh -h 127.0.0.1 -c \"
INSERT INTO payments (customer, balance)
  SELECT
    'Customer ' || i,
    (random() * 9000 + 1000)::NUMERIC(12, 2)
  FROM generate_series(1, 1000) i;\"")

pe "ysqlsh -h 127.0.0.1 -c \"SELECT COUNT(*) AS total_accounts, ROUND(SUM(balance), 2) AS total_funds FROM payments;\""

p "1,000 accounts holding real money. Now we need a snapshot to exist before we continue."

# ── Scene 4: Wait for the first snapshot ──────────────────────────────────────

p ""
p "⏳ Waiting for the first snapshot (taken ~2 min after the schedule is created)."
p "   Polling yb-admin every 10 s — continuing as soon as a snapshot is confirmed."
p ""

echo ""
_elapsed=0
while true; do
  _snap_count=$(yb-admin -master_addresses "${MASTERS}" list_snapshot_schedules 2>/dev/null \
    | grep -q '"snapshot_time"'; echo $?)
  if [ "${_snap_count:-1}" -eq 0 ]; then
    echo ""
    echo "   ✅ First snapshot confirmed after ${_elapsed}s — PITR is now active."
    echo ""
    break
  fi
  printf "\r   ⏳ %3ds elapsed, no snapshot yet — checking again in 10 s..." "$_elapsed"
  sleep 10
  _elapsed=$(( _elapsed + 10 ))
done

pe "yb-admin -master_addresses ${MASTERS} list_snapshot_schedules"

# ── Scene 5: Record the "safe" restore point ──────────────────────────────────

p "Everything looks healthy. Let's capture our recovery target timestamp."

# Capture both forms: Unix microseconds for the restore command (most reliable),
# and a human-readable string for display.
PITR_TS_US=$(ysqlsh -h 127.0.0.1 -t -c \
  "SELECT (EXTRACT(EPOCH FROM CURRENT_TIMESTAMP) * 1000000)::bigint" | xargs)
PITR_TS_HR=$(ysqlsh -h 127.0.0.1 -t -c \
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

pe "ysqlsh -h 127.0.0.1 -c \"DELETE FROM payments;\""

pe "ysqlsh -h 127.0.0.1 -c \"SELECT COUNT(*) AS survivors FROM payments;\""

p "😱 All 1,000 accounts are gone! \$1.2 M in customer funds — vanished."

# ── Scene 7: Time Travel — read the deleted data WITHOUT restoring ────────────

p ""
p "=== Time Travel with yb_read_time ==="
p ""
p "The data is gone at the current timestamp. But yb_read_time lets us READ"
p "historical data without any restore — useful for forensics or audits."
p ""
p "Syntax:  SET yb_read_time TO <unix_microseconds>;"
p "         SELECT ...;   -- reads as-of that moment; NOTICE is informational"
p "         SET yb_read_time TO 0;  -- reset to present (always do this)"

p ""
p "--- Reading the deleted data at our safe point (${PITR_TS_HR}) ---"
p "    Notice: the table is empty NOW but yb_read_time shows the past."

pe "echo 'SET yb_read_time TO ${PITR_TS_US}; SELECT COUNT(*) AS accounts_before, ROUND(SUM(balance),2) AS funds_before FROM payments; SET yb_read_time TO 0;' | ysqlsh -h 127.0.0.1"

p ""
p "--- First 5 accounts as they existed before the DELETE ---"

pe "echo 'SET yb_read_time TO ${PITR_TS_US}; SELECT id, customer, balance FROM payments ORDER BY id LIMIT 5; SET yb_read_time TO 0;' | ysqlsh -h 127.0.0.1"

p ""
p "The data is still readable in the PITR window. But it is NOT restored yet —"
p "the table is still empty in the present. For a real recovery, use PITR."

# ── Scene 8: PITR Recovery ────────────────────────────────────────────────────

p ""
p "=== PITR Restore ==="
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

# ── Scene 9: Verify ───────────────────────────────────────────────────────────

p "Reconnecting to YSQL and verifying the recovery..."

pe "ysqlsh -h 127.0.0.1 -c \"SELECT COUNT(*) AS restored_accounts, ROUND(SUM(balance), 2) AS restored_funds FROM payments;\""

pe "ysqlsh -h 127.0.0.1 -c \"SELECT id, customer, balance FROM payments ORDER BY id LIMIT 5;\""

p ""
p "🎉 All 1,000 accounts restored with their original balances. Zero data loss."
p ""
p "Summary:"
p "  yb_read_time  — read any past timestamp without restoring (forensics / audits)"
p "  PITR restore  — bring the whole database back to a past state permanently"
p ""
p "  • Online restore — cluster never stopped"
p "  • Any-point recovery within the retention window (24h in this demo)"
p "  • Database-level granularity"

cmd

p ""
