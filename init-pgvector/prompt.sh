#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# YugabyteDB pgvector demo  —  "The Recommendation Engine Problem"
#
# Scenario: An e-commerce platform needs to recommend similar products. Keyword
# search (LIKE, full-text) misses cross-category semantic similarity. A gaming
# headset and noise-cancelling headphones are "close" even though they are in
# different categories. pgvector stores embeddings and finds neighbors by
# vector distance — no external vector DB required.
#
# Embeddings: 8 dimensions representing feature axes:
#   [tech, sports, music, health, travel, fashion, gaming, food]
# ─────────────────────────────────────────────────────────────────────────────

. pscript
set -f  # disable filename expansion

TYPE_SPEED=70
NO_WAIT=false
DEMO_PROMPT="${GREEN}➜ ${CYAN}\W ${COLOR_RESET}"

# Idempotent cleanup
ysqlsh -h 127.0.0.1 -c "DROP TABLE IF EXISTS products CASCADE;" 2>/dev/null || true

clear

# ── Scene 1: Enable extension ─────────────────────────────────────────────────

p "=== 'The Recommendation Engine Problem' — pgvector Demo ==="
p ""
p "pgvector is bundled with YugabyteDB. One command to enable it."

pe "ysqlsh -h 127.0.0.1 -c \"CREATE EXTENSION IF NOT EXISTS vector;\""

# ── Scene 2: Schema ───────────────────────────────────────────────────────────

p ""
p "--- Part 1: Create a product catalog with vector embeddings ---"
p "8-dimensional embeddings: [tech, sports, music, health, travel, fashion, gaming, food]"
p "In production these come from an embedding model (e.g., OpenAI, Cohere, Ollama)."

pe "ysqlsh -h 127.0.0.1 -f products.sql"

pe "ysqlsh -h 127.0.0.1 -c \"SELECT id, name, category, price FROM products ORDER BY id;\""

# ── Scene 3: L2 distance ──────────────────────────────────────────────────────

p ""
p "--- Part 2: L2 (Euclidean) distance — <-> operator ---"
p "Straight-line distance between two points in vector space."
p "L2 only has distance — there is no standard bounded similarity for it."
p "Query vector: [0.5, 0.0, 0.5, 0.0, 0.0, 0.0, 0.9, 0.0]  (gaming + music)"

pe "ysqlsh -h 127.0.0.1 -c \"
SELECT
  name,
  category,
  ROUND((embedding <-> '[0.5,0.0,0.5,0.0,0.0,0.0,0.9,0.0]')::numeric, 4) AS l2_distance
FROM   products
ORDER BY embedding <-> '[0.5,0.0,0.5,0.0,0.0,0.0,0.9,0.0]'
LIMIT  5;\""

p "Gaming Headset tops the list. Noise-Cancelling Headphones and Wireless Earbuds follow"
p "— the embedding captures the music+gaming dimensions shared across those products."
p "L2 is sensitive to magnitude: a vector twice as long scores worse even if perfectly aligned."

# ── Scene 4: Cosine distance ──────────────────────────────────────────────────

p ""
p "--- Part 3: Cosine distance — <=> operator ---"
p "Measures the angle between vectors — direction only, magnitude is ignored."
p "distance = 1 - cosine_similarity  (range 0 to 2)"
p "similarity = 1 - distance         (1 = identical direction, -1 = opposite)"
p "Query vector: [0.0, 0.8, 0.0, 0.9, 0.0, 0.1, 0.0, 0.0]  (sports + health)"

pe "ysqlsh -h 127.0.0.1 -c \"
SELECT
  name,
  category,
  ROUND((1 - (embedding <=> '[0.0,0.8,0.0,0.9,0.0,0.1,0.0,0.0]'))::numeric, 4) AS cosine_similarity,
  ROUND((embedding <=> '[0.0,0.8,0.0,0.9,0.0,0.1,0.0,0.0]')::numeric, 4)       AS cosine_distance
FROM   products
ORDER BY embedding <=> '[0.0,0.8,0.0,0.9,0.0,0.1,0.0,0.0]'
LIMIT  5;\""

p "Resistance Bands and Yoga Mat score highest similarity."
p "Trail Running Shoes follows — high sports, moderate health — directionally aligned."
p "Best choice for language model embeddings (OpenAI, Cohere, Ollama — all unit-normed)."

# ── Scene 5: Inner product ────────────────────────────────────────────────────

p ""
p "--- Part 4: Inner product — <#> operator ---"
p "<#> stores the NEGATIVE inner product. Convert to similarity by multiplying by -1."
p "similarity = -1 * distance   (higher dot product = more similar)"
p "Query vector: [0.0, 0.0, 0.9, 0.0, 0.0, 0.0, 0.0, 0.0]  (music only)"

pe "ysqlsh -h 127.0.0.1 -c \"
SELECT
  name,
  category,
  ROUND((-1 * (embedding <#> '[0.0,0.0,0.9,0.0,0.0,0.0,0.0,0.0]'))::numeric, 4) AS ip_similarity,
  ROUND((embedding <#> '[0.0,0.0,0.9,0.0,0.0,0.0,0.0,0.0]')::numeric, 4)         AS ip_distance
FROM   products
ORDER BY embedding <#> '[0.0,0.0,0.9,0.0,0.0,0.0,0.0,0.0]'
LIMIT  5;\""

p "Vinyl Record Player and Acoustic Guitar top the list — highest music dimension."

# ── Scene 6: Magnitude, normalization, and why IP wins ───────────────────────

p ""
p "--- Part 5: Vector magnitude, normalization, and why IP is the fast path ---"
p "l2_norm is not available for vector in this YugabyteDB build."
p "Magnitude = L2 distance from the zero vector:  embedding <-> '[0,...,0]'"

pe "ysqlsh -h 127.0.0.1 -c \"
SELECT
  name,
  ROUND((embedding <-> '[0,0,0,0,0,0,0,0]'::vector(8))::numeric, 4) AS magnitude
FROM   products
ORDER BY magnitude DESC
LIMIT  5;\""

p "Most embeddings from real models are NOT unit-length — magnitudes vary."
p ""
p "l2_normalize returns a unit vector (magnitude = 1) pointing the same direction."

pe "ysqlsh -h 127.0.0.1 -c \"
SELECT
  name,
  ROUND((l2_normalize(embedding::vector(8)) <-> '[0,0,0,0,0,0,0,0]'::vector(8))::numeric, 4) AS norm_after,
  l2_normalize(embedding::vector(8)) AS unit_vector
FROM   products
LIMIT  3;\""

p "After normalization: magnitude is always 1. Direction is preserved."

p ""
p "Key identity: for unit-normalized vectors, inner product == cosine similarity."
p "  cosine(a,b) = (a·b) / (|a| * |b|)"
p "  When |a| = |b| = 1:  cosine(a,b) = a·b = inner product"

pe "ysqlsh -h 127.0.0.1 -c \"
SELECT
  name,
  ROUND((-1 * (l2_normalize(embedding::vector(8)) <#> l2_normalize('[0.6,0.0,0.8,0.1,0.2,0.2,0.2,0.0]'::vector(8))))::numeric, 4) AS ip_sim,
  ROUND((1  -  (l2_normalize(embedding::vector(8)) <=> l2_normalize('[0.6,0.0,0.8,0.1,0.2,0.2,0.2,0.0]'::vector(8))))::numeric, 4) AS cos_sim
FROM   products
ORDER BY l2_normalize(embedding::vector(8)) <#> l2_normalize('[0.6,0.0,0.8,0.1,0.2,0.2,0.2,0.0]'::vector(8))
LIMIT  5;\""

p "ip_sim and cos_sim are identical — normalization collapses the two into one."
p ""
p "Production pattern: normalize embeddings at INSERT time, use vector_ip_ops index."
p "Inner product is computationally cheaper than cosine and gives the same ranking."

pe "ysqlsh -h 127.0.0.1 -c \"
ALTER TABLE products ADD COLUMN IF NOT EXISTS embedding_norm vector(8);
UPDATE products SET embedding_norm = l2_normalize(embedding::vector(8));\""

pe "ysqlsh -h 127.0.0.1 -c \"
SELECT
  name,
  ROUND((-1 * (embedding_norm <#> '[0.756,0.000,0.378,0.126,0.252,0.252,0.252,0.000]'))::numeric, 4) AS similarity
FROM   products
ORDER BY embedding_norm <#> '[0.756,0.000,0.378,0.126,0.252,0.252,0.252,0.000]'
LIMIT  5;\""

p "Query vector is the l2_normalize of '[0.6,0.0,0.3,0.1,0.2,0.2,0.2,0.0]'."
p "All queries now use inner product — fastest path, cosine-equivalent results."

# ── Scene 7: Hybrid search ────────────────────────────────────────────────────

p ""
p "--- Part 6: Hybrid search — vector similarity + SQL predicates ---"
p "Vector search composes naturally with WHERE clauses. Find similar products under 150."

pe "ysqlsh -h 127.0.0.1 -c \"
SELECT
  name,
  category,
  price,
  ROUND((1 - (embedding <=> '[0.6,0.0,0.8,0.1,0.2,0.2,0.2,0.0]'))::numeric, 4) AS cosine_similarity
FROM   products
WHERE  price < 150.00
ORDER BY embedding <=> '[0.6,0.0,0.8,0.1,0.2,0.2,0.2,0.0]'
LIMIT  5;\""

p "Standard SQL filter (price < 150) combines with vector ordering. No extra plumbing."

# ── Scene 8: HNSW index ───────────────────────────────────────────────────────

p ""
p "--- Part 7: HNSW indexes — one per distance operator ---"
p "Without an index, every query scans all rows. At 1M rows that is too slow."
p "HNSW builds a proximity graph for sub-linear approximate nearest neighbor search."
p ""
p "YugabyteDB requires NONCONCURRENTLY — the build holds an exclusive lock."
p "CRITICAL: each operator class must match the distance operator used in queries."
p "  vector_l2_ops     → <->   vector_cosine_ops → <=>   vector_ip_ops → <#>"

pe "ysqlsh -h 127.0.0.1 -c \"
CREATE INDEX NONCONCURRENTLY idx_products_l2
ON products USING ybhnsw (embedding vector_l2_ops)
WITH (m = 16, ef_construction = 100);\""

pe "ysqlsh -h 127.0.0.1 -c \"
CREATE INDEX NONCONCURRENTLY idx_products_cosine
ON products USING ybhnsw (embedding vector_cosine_ops)
WITH (m = 16, ef_construction = 100);\""

pe "ysqlsh -h 127.0.0.1 -c \"
CREATE INDEX NONCONCURRENTLY idx_products_ip
ON products USING ybhnsw (embedding_norm vector_ip_ops)
WITH (m = 16, ef_construction = 100);\""

p ""
p "Verify each query uses its matching index:"

pe "ysqlsh -h 127.0.0.1 -c \"
EXPLAIN SELECT name FROM products
ORDER BY embedding <-> '[0.5,0.0,0.5,0.0,0.0,0.0,0.9,0.0]'
LIMIT 5;\""

p "→ Index Scan on idx_products_l2 (vector_l2_ops)"

pe "ysqlsh -h 127.0.0.1 -c \"
EXPLAIN SELECT name FROM products
ORDER BY embedding <=> '[0.0,0.8,0.0,0.9,0.0,0.1,0.0,0.0]'
LIMIT 5;\""

p "→ Index Scan on idx_products_cosine (vector_cosine_ops)"

pe "ysqlsh -h 127.0.0.1 -c \"
EXPLAIN SELECT name FROM products
ORDER BY embedding_norm <#> '[0.756,0.000,0.378,0.126,0.252,0.252,0.252,0.000]'
LIMIT 5;\""

p "→ Index Scan on idx_products_ip (vector_ip_ops)"
p "Wrong operator class on an index = no index scan. Mismatches silently seq-scan."

# ── Scene 9: ef_search tuning ─────────────────────────────────────────────────

p ""
p "--- Part 8: ef_search — tune recall vs latency ---"
p "ef_search controls how many candidates the index explores per query."
p "Higher → better recall, more work. Default is 40."

pe "ysqlsh -h 127.0.0.1 -c \"
SET hnsw.ef_search = 10;
SELECT name,
       ROUND((-1 * (embedding_norm <#> '[0.756,0.000,0.378,0.126,0.252,0.252,0.252,0.000]'))::numeric, 4) AS similarity
FROM   products
ORDER BY embedding_norm <#> '[0.756,0.000,0.378,0.126,0.252,0.252,0.252,0.000]'
LIMIT  5;\""

pe "ysqlsh -h 127.0.0.1 -c \"
SET hnsw.ef_search = 200;
SELECT name,
       ROUND((-1 * (embedding_norm <#> '[0.756,0.000,0.378,0.126,0.252,0.252,0.252,0.000]'))::numeric, 4) AS similarity
FROM   products
ORDER BY embedding_norm <#> '[0.756,0.000,0.378,0.126,0.252,0.252,0.252,0.000]'
LIMIT  5;\""

p "Same results on this small dataset. At 1M rows, ef_search=10 may miss true neighbors"
p "that ef_search=200 finds. Benchmark recall@k and set ef_search to meet your target."

# ── Scene 10: Operator class selection ───────────────────────────────────────

p ""
p "--- Part 9: Choose the right operator class ---"
p "The index operator class must match the distance operator used in queries."

pe "ysqlsh -h 127.0.0.1 -c \"
SELECT a.amname AS index_method, opc.opcname AS operator_class
FROM   pg_opclass opc
JOIN   pg_am a ON a.oid = opc.opcmethod
WHERE  a.amname = 'ybhnsw'
ORDER BY opc.opcname;\""

p "  vector_cosine_ops → <=>  cosine distance  (unnormalized language model embeddings)"
p "  vector_ip_ops     → <#>  inner product    (normalized embeddings — preferred)"
p "  vector_l2_ops     → <->  L2 distance      (geometric / image embeddings)"

# ── Scene 11: YugabyteDB-specific limitations ────────────────────────────────

p ""
p "--- Part 10: YugabyteDB pgvector limitations to know ---"
p "  • CREATE INDEX NONCONCURRENTLY required (exclusive lock during build)"
p "  • Partial indexes on vector columns not supported"
p "  • Vector indexes do not replicate via xCluster"
p "  • yb_read_time time-travel queries unavailable for vector data"
p "  • IVFFlat not supported — only ybhnsw available"
p ""
p "All other SQL features (WHERE, JOIN, aggregates, RETURNING, CTEs) work normally."

# ── Summary ───────────────────────────────────────────────────────────────────

p ""
p "=== pgvector Summary ==="
p "  CREATE EXTENSION vector          → enable pgvector (bundled in YugabyteDB)"
p "  vector(n)                        → fixed-dimension column type"
p ""
p "  Distance operators:"
p "  <->  L2 distance                 → sqrt(sum((a-b)^2))  — magnitude-sensitive"
p "  <=>  cosine distance             → 1 - cosine_sim      — scale-invariant"
p "  <#>  neg inner product           → -(a·b)              — for IP-trained models"
p ""
p "  Similarity from distance:"
p "  L2         → no standard similarity bound"
p "  cosine     → 1 - distance        (range -1 to 1)"
p "  inner prod → -1 * distance       (range -inf to +inf)"
p ""
p "  v <-> '[0,...]'   → vector magnitude (l2_norm not available for vector type)"
p "  l2_normalize(v)   → unit vector (magnitude = 1, same direction)"
p ""
p "  Normalization insight:"
p "  cosine(a,b) = a·b when |a| = |b| = 1"
p "  → normalize at INSERT, use vector_ip_ops — same ranking, cheaper compute"
p ""
p "  USING ybhnsw (col vector_l2_ops)     → L2 index       — pair with <->"
p "  USING ybhnsw (col vector_cosine_ops) → cosine index   — pair with <=>"
p "  USING ybhnsw (col vector_ip_ops)     → IP index       — pair with <#>"
p "  hnsw.ef_search                    → tune recall vs latency at query time"
p "  WHERE + ORDER BY + LIMIT          → hybrid SQL + vector search"
p ""
p "One database. SQL + vectors. No separate vector store to operate."

cmd
p ""
