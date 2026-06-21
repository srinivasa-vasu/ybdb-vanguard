# Semantic Search with pgvector

[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/srinivasa-vasu/ybdb-vanguard?devcontainer_path=.devcontainer%2Finit-pgvector%2Fdevcontainer.json)

Vector similarity search in YugabyteDB using the bundled pgvector extension: L2 distance, cosine similarity, inner product, HNSW approximate nearest neighbor indexes, and hybrid SQL + vector queries — no separate vector database required.

---

> **Run queries interactively**: Select any SQL block → **`Ctrl+Shift+Enter`** (Windows/Linux) or **`Cmd+Shift+Enter`** (Mac) → runs in the active terminal.

---

## Running the demo

| Task | What it runs |
|---|---|
| **Terminal → Run Task → `pgvector-demo`** | "The Recommendation Engine Problem" (`prompt.sh`) |
| **Terminal → Run Task → `ysql`** | YSQL shell for the Workshop section below |

---

## Workshop

> Use the **`ysql`** terminal — it opens automatically when the container starts.

### Part 1 · Enable pgvector

pgvector is bundled with YugabyteDB — no installation needed.

```sql
CREATE EXTENSION IF NOT EXISTS vector;
```

---

### Part 2 · Vector columns and data types

The demo loads a 20-row product catalog from `products.sql`:

```bash
ysqlsh -h 127.0.0.1 -f products.sql
```

The schema uses an 8-dimensional `vector` column (dimensions: tech, sports, music, health, travel, fashion, gaming, food):

```sql
CREATE TABLE products (
  id          SERIAL PRIMARY KEY,
  name        TEXT           NOT NULL,
  category    TEXT           NOT NULL,
  description TEXT           NOT NULL,
  price       NUMERIC(10,2),
  embedding   vector(8)      -- 8-dimensional; max 16,000 dimensions
);

-- Insert as a string literal '[v1, v2, ..., vn]'
INSERT INTO products (name, category, description, price, embedding) VALUES
  ('Noise-Cancelling Headphones', 'Electronics', '...', 299.99, '[0.6,0.0,0.9,0.1,0.2,0.2,0.1,0.0]');

-- Cast from text
SELECT '[1,2,3]'::vector(3);
```

---

### Part 3 · Distance operators and similarity

All three operators return a **distance** (smaller = more similar). Derive similarity from distance where applicable.

| Operator | Name | Distance formula | Similarity |
|---|---|---|---|
| `<->` | L2 (Euclidean) | `sqrt(sum((a-b)^2))` | No standard bounded form |
| `<=>` | Cosine | `1 - cosine_sim` | `1 - distance` (range −1 to 1) |
| `<#>` | Neg. inner product | `-(a·b)` | `-1 * distance` (unbounded) |

```sql
-- L2: straight-line distance — magnitude sensitive, no standard similarity
SELECT name,
       (embedding <-> '[0.5,0.0,0.5,0.0,0.0,0.0,0.9,0.0]') AS l2_distance
FROM products
ORDER BY embedding <-> '[0.5,0.0,0.5,0.0,0.0,0.0,0.9,0.0]'
LIMIT 5;

-- Cosine: 1 - distance = similarity
SELECT name,
       1 - (embedding <=> '[0.0,0.8,0.0,0.9,0.0,0.1,0.0,0.0]') AS cosine_similarity,
       (embedding <=> '[0.0,0.8,0.0,0.9,0.0,0.1,0.0,0.0]')     AS cosine_distance
FROM products
ORDER BY embedding <=> '[0.0,0.8,0.0,0.9,0.0,0.1,0.0,0.0]'  -- index used on ORDER BY
LIMIT 5;

-- Inner product: -1 * distance = similarity
SELECT name,
       -1 * (embedding <#> '[0.0,0.0,0.9,0.0,0.0,0.0,0.0,0.0]') AS ip_similarity,
       (embedding <#> '[0.0,0.0,0.9,0.0,0.0,0.0,0.0,0.0]')       AS ip_distance
FROM products
ORDER BY embedding <#> '[0.0,0.0,0.9,0.0,0.0,0.0,0.0,0.0]'
LIMIT 5;
```

**Choosing the right metric:**

| Metric | Best for |
|---|---|
| Cosine | Language model embeddings (OpenAI, Cohere, Ollama) — scale-invariant |
| Inner product | Normalized embeddings — equivalent to cosine, cheaper to compute |
| L2 | Image or geometric feature vectors — absolute magnitude matters |

---

### Part 4 · Vector magnitude, normalization, and why inner product wins

`l2_normalize` returns a unit vector of the same direction (magnitude = 1). `l2_norm` is not available for the `vector` type in this YugabyteDB build — compute magnitude as L2 distance from the zero vector instead.

```sql
-- Magnitude = L2 distance from the zero vector (l2_norm not available for vector type)
SELECT name,
       ROUND((embedding <-> '[0,0,0,0,0,0,0,0]'::vector(8))::numeric, 4) AS magnitude
FROM products ORDER BY magnitude DESC LIMIT 5;

-- Normalize to unit length; verify magnitude is now 1
SELECT name,
       ROUND((l2_normalize(embedding::vector(8)) <-> '[0,0,0,0,0,0,0,0]'::vector(8))::numeric, 4) AS magnitude_after,
       l2_normalize(embedding::vector(8)) AS unit_vector
FROM products LIMIT 3;
-- magnitude_after is always 1.0
```

**The normalization identity:**

```
cosine(a, b) = (a · b) / (|a| × |b|)

When |a| = |b| = 1:
  cosine(a, b) = a · b = inner product(a, b)
```

This means: normalize your embeddings once at INSERT time, then use `<#>` with a `vector_ip_ops` index instead of `<=>` with `vector_cosine_ops`. You get **identical rankings** with **cheaper arithmetic** (no square root, no division).

```sql
-- Add a normalized column
ALTER TABLE products ADD COLUMN embedding_norm vector(8);
UPDATE products SET embedding_norm = l2_normalize(embedding::vector(8));

-- Compare: cosine similarity vs inner product similarity on normalized vectors
SELECT name,
       ROUND((-1 * (embedding_norm <#> '[0.756,0.000,0.378,0.126,0.252,0.252,0.252,0.000]'::vector(8)))::numeric, 4) AS ip_sim,
       ROUND((1  -  (embedding_norm <=> '[0.756,0.000,0.378,0.126,0.252,0.252,0.252,0.000]'::vector(8)))::numeric, 4) AS cos_sim
FROM products
ORDER BY embedding_norm <#> '[0.756,0.000,0.378,0.126,0.252,0.252,0.252,0.000]'
LIMIT 5;
-- ip_sim and cos_sim are identical — normalization collapses the two

-- Production pattern: normalized column + IP index
CREATE INDEX NONCONCURRENTLY idx_embedding_norm
ON products USING ybhnsw (embedding_norm vector_ip_ops)
WITH (m = 16, ef_construction = 100);

-- Query with inner product — cosine-equivalent, index-backed
SELECT name,
       -1 * (embedding_norm <#> '[0.756,0.000,0.378,0.126,0.252,0.252,0.252,0.000]') AS similarity
FROM products
ORDER BY embedding_norm <#> '[0.756,0.000,0.378,0.126,0.252,0.252,0.252,0.000]'
LIMIT 5;
```

**Summary of the production normalization pattern:**

| Step | Action |
|---|---|
| Insert | `embedding_norm = l2_normalize(raw_embedding)` |
| Index | `USING ybhnsw (embedding_norm vector_ip_ops)` |
| Query | `ORDER BY embedding_norm <#> l2_normalize(query_embedding)` |
| Similarity display | `-1 * (embedding_norm <#> query)` |

---

### Part 5 · Hybrid search — vector + SQL predicates

Vector queries compose naturally with standard SQL filters. The database pushes the `WHERE` clause down before ranking by distance.

```sql
-- Similar products, but only under $150
SELECT name, category, price,
       ROUND((embedding <=> '[0.6,0.0,0.8,0.1,0.2,0.2,0.2,0.0]')::numeric, 4) AS dist
FROM   products
WHERE  price < 150.00
ORDER BY embedding <=> '[0.6,0.0,0.8,0.1,0.2,0.2,0.2,0.0]'
LIMIT  5;

-- Combine with any SQL expression
WHERE  category = 'Electronics' AND price BETWEEN 50 AND 200
ORDER BY embedding <=> query_vector
LIMIT 10;
```

---

### Part 6 · HNSW indexes (ybhnsw) — one per distance operator

Without an index, every vector query scans the full table (exact nearest neighbor). `ybhnsw` provides approximate nearest neighbor (ANN) search via a Hierarchical Navigable Small World graph.

**YugabyteDB requires `NONCONCURRENTLY`** — the index build holds an exclusive lock that blocks writes. Build during a maintenance window.

**The operator class must match the distance operator used in queries.** A mismatch silently falls back to a sequential scan — there is no error.

| Index | Column | Operator class | Query operator |
|---|---|---|---|
| `idx_products_l2` | `embedding` | `vector_l2_ops` | `<->` |
| `idx_products_cosine` | `embedding` | `vector_cosine_ops` | `<=>` |
| `idx_products_ip` | `embedding_norm` | `vector_ip_ops` | `<#>` |

```sql
-- L2 distance index
CREATE INDEX NONCONCURRENTLY idx_products_l2
ON products USING ybhnsw (embedding vector_l2_ops)
WITH (m = 16, ef_construction = 100);

-- Cosine distance index
CREATE INDEX NONCONCURRENTLY idx_products_cosine
ON products USING ybhnsw (embedding vector_cosine_ops)
WITH (m = 16, ef_construction = 100);

-- Inner product index (on normalized column)
CREATE INDEX NONCONCURRENTLY idx_products_ip
ON products USING ybhnsw (embedding_norm vector_ip_ops)
WITH (m = 16, ef_construction = 100);

-- Verify each query uses its matching index
EXPLAIN SELECT name FROM products
ORDER BY embedding <-> '[0.5,0.0,0.5,0.0,0.0,0.0,0.9,0.0]' LIMIT 5;
-- → Index Scan on idx_products_l2

EXPLAIN SELECT name FROM products
ORDER BY embedding <=> '[0.0,0.8,0.0,0.9,0.0,0.1,0.0,0.0]' LIMIT 5;
-- → Index Scan on idx_products_cosine

EXPLAIN SELECT name FROM products
ORDER BY embedding_norm <#> '[0.756,0.000,0.378,0.126,0.252,0.252,0.252,0.000]' LIMIT 5;
-- → Index Scan on idx_products_ip
```

---

### Part 7 · HNSW build parameters

| Parameter | Range | Default | Effect |
|---|---|---|---|
| `m` | 5–64 | 32 | Connections per graph node — higher = better recall, larger index |
| `ef_construction` | 50–1000 | 200 | Candidate list at build time — higher = better recall, slower build |

```sql
-- High-recall index (better quality, slower build, larger index)
CREATE INDEX NONCONCURRENTLY ...
USING ybhnsw (embedding vector_cosine_ops)
WITH (m = 32, ef_construction = 400);

-- Faster build with lower recall
WITH (m = 8, ef_construction = 64);
```

---

### Part 8 · ef_search — tune recall vs latency at query time

`hnsw.ef_search` controls how many candidates the index explores per query. Set it per session or per transaction.

```sql
-- Fast but lower recall (default 40)
SET hnsw.ef_search = 10;

-- Slower but higher recall
SET hnsw.ef_search = 200;

-- Verify the index is being used
EXPLAIN SELECT name FROM products
ORDER BY embedding <=> '[0.6,0.0,0.8,0.1,0.2,0.2,0.2,0.0]'
LIMIT 5;
-- → Index Scan on idx_embedding_cosine
```

**Recall benchmarking**: compare results with `ef_search = 10` vs exact search (no index or very high ef_search) to measure recall@k. Target 95%+ recall for most production workloads.

---

### Part 9 · Vector functions

```sql
-- Magnitude via distance from zero vector (l2_norm not available for vector in this build)
SELECT '[3,4]'::vector(2) <-> '[0,0]'::vector(2);   -- → 5

-- Normalise a vector to unit length (for cosine similarity via inner product)
SELECT l2_normalize('[3,4,0]'::vector(3));  -- → [0.6, 0.8, 0]

-- Subtract two vectors element-wise
SELECT '[4,5,6]'::vector - '[1,2,3]'::vector;  -- → [3,3,3]

-- Average of all embeddings in a table (centroid)
SELECT avg(embedding) FROM products;
```

---

### Part 10 · YugabyteDB pgvector limitations

| Limitation | Detail |
|---|---|
| Index creation | `NONCONCURRENTLY` required — takes an exclusive lock that blocks writes |
| Partial indexes | Not supported on vector columns |
| xCluster | Vector indexes are not replicated via xCluster |
| Time travel | `yb_read_time` queries unavailable for vector data |
| IVFFlat | Not supported — only `ybhnsw` is available |
| Concurrent writes during build | Blocked by the exclusive lock; plan for a maintenance window |

All standard SQL operations (SELECT, JOIN, WHERE, aggregates, RETURNING, CTEs) work normally on vector columns — only the index mechanics differ.

---

### Part 11 · Inspect available operator classes

```sql
SELECT a.amname, opc.opcname, opc.opcintype::regtype
FROM   pg_opclass opc
JOIN   pg_am a ON a.oid = opc.opcmethod
WHERE  a.amname = 'ybhnsw'
ORDER BY opc.opcname;
```

---

## Key mental models

```
vector(n)
  → fixed-dimension column; all rows must have the same n
  → stored as an array of 4-byte floats

Distance operators:
  <->  L2 distance     → sqrt(sum((a-b)^2))        — magnitude-sensitive
  <=>  cosine distance → 1 - (a·b / |a||b|)        — scale-invariant (angle only)
  <#>  neg inner prod  → -(a·b)                     — for IP-trained models

Similarity from distance:
  L2         → no standard bounded similarity
  cosine     → 1 - distance                    (range −1 to 1)
  inner prod → -1 * distance                   (unbounded, higher is better)

Magnitude and normalization:
  v <-> '[0,...]'   → vector magnitude (l2_norm unavailable for vector type in this build)
  l2_normalize(v)   → unit vector: same direction, magnitude = 1

The normalization identity:
  cosine(a,b) = a·b  when |a| = |b| = 1
  → for normalized vectors, inner product == cosine similarity
  → preferred production pattern:
      normalize at INSERT    (embedding_norm = l2_normalize(raw))
      index with IP ops      (USING ybhnsw (embedding_norm vector_ip_ops))
      query with <#>         (ORDER BY embedding_norm <#> l2_normalize(q))
      display similarity     (-1 * distance)
  → same ranking as cosine, no square root or division at query time

ybhnsw index
  → approximate NN — trades recall for speed at 1M+ rows
  → operator class must match the distance operator in queries
  → CREATE INDEX NONCONCURRENTLY (exclusive lock during build)
  → hnsw.ef_search controls recall quality at query time (default 40)

Hybrid search
  → WHERE (SQL predicates) + ORDER BY (vector distance) + LIMIT k
  → standard SQL — no special syntax, no extra infrastructure

In production
  → embeddings come from an embedding model (OpenAI, Cohere, Ollama, etc.)
  → store both the source text and its embedding in the same row
  → normalize at write time, not at query time
  → refresh embeddings when the source text changes
```
