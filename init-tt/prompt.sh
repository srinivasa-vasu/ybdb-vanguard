#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# YugabyteDB Time Travel demo  —  "The Compliance Audit"
#
# Scenario: The compliance team flags unusual account activity. Balances on
# dozens of accounts dropped by ~90 % and 15 high-value accounts disappeared
# entirely — all in the last few minutes. Using SET yb_read_time, the DBA
# runs a forensic audit against the live database without restoring anything.
# The database is never changed; only the session read timestamp moves backward.
#
# Syntax:
#   SET yb_read_time TO <unix_timestamp_microseconds>;   -- travel to the past
#   SET yb_read_time TO 0;                               -- return to now
#
# No PITR snapshot schedule required. Retention window: 900 s (15 min) default.
# ─────────────────────────────────────────────────────────────────────────────

. pscript

TYPE_SPEED=40
NO_WAIT=false
DEMO_PROMPT="${GREEN}➜ ${CYAN}\W ${COLOR_RESET}"

clear

# ── Quiet setup: ensure payments table exists with 1,000 rows ─────────────────

_count=$(ysqlsh -h 127.0.0.1 -t -c "SELECT COUNT(*) FROM payments;" 2>/dev/null | xargs)
if [ -z "$_count" ] || [ "$_count" -lt 100 ]; then
  echo "Setting up payments table..."
  ysqlsh -h 127.0.0.1 -c "
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

# ── Scene 1: Show current healthy state ───────────────────────────────────────

p "=== YugabyteDB Time Travel: The Compliance Audit ==="
p ""
p "Current database state — all accounts healthy:"

pe "ysqlsh -h 127.0.0.1 -c \"SELECT COUNT(*) AS total_accounts, ROUND(SUM(balance), 2) AS total_funds, ROUND(AVG(balance), 2) AS avg_balance FROM payments;\""

# ── Scene 2: Capture the audit timestamp ──────────────────────────────────────

p ""
p "Opening the audit window — recording the 'before' timestamp."
p "YugabyteDB time travel uses Unix microseconds as the read timestamp."

# Capture both forms: microseconds for SET yb_read_time, human-readable for display
READ_TS_US=$(ysqlsh -h 127.0.0.1 -t -c \
  "SELECT (EXTRACT(EPOCH FROM CURRENT_TIMESTAMP) * 1000000)::bigint" | xargs)
READ_TS_HR=$(ysqlsh -h 127.0.0.1 -t -c \
  "SELECT to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS')" | xargs)

p "Audit timestamp : ${READ_TS_HR} UTC"
p "HybridTime (µs) : ${READ_TS_US}"
p ""
p "SET yb_read_time TO ${READ_TS_US}  will return any query to this moment."

# Ensure a clear gap in the WAL between the captured timestamp and the upcoming changes
sleep 3

# ── Scene 3: Simulate suspicious activity ─────────────────────────────────────

p ""
p "🚨 Suspicious activity — two events in the audit log:"
p "   1. 50 accounts: balances reduced to 10 % of original"
p "   2. 15 high-value accounts (id <= 100, balance > 9500): deleted"

(set -f; pe "ysqlsh -h 127.0.0.1 -c \"UPDATE payments SET balance = balance * 0.10 WHERE id % 20 = 0;\"")

pe "ysqlsh -h 127.0.0.1 -c \"DELETE FROM payments WHERE balance > 9500 AND id <= 100;\""

pe "ysqlsh -h 127.0.0.1 -c \"SELECT COUNT(*) AS remaining_accounts, ROUND(SUM(balance), 2) AS remaining_funds FROM payments;\""

p "Accounts are down. Investigation starting — no restore required."

# ── Scene 4: Time travel — overall state before the incident ──────────────────

p ""
p "--- Query 1: How many accounts existed at the audit timestamp? ---"
p "SET yb_read_time TO ${READ_TS_US}  (travels to ${READ_TS_HR})"

pe "echo 'SET yb_read_time TO ${READ_TS_US}; SELECT COUNT(*) AS accounts_before, ROUND(SUM(balance), 2) AS funds_before FROM payments; SET yb_read_time TO 0;' | ysqlsh -h 127.0.0.1"

p "1,000 accounts, full funds — exactly as they were at the audit timestamp."

# ── Scene 5: Time travel — inspect the drained accounts ───────────────────────

p ""
p "--- Query 2: What were the balances of the drained accounts before the incident? ---"

pe "echo 'SET yb_read_time TO ${READ_TS_US}; SELECT id, customer, balance AS balance_before FROM payments WHERE id % 20 = 0 ORDER BY id LIMIT 10; SET yb_read_time TO 0;' | ysqlsh -h 127.0.0.1"

p "Those same accounts now:"

pe "ysqlsh -h 127.0.0.1 -c \"SELECT id, customer, balance AS balance_after FROM payments WHERE id % 20 = 0 ORDER BY id LIMIT 10;\""

p "Original balances (thousands) → reduced to hundreds. Each read used its own read time."

# ── Scene 6: Time travel — recover deleted account details ────────────────────

p ""
p "--- Query 3: Which accounts were deleted? Read them from the past. ---"

pe "echo 'SET yb_read_time TO ${READ_TS_US}; SELECT id, customer, balance AS last_known_balance FROM payments WHERE balance > 9500 AND id <= 100 ORDER BY balance DESC; SET yb_read_time TO 0;' | ysqlsh -h 127.0.0.1"

p "Those rows in the CURRENT database:"

pe "ysqlsh -h 127.0.0.1 -c \"SELECT COUNT(*) AS count_now FROM payments WHERE balance > 9500 AND id <= 100;\""

p "The time travel read found them; the live query confirmed they are gone."

# ── Scene 7: Cleanup and summary ──────────────────────────────────────────────

p ""
p "--- Summary ---"
p "Audit timestamp  : ${READ_TS_HR} UTC  (${READ_TS_US} µs)"
p "Accounts before  : 1,000   |   Accounts now: $(ysqlsh -h 127.0.0.1 -t -c "SELECT COUNT(*) FROM payments;" | xargs)"
p ""
p "The database was NEVER MODIFIED during this investigation."
p "SET yb_read_time is session-scoped and read-only — writes are rejected"
p "when a past read time is active."
p ""
p "Flashback window: 900 s default (timestamp_history_retention_interval_sec)."
p "For longer lookback → use PITR restore or DB Clone (init-pitr / init-clone)."

cmd

p ""
