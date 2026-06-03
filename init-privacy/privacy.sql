-- ═════════════════════════════════════════════════════════════════════════════
-- privacy.sql  —  Data Privacy: Column Encryption & Anonymization
-- Load: \i init-privacy/privacy.sql   (or paste blocks interactively)
-- ═════════════════════════════════════════════════════════════════════════════

CREATE EXTENSION IF NOT EXISTS pgcrypto;

\echo ''
\echo '════════════════════════════════════════════════════════════════════'
\echo ' Part 1 — pgcrypto: symmetric column encryption                      '
\echo '════════════════════════════════════════════════════════════════════'

-- ── 1.1  Setup: plaintext table ──────────────────────────────────────────────
\echo '-- 1.1  Plaintext patient table (the "before" state)'
DROP TABLE IF EXISTS patients CASCADE;
CREATE TABLE patients (
    id        SERIAL PRIMARY KEY,
    full_name TEXT   NOT NULL,
    email     TEXT   NOT NULL,
    phone     TEXT,
    dob       DATE,
    diagnosis TEXT   NOT NULL
);

INSERT INTO patients (full_name, email, phone, dob, diagnosis) VALUES
  ('Alice Johnson', 'alice@example.com', '555-0101', '1985-03-14', 'Hypertension'),
  ('Bob Williams',  'bob@example.com',   '555-0102', '1972-07-22', 'Type 2 Diabetes'),
  ('Carol Smith',   'carol@example.com', '555-0103', '1990-11-05', 'Asthma');

SELECT * FROM patients;

-- ── 1.2  Encrypted table ─────────────────────────────────────────────────────
\echo '-- 1.2  Create encrypted patient table'
DROP TABLE IF EXISTS patients_secure CASCADE;
CREATE TABLE patients_secure (
    id            SERIAL PRIMARY KEY,
    -- SHA-256 hash of email for fast lookups without decryption
    email_hash    TEXT   NOT NULL UNIQUE,
    -- pgp_sym_encrypt: AES symmetric encryption via GnuPG
    email_enc     BYTEA  NOT NULL,
    phone_enc     BYTEA,
    dob_enc       BYTEA,
    diagnosis_enc BYTEA  NOT NULL,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Use a static demo key (production: SET app.enc_key from a secrets manager)
SET app.enc_key = 'demo_encryption_key_v1';

\echo '-- 1.3  Encrypt PII on insert'
INSERT INTO patients_secure (email_hash, email_enc, phone_enc, dob_enc, diagnosis_enc)
SELECT
    encode(digest(email, 'sha256'), 'hex'),
    pgp_sym_encrypt(email,          current_setting('app.enc_key', true)),
    pgp_sym_encrypt(phone,          current_setting('app.enc_key', true)),
    pgp_sym_encrypt(dob::text,      current_setting('app.enc_key', true)),
    pgp_sym_encrypt(diagnosis,      current_setting('app.enc_key', true))
FROM patients
ON CONFLICT (email_hash) DO NOTHING;

\echo '-- Stored data: only hash and ciphertext'
SELECT id, email_hash, encode(email_enc, 'hex') AS email_enc_hex FROM patients_secure;

-- ── 1.4  Authorized decryption ────────────────────────────────────────────────
\echo '-- 1.4  Decrypt for authorized access'
SELECT
    id,
    pgp_sym_decrypt(email_enc,     'demo_encryption_key_v1') AS email,
    pgp_sym_decrypt(phone_enc,     'demo_encryption_key_v1') AS phone,
    pgp_sym_decrypt(dob_enc,       'demo_encryption_key_v1') AS dob,
    pgp_sym_decrypt(diagnosis_enc, 'demo_encryption_key_v1') AS diagnosis
FROM patients_secure;

-- ── 1.5  Hash-based lookup ────────────────────────────────────────────────────
\echo '-- 1.5  Find patient by email using hash (no decryption required)'
SELECT id, email_hash
FROM patients_secure
WHERE email_hash = encode(digest('alice@example.com', 'sha256'), 'hex');


\echo ''
\echo '════════════════════════════════════════════════════════════════════'
\echo ' Part 2 — Hashing, HMAC, and random token generation                 '
\echo '════════════════════════════════════════════════════════════════════'

-- ── 2.1  SHA-2 hashes ─────────────────────────────────────────────────────────
\echo '-- 2.1  digest(): one-way hash (non-reversible)'
SELECT
    encode(digest('alice@example.com', 'sha256'), 'hex') AS sha256,
    encode(digest('alice@example.com', 'sha512'), 'hex') AS sha512,
    encode(digest('alice@example.com', 'md5'),    'hex') AS md5;

-- ── 2.2  HMAC: keyed hash for tamper detection ────────────────────────────────
\echo '-- 2.2  hmac(): keyed hash (only the key holder can verify)'
SELECT encode(hmac('user_id:42|action:LOGIN|ts:1748800000', 'hmac_secret_key', 'sha256'), 'hex') AS hmac_sig;

-- ── 2.3  Tamper-evident audit log ─────────────────────────────────────────────
\echo '-- 2.3  Audit log with HMAC integrity verification'
DROP TABLE IF EXISTS audit_log;
CREATE TABLE audit_log (
    log_id     SERIAL PRIMARY KEY,
    action     TEXT        NOT NULL,
    patient_id INT,
    actor      TEXT        NOT NULL,
    logged_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    signature  BYTEA       NOT NULL
);

INSERT INTO audit_log (action, patient_id, actor, signature)
SELECT
    action, patient_id, actor,
    hmac(action || '|' || patient_id::text || '|' || actor, 'audit_hmac_key', 'sha256')
FROM (VALUES
    ('VIEW_DIAGNOSIS',   1, 'dr.jones'),
    ('UPDATE_DIAGNOSIS', 2, 'dr.smith'),
    ('EXPORT_RECORDS',   NULL, 'admin')
) AS t(action, patient_id, actor);

\echo '-- Verify integrity: VALID or TAMPERED'
SELECT
    log_id, action, patient_id, actor, logged_at,
    CASE WHEN signature = hmac(
                action || '|' || COALESCE(patient_id::text,'NULL') || '|' || actor,
                'audit_hmac_key', 'sha256')
         THEN 'VALID' ELSE 'TAMPERED' END AS integrity
FROM audit_log;

-- ── 2.4  Secure random tokens ─────────────────────────────────────────────────
\echo '-- 2.4  gen_random_bytes(): secure tokens, salts, nonces'
SELECT
    encode(gen_random_bytes(16), 'hex')    AS session_token_32hex,
    encode(gen_random_bytes(32), 'base64') AS api_key_base64,
    gen_random_uuid()                       AS uuid_v4;


\echo ''
\echo '════════════════════════════════════════════════════════════════════'
\echo ' Part 3 — Data masking and anonymization patterns                    '
\echo '════════════════════════════════════════════════════════════════════'

-- ── 3.1  In-query masking ─────────────────────────────────────────────────────
\echo '-- 3.1  Masking patterns: partial reveal, bucketing, pseudonymization'
SELECT
    id,
    -- Email: keep domain, mask local part
    SUBSTRING(pgp_sym_decrypt(email_enc,'demo_encryption_key_v1'), 1, 2)
      || '***@'
      || SPLIT_PART(pgp_sym_decrypt(email_enc,'demo_encryption_key_v1'), '@', 2)
      AS masked_email,
    -- Phone: show last 4 digits only
    '***-' || RIGHT(pgp_sym_decrypt(phone_enc,'demo_encryption_key_v1'), 4)
      AS masked_phone,
    -- DOB: generalize to birth year
    SUBSTRING(pgp_sym_decrypt(dob_enc,'demo_encryption_key_v1'), 1, 4)
      AS birth_year,
    -- Diagnosis: bucket to broad category
    CASE
        WHEN pgp_sym_decrypt(diagnosis_enc,'demo_encryption_key_v1')
               IN ('Hypertension','Type 2 Diabetes') THEN 'Chronic Condition'
        WHEN pgp_sym_decrypt(diagnosis_enc,'demo_encryption_key_v1')
               IN ('Asthma','COPD')                  THEN 'Respiratory'
        ELSE 'Other'
    END AS diagnosis_bucket
FROM patients_secure;

-- ── 3.2  Pseudonymization ─────────────────────────────────────────────────────
\echo '-- 3.2  Pseudonymization: deterministic, irreversible, consistent'
SELECT
    id,
    -- Same input always → same pseudo_id; not reversible without the salt
    encode(digest(email_hash || 'pseudo_salt_v1', 'sha256'), 'hex') AS pseudo_id,
    birth_year,
    diagnosis_bucket
FROM (
    SELECT
        id,
        email_hash,
        SUBSTRING(pgp_sym_decrypt(dob_enc,'demo_encryption_key_v1'), 1, 4) AS birth_year,
        CASE WHEN pgp_sym_decrypt(diagnosis_enc,'demo_encryption_key_v1')
                    IN ('Hypertension','Type 2 Diabetes') THEN 'Chronic' ELSE 'Other' END
          AS diagnosis_bucket
    FROM patients_secure
) sub;

-- ── 3.3  Anonymized views ─────────────────────────────────────────────────────
\echo '-- 3.3  Create anonymized view for analytics team'
CREATE OR REPLACE VIEW patients_analytics AS
SELECT
    id,
    encode(digest(email_hash || 'analytics_salt', 'sha256'), 'hex') AS anon_id,
    '***@anon.invalid'                                               AS email,
    '***-****'                                                       AS phone,
    SUBSTRING(pgp_sym_decrypt(dob_enc,'demo_encryption_key_v1'), 1, 4)
                                                                     AS birth_year,
    CASE
        WHEN pgp_sym_decrypt(diagnosis_enc,'demo_encryption_key_v1')
               IN ('Hypertension','Type 2 Diabetes') THEN 'Chronic'
        ELSE 'Other'
    END                                                              AS diagnosis_bucket,
    created_at::date                                                 AS record_date
FROM patients_secure;

\echo '-- Analytics team queries this view — no PII exposure'
SELECT * FROM patients_analytics;

-- ── 3.4  Multi-schema: prod vs anonymized ────────────────────────────────────
\echo '-- 3.4  Multi-schema: production + anonymized schema side by side'
CREATE SCHEMA IF NOT EXISTS analytics;

CREATE OR REPLACE VIEW analytics.patients AS
SELECT * FROM patients_analytics;

\echo '-- Production schema: encrypted columns'
SELECT id, email_hash FROM public.patients_secure LIMIT 3;

\echo '-- Analytics schema: anonymized view, zero PII'
SELECT * FROM analytics.patients LIMIT 3;


\echo ''
\echo '════════════════════════════════════════════════════════════════════'
\echo ' Part 4 — Key rotation for column encryption                         '
\echo '════════════════════════════════════════════════════════════════════'

\echo '-- 4.1  Re-encrypt with a new key (key rotation for column-level encryption)'
\echo '--'
\echo '-- Step 1: add a key_version column to track which key encrypted each row'
ALTER TABLE patients_secure ADD COLUMN IF NOT EXISTS key_version INT NOT NULL DEFAULT 1;

\echo '-- Step 2: re-encrypt rows using the new key, update key_version'
UPDATE patients_secure SET
    email_enc     = pgp_sym_encrypt(
                      pgp_sym_decrypt(email_enc,     'demo_encryption_key_v1'),
                      'demo_encryption_key_v2'),
    phone_enc     = pgp_sym_encrypt(
                      pgp_sym_decrypt(phone_enc,     'demo_encryption_key_v1'),
                      'demo_encryption_key_v2'),
    dob_enc       = pgp_sym_encrypt(
                      pgp_sym_decrypt(dob_enc,       'demo_encryption_key_v1'),
                      'demo_encryption_key_v2'),
    diagnosis_enc = pgp_sym_encrypt(
                      pgp_sym_decrypt(diagnosis_enc, 'demo_encryption_key_v1'),
                      'demo_encryption_key_v2'),
    key_version   = 2
WHERE key_version = 1;

\echo '-- Step 3: verify all rows now use key v2'
SELECT id, key_version FROM patients_secure;

\echo '-- Step 4: confirm decryption with new key'
SELECT id,
       pgp_sym_decrypt(email_enc, 'demo_encryption_key_v2') AS email,
       pgp_sym_decrypt(diagnosis_enc, 'demo_encryption_key_v2') AS diagnosis
FROM patients_secure;


\echo ''
\echo '════════════════════════════════════════════════════════════════════'
\echo ' Reference — pgcrypto function summary                               '
\echo '════════════════════════════════════════════════════════════════════'

\echo '--'
\echo '-- pgp_sym_encrypt(plaintext, password)      → BYTEA  (encrypt)'
\echo '-- pgp_sym_decrypt(ciphertext, password)     → TEXT   (decrypt)'
\echo '-- pgp_sym_decrypt(ciphertext, password)::T  → T      (cast to target type)'
\echo '--'
\echo '-- digest(data, algorithm)                   → BYTEA  (SHA-256, SHA-512, MD5)'
\echo '-- hmac(data, key, algorithm)                → BYTEA  (keyed hash)'
\echo '-- encode(bytea, format)                     → TEXT   (hex / base64 / escape)'
\echo '--'
\echo '-- gen_random_bytes(n)                       → BYTEA  (cryptographic RNG)'
\echo '-- gen_random_uuid()                         → UUID   (v4 random UUID)'
\echo '--'
\echo '-- crypt(password, gen_salt(''bf''))          → TEXT   (bcrypt password hash)'
\echo '-- crypt(input, stored_hash) = stored_hash   → boolean verify'
