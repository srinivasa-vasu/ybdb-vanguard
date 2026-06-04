#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# YugabyteDB Data Privacy demo  —  "The GDPR Audit"
#
# Scenario: A healthcare SaaS company undergoes a GDPR/HIPAA audit. The auditor
# asks: "How do you protect PII at the column level? How do you anonymize data
# for analytics and testing?" The DBA demonstrates pgcrypto column encryption,
# hash-based pseudonymization, and multi-schema anonymized views — all in SQL,
# no application changes needed.
# ─────────────────────────────────────────────────────────────────────────────

. pscript

TYPE_SPEED=35
NO_WAIT=false
DEMO_PROMPT="${GREEN}➜ ${CYAN}\W ${COLOR_RESET}"

clear

# ── Scene 1: Setup ────────────────────────────────────────────────────────────

p "=== 'The GDPR Audit' — Data Privacy Demo ==="
p ""
p "Step 1: Enable the pgcrypto extension."

pe "ysqlsh -h 127.0.0.1 -c \"CREATE EXTENSION IF NOT EXISTS pgcrypto;\""

p "Now create a patient records table with plaintext PII — the 'before' state."

pe "ysqlsh -h 127.0.0.1 -c \"
CREATE TABLE IF NOT EXISTS patients (
  id        SERIAL PRIMARY KEY,
  full_name TEXT   NOT NULL,
  email     TEXT   NOT NULL,
  phone     TEXT,
  dob       DATE,
  diagnosis TEXT   NOT NULL
);\""

pe "ysqlsh -h 127.0.0.1 -c \"
INSERT INTO patients (full_name, email, phone, dob, diagnosis) VALUES
  ('Alice Johnson', 'alice@example.com', '555-0101', '1985-03-14', 'Hypertension'),
  ('Bob Williams',  'bob@example.com',   '555-0102', '1972-07-22', 'Type 2 Diabetes'),
  ('Carol Smith',   'carol@example.com', '555-0103', '1990-11-05', 'Asthma');\""

pe "ysqlsh -h 127.0.0.1 -c \"SELECT * FROM patients;\""

p "PII stored in plaintext — the auditor raises an immediate flag."

# ── Scene 2: Column encryption with pgcrypto ──────────────────────────────────

p ""
p "--- Part 1: Symmetric column encryption with pgcrypto ---"
p "Store only encrypted bytes in the sensitive columns."

pe "ysqlsh -h 127.0.0.1 -c \"
CREATE TABLE IF NOT EXISTS patients_secure (
  id             SERIAL PRIMARY KEY,
  email_hash     TEXT   NOT NULL,           -- for lookups (one-way)
  email_enc      BYTEA  NOT NULL,           -- for decryption when needed
  phone_enc      BYTEA,
  dob_enc        BYTEA,
  diagnosis_enc  BYTEA  NOT NULL,
  created_at     TIMESTAMPTZ DEFAULT now()
);\""

pe "ysqlsh -h 127.0.0.1 -c \"
INSERT INTO patients_secure
  (email_hash, email_enc, phone_enc, dob_enc, diagnosis_enc)
SELECT
  encode(digest(email, 'sha256'), 'hex'),
  pgp_sym_encrypt(email,     'encryption_key_v1'),
  pgp_sym_encrypt(phone,     'encryption_key_v1'),
  pgp_sym_encrypt(dob::text, 'encryption_key_v1'),
  pgp_sym_encrypt(diagnosis, 'encryption_key_v1')
FROM patients;\""

pe "ysqlsh -h 127.0.0.1 -c \"SELECT id, email_hash, encode(email_enc,'hex') AS email_enc_hex FROM patients_secure;\""

p "Only the SHA-256 hash and ciphertext are stored. Plaintext never touches disk."

# ── Scene 3: Decrypt when authorized ─────────────────────────────────────────

p ""
p "--- Part 2: Authorized decryption for clinical staff ---"

pe "ysqlsh -h 127.0.0.1 -c \"
SELECT
  id,
  pgp_sym_decrypt(email_enc,     'encryption_key_v1') AS email,
  pgp_sym_decrypt(phone_enc,     'encryption_key_v1') AS phone,
  pgp_sym_decrypt(dob_enc,       'encryption_key_v1') AS dob,
  pgp_sym_decrypt(diagnosis_enc, 'encryption_key_v1') AS diagnosis
FROM patients_secure;\""

p "Decryption requires the key. Wrong key returns an error, not garbage data."

# ── Scene 4: Hash-based lookup ────────────────────────────────────────────────

p ""
p "--- Part 3: Find a patient by email using the hash (no decryption needed) ---"

pe "ysqlsh -h 127.0.0.1 -c \"
SELECT id, email_hash
FROM patients_secure
WHERE email_hash = encode(digest('alice@example.com', 'sha256'), 'hex');\""

p "Hash-based lookup: search without exposing the email or needing the key."

# ── Scene 5: Anonymization patterns ──────────────────────────────────────────

p ""
p "--- Part 4: Anonymization for analytics and test environments ---"
p "Techniques: masking, pseudonymization, generalization — all in SQL."

pe "ysqlsh -h 127.0.0.1 -c \"
SELECT
  id,
  -- Pseudonymize: deterministic hash (same input → same output, not reversible)
  encode(digest(email_hash || 'salt_v1', 'sha256'), 'hex') AS pseudo_id,
  -- Mask phone: show only last 4 digits
  '***-' || RIGHT(pgp_sym_decrypt(phone_enc, 'encryption_key_v1'), 4) AS masked_phone,
  -- Generalize DOB to birth year only
  SUBSTRING(pgp_sym_decrypt(dob_enc, 'encryption_key_v1'), 1, 4) AS birth_year,
  -- Diagnosis bucketed to broad category
  CASE
    WHEN pgp_sym_decrypt(diagnosis_enc,'encryption_key_v1') IN ('Hypertension','Type 2 Diabetes')
         THEN 'Chronic Condition'
    ELSE 'Other'
  END AS diagnosis_category
FROM patients_secure;\""

# ── Scene 6: Anonymized view for the analytics schema ────────────────────────

p ""
p "--- Part 5: Anonymized view — safe for the analytics team ---"

pe "ysqlsh -h 127.0.0.1 -c \"
CREATE OR REPLACE VIEW patients_analytics AS
SELECT
  id,
  encode(digest(email_hash || 'analytics_salt', 'sha256'), 'hex') AS anon_id,
  '***-****' AS phone,
  SUBSTRING(pgp_sym_decrypt(dob_enc, 'encryption_key_v1'), 1, 4) AS birth_year,
  CASE
    WHEN pgp_sym_decrypt(diagnosis_enc,'encryption_key_v1')
           IN ('Hypertension','Type 2 Diabetes') THEN 'Chronic'
    ELSE 'Other'
  END AS diagnosis_bucket,
  created_at::date AS record_date
FROM patients_secure;\""

pe "ysqlsh -h 127.0.0.1 -c \"SELECT * FROM patients_analytics;\""

p "The analytics team queries this view. They never see email, phone, or exact DOB."

# ── Scene 7: HMAC for tamper-evident audit log ────────────────────────────────

p ""
p "--- Part 6: HMAC for a tamper-evident audit trail ---"

pe "ysqlsh -h 127.0.0.1 -c \"
CREATE TABLE IF NOT EXISTS audit_log (
  log_id    SERIAL PRIMARY KEY,
  action    TEXT NOT NULL,
  patient_id INT,
  actor     TEXT NOT NULL,
  logged_at TIMESTAMPTZ DEFAULT now(),
  signature BYTEA NOT NULL   -- HMAC prevents log tampering
);

INSERT INTO audit_log (action, patient_id, actor, signature)
VALUES (
  'VIEW_DIAGNOSIS',
  1,
  'dr.jones',
  hmac('VIEW_DIAGNOSIS|1|dr.jones', 'audit_hmac_key', 'sha256')
);\""

pe "ysqlsh -h 127.0.0.1 -c \"
SELECT
  log_id, action, patient_id, actor, logged_at,
  CASE WHEN signature = hmac(action || '|' || patient_id::text || '|' || actor,
                              'audit_hmac_key', 'sha256')
       THEN 'VALID' ELSE 'TAMPERED' END AS integrity
FROM audit_log;\""

p "The HMAC signature verifies the log entry has not been altered since insertion."

p ""
p "=== Privacy Summary ==="
p "  pgp_sym_encrypt / decrypt  → symmetric column encryption (AES via GnuPG)"
p "  digest(val, 'sha256')       → one-way hash for lookups and pseudonymization"
p "  hmac(val, key, 'sha256')    → keyed hash for tamper-evident audit logs"
p "  Masking patterns            → SUBSTRING, RIGHT, OVERLAY, CASE bucketing"
p "  Anonymized VIEW             → safe layer for analytics; no schema changes"
p ""
p "Key principle: PII stays encrypted. Analytics uses anonymized views."
p "  encrypt    → pgp_sym_encrypt  (reversible, key required)"
p "  hash       → digest / hmac    (non-reversible, for search / audit)"
p "  anonymize  → CREATE VIEW      (query-time transformation, no storage cost)"

cmd
p ""
