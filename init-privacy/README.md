# Data Privacy — Column Encryption & Anonymization

[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/srinivasa-vasu/ybdb-vanguard?devcontainer_path=.devcontainer%2Finit-privacy%2Fdevcontainer.json)

Column-level encryption with `pgcrypto`, hash-based pseudonymization, tamper-evident audit logs, and anonymized views for multi-schema data access — all in SQL, no application changes needed.

---

> **Run queries interactively**: Select any SQL block → **`Ctrl+Shift+Enter`** (Windows/Linux) or **`Cmd+Shift+Enter`** (Mac) → runs in the active terminal.

---

## Prerequisites

The devcontainer starts a **single-node cluster**. Run `CREATE EXTENSION pgcrypto` once per database (included in `privacy.sql`).

```bash
ysqlsh -h 127.0.0.1
```

---

## Running the demo

| Task | What it runs |
|---|---|
| **Terminal → Run Task → `privacy-demo`** | "The GDPR Audit" (`prompt.sh`) |

---

## Manual exercises

```sql
-- Load the full exercise
\i init-privacy/privacy.sql

-- Or enable pgcrypto manually
CREATE EXTENSION IF NOT EXISTS pgcrypto;
```

---

### Part 1 · Symmetric column encryption

```sql
-- Encrypt a column value
pgp_sym_encrypt('alice@example.com', 'my_encryption_key')  → BYTEA

-- Decrypt it back
pgp_sym_decrypt(encrypted_bytea, 'my_encryption_key')      → TEXT

-- Store: only the hash (for lookups) and ciphertext
CREATE TABLE patients_secure (
    id            SERIAL PRIMARY KEY,
    email_hash    TEXT  NOT NULL UNIQUE,   -- SHA-256, for lookups
    email_enc     BYTEA NOT NULL,          -- AES-encrypted via GnuPG
    diagnosis_enc BYTEA NOT NULL
);

INSERT INTO patients_secure (email_hash, email_enc, diagnosis_enc)
SELECT
    encode(digest(email, 'sha256'), 'hex'),
    pgp_sym_encrypt(email,      'enc_key'),
    pgp_sym_encrypt(diagnosis,  'enc_key')
FROM patients;

-- Authorized read
SELECT pgp_sym_decrypt(email_enc, 'enc_key') AS email FROM patients_secure;

-- Hash-based lookup (no decryption needed)
SELECT id FROM patients_secure
WHERE email_hash = encode(digest('alice@example.com', 'sha256'), 'hex');
```

---

### Part 2 · Hashing and HMAC

```sql
-- SHA-256 one-way hash (non-reversible)
encode(digest('alice@example.com', 'sha256'), 'hex')

-- SHA-512
encode(digest('alice@example.com', 'sha512'), 'hex')

-- HMAC: keyed hash — only the key holder can verify
encode(hmac('user_id:42|action:LOGIN', 'hmac_secret', 'sha256'), 'hex')

-- Tamper-evident audit log
INSERT INTO audit_log (action, patient_id, actor, signature)
VALUES (
    'VIEW_DIAGNOSIS', 1, 'dr.jones',
    hmac('VIEW_DIAGNOSIS|1|dr.jones', 'audit_hmac_key', 'sha256')
);

-- Verify integrity
SELECT
    log_id, action,
    CASE WHEN signature = hmac(action || '|' || patient_id || '|' || actor,
                                'audit_hmac_key', 'sha256')
         THEN 'VALID' ELSE 'TAMPERED' END AS integrity
FROM audit_log;
```

---

### Part 3 · Masking and anonymization patterns

```sql
-- Mask email: show only domain
SUBSTRING(email, 1, 2) || '***@' || SPLIT_PART(email, '@', 2)

-- Mask phone: show only last 4 digits
'***-' || RIGHT(phone, 4)

-- Generalize date to year
SUBSTRING(dob::text, 1, 4)   -- '1985'

-- Bucket a categorical value
CASE
    WHEN diagnosis IN ('Hypertension','Type 2 Diabetes') THEN 'Chronic'
    ELSE 'Other'
END

-- Pseudonymize (deterministic: same input → same output, not reversible)
encode(digest(email || 'pseudo_salt', 'sha256'), 'hex')
```

---

### Part 4 · Anonymized views for multi-schema access

```sql
-- Analytics schema: anonymized view with zero PII
CREATE SCHEMA analytics;

CREATE VIEW analytics.patients AS
SELECT
    id,
    encode(digest(email_hash || 'salt', 'sha256'), 'hex') AS anon_id,
    '***@anon.invalid'                                     AS email,
    SUBSTRING(pgp_sym_decrypt(dob_enc, 'enc_key'), 1, 4)  AS birth_year,
    CASE WHEN pgp_sym_decrypt(diagnosis_enc, 'enc_key')
              IN ('Hypertension','Type 2 Diabetes') THEN 'Chronic'
         ELSE 'Other' END                                  AS diagnosis_bucket,
    created_at::date                                       AS record_date
FROM public.patients_secure;

-- Grant analytics team access to the view only
GRANT USAGE ON SCHEMA analytics TO analytics_role;
GRANT SELECT ON analytics.patients TO analytics_role;
-- analytics_role has no access to public.patients_secure
```

---

### Part 5 · Column-level key rotation

```sql
-- Add a version column to track which key encrypted each row
ALTER TABLE patients_secure ADD COLUMN key_version INT NOT NULL DEFAULT 1;

-- Re-encrypt with the new key (decrypt old → encrypt new)
UPDATE patients_secure SET
    email_enc     = pgp_sym_encrypt(pgp_sym_decrypt(email_enc,     'old_key'), 'new_key'),
    diagnosis_enc = pgp_sym_encrypt(pgp_sym_decrypt(diagnosis_enc, 'old_key'), 'new_key'),
    key_version   = 2
WHERE key_version = 1;
```

---

### Part 6 · Password hashing with bcrypt

```sql
-- Hash a password
SELECT crypt('user_password', gen_salt('bf', 12)) AS bcrypt_hash;

-- Verify a password
SELECT crypt('user_password', stored_hash) = stored_hash AS is_valid
FROM users WHERE username = 'alice';
```

---

## pgcrypto function reference

| Function | Returns | Use case |
|---|---|---|
| `pgp_sym_encrypt(text, key)` | `BYTEA` | Encrypt a column value (AES/GnuPG) |
| `pgp_sym_decrypt(bytea, key)` | `TEXT` | Decrypt back to plaintext |
| `digest(data, algo)` | `BYTEA` | One-way hash (sha256, sha512, md5) |
| `hmac(data, key, algo)` | `BYTEA` | Keyed hash for tamper detection |
| `encode(bytea, format)` | `TEXT` | Convert bytes to hex / base64 |
| `gen_random_bytes(n)` | `BYTEA` | Cryptographic random bytes |
| `gen_random_uuid()` | `UUID` | Random UUID v4 |
| `crypt(password, salt)` | `TEXT` | bcrypt password hashing |
| `gen_salt('bf', rounds)` | `TEXT` | Generate bcrypt salt |

---

## Key mental models

```
Encrypt vs Hash vs Mask
  pgp_sym_encrypt  → reversible with the key (store sensitive data)
  digest / hmac    → non-reversible (search tokens, audit integrity)
  masking patterns → query-time transformation (analytics, display)

Column encryption design
  Searchable field → store hash (for WHERE) + ciphertext (for display)
  Non-searchable   → store ciphertext only
  Never decrypt    → store hash only (passwords, irreversible IDs)

Multi-schema access control
  public.patients_secure   → encrypted columns; clinical staff only
  analytics.patients       → anonymized view; analytics team access
  GRANT on VIEW, not table → analytics team never touches ciphertext

Key rotation
  Add key_version column → know which key encrypted each row
  Batch UPDATE            → decrypt old, encrypt new, bump version
  No downtime required    → can run during normal operation
```
