# Encryption at Rest (EAR)

[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/srinivasa-vasu/ybdb-vanguard?devcontainer_path=.devcontainer%2Finit-ear%2Fdevcontainer.json)

Enable, verify, and rotate encryption keys on a live YugabyteDB cluster — no restart required at any step.

---

## How YugabyteDB EAR works

- Encryption is applied at the **tablet storage layer** (below YSQL and YCQL)
- Keys are loaded into **master memory only** — never written to disk inside the cluster
- New writes are encrypted immediately after activation
- Existing data is re-encrypted during background **tablet compaction** (no downtime)
- Rotation: load the new key → activate it — the cluster re-encrypts during next compaction

---

## Prerequisites

The devcontainer starts a **single-node cluster** and installs `openssl`. All exercises use `yb-admin` commands (no SQL changes needed).

```bash
ysqlsh      # YSQL shell
```

---

## Running the demo

| Task | What it runs |
|---|---|
| **Terminal → Run Task → `ear-demo`** | "The Compliance Mandate" (`prompt.sh`) |

The demo walks through: check initial state → generate key → load into masters → verify → activate → insert data → key rotation → verify again.

---

## Manual exercises

### Part 1 · Check initial encryption status

```bash
yb-admin --master_addresses 127.0.0.1:7100 is_encryption_enabled
# Expected: Encryption status: DISABLED
```

---

### Part 2 · Generate key files

Key sizes: 32 bytes (AES-256), 40 bytes, or 48 bytes.

```bash
mkdir -p init-ear/keys

# Key version 1
openssl rand -out init-ear/keys/universe_key_v1 32

# Verify it was created
ls -lh init-ear/keys/
```

---

### Part 3 · Load key into all masters

```bash
yb-admin --master_addresses 127.0.0.1:7100 \
  add_universe_key_to_all_masters key_v1 init-ear/keys/universe_key_v1
```

Verify every master node has it in memory:

```bash
yb-admin --master_addresses 127.0.0.1:7100 \
  all_masters_have_universe_key_in_memory key_v1
# Expected: All masters have key in memory: 1
```

---

### Part 4 · Activate encryption

```bash
yb-admin --master_addresses 127.0.0.1:7100 \
  rotate_universe_key_in_memory key_v1
```

Confirm:

```bash
yb-admin --master_addresses 127.0.0.1:7100 is_encryption_enabled
# Expected: Encryption status: ENABLED with key id key_v1
```

All new writes are now encrypted. Existing data is re-encrypted during compaction.

---

### Part 5 · Key rotation

Generate a new key, load it, and rotate to it. The old key must be kept until
compaction has re-encrypted all tablets.

```bash
# Generate new key
openssl rand -out init-ear/keys/universe_key_v2 32

# Load into masters
yb-admin --master_addresses 127.0.0.1:7100 \
  add_universe_key_to_all_masters key_v2 init-ear/keys/universe_key_v2

# Verify all masters have it
yb-admin --master_addresses 127.0.0.1:7100 \
  all_masters_have_universe_key_in_memory key_v2

# Rotate to new key (encryption stays active, new key takes over)
yb-admin --master_addresses 127.0.0.1:7100 \
  rotate_universe_key_in_memory key_v2

# Confirm
yb-admin --master_addresses 127.0.0.1:7100 is_encryption_enabled
# Expected: Encryption status: ENABLED with key id key_v2
```

---

### Part 6 · Disable encryption (optional)

```bash
yb-admin --master_addresses 127.0.0.1:7100 disable_encryption

yb-admin --master_addresses 127.0.0.1:7100 is_encryption_enabled
# Expected: Encryption status: DISABLED
```

Existing encrypted data is decrypted during background compaction.

---

### Part 7 · Multi-key rotation sequence (production pattern)

In production, keep a rotation log:

```
key_v1  →  active from 2025-01-01  →  decommissioned after compaction 2025-04-01
key_v2  →  active from 2025-04-01  →  decommissioned after compaction 2025-07-01
key_v3  →  active from 2025-07-01  →  current
```

Before removing an old key file, confirm all tablets have been compacted with the new key. For a production cluster, trigger a manual compaction:

```bash
yb-admin --master_addresses 127.0.0.1:7100 compact_table ysql.yugabyte sensitive_records
```

---

## Key mental models

```
EAR is below the SQL layer
  Transparent to apps  → no query changes, no schema changes
  All APIs work        → YSQL, YCQL, CDC, backups all continue normally

Key lifecycle
  Generate   → openssl rand -out <path> 32
  Load       → add_universe_key_to_all_masters <id> <path>  (in memory only)
  Activate   → rotate_universe_key_in_memory <id>  (also used for rotation)
  Verify     → is_encryption_enabled
  Disable    → disable_encryption

Key storage rules
  • Never store keys inside the cluster or on the same disk as data
  • Use a secrets manager (AWS KMS, HashiCorp Vault, GCP KMS) in production
  • Retain old keys until compaction re-encrypts all tablets with the new key
  • For snapshot/backup restoration, copy all keys used during that period

Compaction and re-encryption
  • New data encrypted immediately
  • Old data re-encrypted lazily during background compaction
  • No read downtime; old key still valid until compaction completes
```

---

## Useful commands

```bash
# Check current encryption status and active key ID
yb-admin --master_addresses 127.0.0.1:7100 is_encryption_enabled

# Generate a key (32 / 40 / 48 bytes)
openssl rand -out <path> 32

# Load key into master memory
yb-admin --master_addresses 127.0.0.1:7100 \
  add_universe_key_to_all_masters <key_id> <key_file_path>

# Verify all masters have the key
yb-admin --master_addresses 127.0.0.1:7100 \
  all_masters_have_universe_key_in_memory <key_id>

# Activate or rotate encryption
yb-admin --master_addresses 127.0.0.1:7100 \
  rotate_universe_key_in_memory <key_id>

# Disable encryption
yb-admin --master_addresses 127.0.0.1:7100 disable_encryption

# Trigger manual compaction on a table
yb-admin --master_addresses 127.0.0.1:7100 \
  compact_table ysql.<db_name> <table_name>
```
