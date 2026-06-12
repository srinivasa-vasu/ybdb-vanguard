#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# YugabyteDB EAR demo  —  "The Compliance Mandate"
#
# Scenario: A security audit requires all data at rest to be encrypted, and
# encryption keys to be rotated quarterly. Using YugabyteDB's built-in EAR,
# a DBA enables encryption on a live cluster, verifies it, inserts data, and
# performs a key rotation — all without downtime.
#
# EAR workflow:
#   1. openssl rand  →  generate key file
#   2. yb-admin add_universe_key_to_all_masters   →  load key into memory
#   3. yb-admin all_masters_have_universe_key_in_memory  →  verify
#   4. yb-admin rotate_universe_key_in_memory    →  activate encryption
#   5. yb-admin is_encryption_enabled            →  confirm
#   (repeat 1-4 with a new key for rotation)
# ─────────────────────────────────────────────────────────────────────────────

. pscript
set -f  # disable filename expansion — prevents SELECT * glob-expanding in eval $@

TYPE_SPEED=35
NO_WAIT=false
DEMO_PROMPT="${GREEN}➜ ${CYAN}\W ${COLOR_RESET}"

KEY_DIR="${PWD}/keys"
mkdir -p "$KEY_DIR"

clear

# ── Quiet cleanup: drop table from a previous run ─────────────────────────────
ysqlsh -h 127.0.0.1 -c "DROP TABLE IF EXISTS sensitive_records CASCADE;" 2>/dev/null || true

# ── Scene 1: Verify encryption is NOT yet active ──────────────────────────────

p "=== 'The Compliance Mandate' — Encryption at Rest Demo ==="
p ""
p "Step 1: Confirm the cluster is currently unencrypted."

pe "yb-admin --master_addresses ${MASTERS} is_encryption_enabled"

p "DISABLED — all data on disk is plaintext. The audit team wants this fixed."

# ── Scene 2: Create some test data before enabling EAR ───────────────────────

p ""
p "Step 2: Create a sensitive table with some data."

pe "ysqlsh -h 127.0.0.1 -c \"
CREATE TABLE IF NOT EXISTS sensitive_records (
  id      SERIAL PRIMARY KEY,
  name    TEXT NOT NULL,
  secret  TEXT NOT NULL
);
INSERT INTO sensitive_records (name, secret) VALUES
  ('Alice', 'project_aurora_credentials'),
  ('Bob',   'database_root_password'),
  ('Carol', 'api_signing_key');\""

pe "ysqlsh -h 127.0.0.1 -c \"SELECT * FROM sensitive_records;\""

# ── Scene 3: Generate the first key ──────────────────────────────────────────

p ""
p "Step 3: Generate a 32-byte AES key using openssl."

pe "openssl rand -out ${KEY_DIR}/universe_key_v1 32"
pe "ls -lh ${KEY_DIR}/"

p "Key stored at ${KEY_DIR}/universe_key_v1 — never persisted inside the DB."

# ── Scene 4: Load key into all masters ───────────────────────────────────────

p ""
p "Step 4: Load the key into master memory. No restart required."

pe "yb-admin --master_addresses ${MASTERS} add_universe_key_to_all_masters key_v1 ${KEY_DIR}/universe_key_v1"

pe "yb-admin --master_addresses ${MASTERS} all_masters_have_universe_key_in_memory key_v1"

# ── Scene 5: Activate encryption ─────────────────────────────────────────────

p ""
p "Step 5: Activate encryption — this is also the 'rotate' command."
p "New writes are encrypted immediately. Old data is re-encrypted during compaction."

pe "yb-admin --master_addresses ${MASTERS} rotate_universe_key_in_memory key_v1"

pe "yb-admin --master_addresses ${MASTERS} is_encryption_enabled"

p "ENABLED with key_v1. All new data is now encrypted at rest."

# ── Scene 6: Data still accessible through YSQL ──────────────────────────────

p ""
p "Step 6: Data remains fully readable through YSQL — encryption is transparent."

pe "ysqlsh -h 127.0.0.1 -c \"SELECT * FROM sensitive_records;\""

pe "ysqlsh -h 127.0.0.1 -c \"INSERT INTO sensitive_records (name, secret) VALUES ('Dave', 'oauth_private_key');
              SELECT COUNT(*) AS total_records FROM sensitive_records;\""

p "Reads and writes work exactly as before. Encryption is below the SQL layer."

# ── Scene 7: Key rotation ─────────────────────────────────────────────────────

p ""
p "=== Quarterly Key Rotation ==="
p "Three months later — the security policy requires a new key."
p ""
p "Step 7: Generate key v2."

pe "openssl rand -out ${KEY_DIR}/universe_key_v2 32"

pe "yb-admin --master_addresses ${MASTERS} add_universe_key_to_all_masters key_v2 ${KEY_DIR}/universe_key_v2"

pe "yb-admin --master_addresses ${MASTERS} all_masters_have_universe_key_in_memory key_v2"

pe "yb-admin --master_addresses ${MASTERS} rotate_universe_key_in_memory key_v2"

pe "yb-admin --master_addresses ${MASTERS} is_encryption_enabled"

p "ENABLED with key_v2. Old data will be re-encrypted with the new key during compaction."
p "Both keys must be retained until compaction completes."

# ── Scene 8: Verify data survives rotation ────────────────────────────────────

p ""
p "Step 8: Data is still fully accessible after rotation."

pe "ysqlsh -h 127.0.0.1 -c \"SELECT * FROM sensitive_records ORDER BY id;\""

p ""
p "=== EAR Summary ==="
p "  openssl rand            → generate key files (32 / 40 / 48 bytes)"
p "  add_universe_key        → load key into master memory (no restart)"
p "  rotate_universe_key     → activate / rotate encryption"
p "  is_encryption_enabled   → confirm status and active key ID"
p ""
p "Key rules:"
p "  • Only new writes are encrypted immediately after activation"
p "  • Old data is re-encrypted during background tablet compaction"
p "  • Keep old keys until all tablets have been compacted"
p "  • Key files are never stored inside the DB; store them in a secrets manager"

cmd
p ""
