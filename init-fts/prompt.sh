#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# YugabyteDB Full-Text Search demo  —  "The Search Engine Problem"
#
# Scenario: A tech news platform stores thousands of articles. The team starts
# with LIKE-based search (fast to build, slow to scale) and upgrades to full-
# text search: stemming, ranking, highlighting, and GIN-indexed queries — all
# without an external search engine.
# ─────────────────────────────────────────────────────────────────────────────

. pscript
set -f  # disable filename expansion — prevents SELECT * glob-expanding in eval $@

TYPE_SPEED=35
NO_WAIT=false
DEMO_PROMPT="${GREEN}➜ ${CYAN}\W ${COLOR_RESET}"

# Idempotent cleanup
ysqlsh -h 127.0.0.1 -c "DROP TABLE IF EXISTS articles CASCADE;" 2>/dev/null || true

clear

# ── Scene 1: Setup ────────────────────────────────────────────────────────────

p "=== 'The Search Engine Problem' — Full-Text Search Demo ==="
p ""
p "A tech news platform stores articles in YugabyteDB."
p "Users expect Google-quality search. We start naive and upgrade."

pe "ysqlsh -h 127.0.0.1 -f articles.sql"

# ── Scene 2: LIKE — the naive way ────────────────────────────────────────────

p ""
p "--- Part 1: The naive approach — LIKE ---"
p "LIKE works, but it is case-sensitive and has no stemming."

pe "ysqlsh -h 127.0.0.1 -c \"SELECT id, title FROM articles WHERE body LIKE '%distributed%' ORDER BY id;\""

p "'Distributed' (capital D) is missed — LIKE is case-sensitive."
pe "ysqlsh -h 127.0.0.1 -c \"SELECT id, title FROM articles WHERE body LIKE '%Distributed%' ORDER BY id;\""

p "No index can help a leading-wildcard LIKE — always a sequential scan."
pe "ysqlsh -h 127.0.0.1 -c \"EXPLAIN SELECT id, title FROM articles WHERE body LIKE '%distributed%';\""

# ── Scene 3: tsvector basics ──────────────────────────────────────────────────

p ""
p "--- Part 2: tsvector — how the engine sees your text ---"
p "to_tsvector parses text into stemmed lexemes with positional markers."

pe "ysqlsh -h 127.0.0.1 -c \"SELECT to_tsvector('english', 'YugabyteDB scales distributed SQL to millions of transactions');\""

p "Stop words removed ('to', 'of'). Stems kept: 'distribut', 'transact', 'scale'."
p "'distributed', 'distributing', 'distribution' all stem to 'distribut'."

pe "ysqlsh -h 127.0.0.1 -c \"
SELECT to_tsquery('english', 'distributed'),
       to_tsquery('english', 'distributing'),
       to_tsquery('english', 'distribution');\""

p "All three queries produce the same lexeme — stemming makes them equivalent."

# ── Scene 4: @@ operator ─────────────────────────────────────────────────────

p ""
p "--- Part 3: Full-text search with @@ ---"
p "'distribute' now matches distributed, distributing, distribution automatically."

pe "ysqlsh -h 127.0.0.1 -c \"
SELECT id, title
FROM   articles
WHERE  to_tsvector('english', title || ' ' || body)
       @@ to_tsquery('english', 'distribute')
ORDER BY id;\""

p ""
p "AND: articles about both 'database' AND 'security'."
pe "ysqlsh -h 127.0.0.1 -c \"
SELECT id, title
FROM   articles
WHERE  to_tsvector('english', title || ' ' || body)
       @@ to_tsquery('english', 'database & security')
ORDER BY id;\""

p ""
p "OR: 'kafka' OR 'replication'."
pe "ysqlsh -h 127.0.0.1 -c \"
SELECT id, title
FROM   articles
WHERE  to_tsvector('english', title || ' ' || body)
       @@ to_tsquery('english', 'kafka | replication')
ORDER BY id;\""

p ""
p "NOT: 'database' but not 'encryption'."
pe "ysqlsh -h 127.0.0.1 -c \"
SELECT id, title
FROM   articles
WHERE  to_tsvector('english', title || ' ' || body)
       @@ to_tsquery('english', 'database & !encrypt')
ORDER BY id;\""

# ── Scene 5: User-friendly parsers ───────────────────────────────────────────

p ""
p "--- Part 4: User-friendly query parsers ---"
p "websearch_to_tsquery accepts Google-style input: no operator syntax needed."

pe "ysqlsh -h 127.0.0.1 -c \"
SELECT id, title
FROM   articles
WHERE  to_tsvector('english', title || ' ' || body)
       @@ websearch_to_tsquery('english', 'distributed database -encryption')
ORDER BY id;\""

p ""
p "phraseto_tsquery: terms must appear adjacent and in order."

pe "ysqlsh -h 127.0.0.1 -c \"
SELECT id, title
FROM   articles
WHERE  to_tsvector('english', title || ' ' || body)
       @@ phraseto_tsquery('english', 'distributed transaction')
ORDER BY id;\""

# ── Scene 6: Ranking ──────────────────────────────────────────────────────────

p ""
p "--- Part 5: Relevance ranking with ts_rank ---"
p "ts_rank scores each document by how frequently query terms appear."

pe "ysqlsh -h 127.0.0.1 -c \"
SELECT
  id,
  title,
  ROUND(ts_rank(
    to_tsvector('english', title || ' ' || body),
    to_tsquery('english', 'database | distribute | transaction')
  )::numeric, 4) AS rank
FROM   articles
WHERE  to_tsvector('english', title || ' ' || body)
       @@ to_tsquery('english', 'database | distribute | transaction')
ORDER BY rank DESC;\""

# ── Scene 7: Highlighting ─────────────────────────────────────────────────────

p ""
p "--- Part 6: ts_headline — highlight matching terms ---"
p "Returns a snippet of text with matched terms wrapped in <b>...</b>."

pe "ysqlsh -h 127.0.0.1 -c \"
SELECT
  id,
  title,
  ts_headline(
    'english', body,
    to_tsquery('english', 'distribute | transaction'),
    'MaxWords=20, MinWords=10, ShortWord=3'
  ) AS snippet
FROM   articles
WHERE  to_tsvector('english', title || ' ' || body)
       @@ to_tsquery('english', 'distribute | transaction')
ORDER BY id;\""

# ── Scene 8: Persisted tsvector + GIN index ───────────────────────────────────

p ""
p "--- Part 7: Persisted tsvector column + GIN index ---"
p "Computing tsvector at query time rescans the full text every time."
p "Store it in a column so the GIN index can speed up lookups."

pe "ysqlsh -h 127.0.0.1 -c \"ALTER TABLE articles ADD COLUMN tsv tsvector;\""

pe "ysqlsh -h 127.0.0.1 -c \"
UPDATE articles
SET    tsv = to_tsvector('english', title || ' ' || body);\""

pe "ysqlsh -h 127.0.0.1 -c \"CREATE INDEX idx_articles_tsv ON articles USING ybgin(tsv);\""

p ""
p "Single-term search now hits the GIN index — no sequential scan."
pe "ysqlsh -h 127.0.0.1 -c \"EXPLAIN SELECT id, title FROM articles WHERE tsv @@ to_tsquery('english', 'distribute');\""

pe "ysqlsh -h 127.0.0.1 -c \"
SELECT id, title
FROM   articles
WHERE  tsv @@ to_tsquery('english', 'distribute')
ORDER BY id;\""

p ""
p "YugabyteDB ybgin note: single-term lookups use the index."
p "Multi-term AND/OR fall back to sequential scan — design queries accordingly."

# ── Scene 9: Auto-update trigger ─────────────────────────────────────────────

p ""
p "--- Part 8: Keep tsvector current with a trigger ---"
p "New and updated rows should automatically populate tsv."

pe "ysqlsh -h 127.0.0.1 -c \"
CREATE TRIGGER tsvupdate
BEFORE INSERT OR UPDATE ON articles
FOR EACH ROW EXECUTE FUNCTION
  tsvector_update_trigger(tsv, 'pg_catalog.english', title, body);\""

pe "ysqlsh -h 127.0.0.1 -c \"
INSERT INTO articles (title, author, body, published)
VALUES (
  'PITR and time travel queries for forensic audits',
  'Test Author',
  'Point-in-time recovery restores databases to any prior moment. Time travel queries audit historical state without a full restore. Both features combine for compliance-grade forensics at scale.',
  CURRENT_DATE
);\""

pe "ysqlsh -h 127.0.0.1 -c \"
SELECT id, title, tsv
FROM   articles
WHERE  id = (SELECT MAX(id) FROM articles);\""

p "tsv populated automatically — no application change needed on insert."

# ── Scene 10: Ranked search on indexed column ─────────────────────────────────

p ""
p "--- Part 9: Full production query — index + rank + highlight ---"

pe "ysqlsh -h 127.0.0.1 -c \"
SELECT
  id,
  title,
  ROUND(ts_rank(tsv, websearch_to_tsquery('english', 'database security'))::numeric, 4) AS rank,
  ts_headline('english', body, websearch_to_tsquery('english', 'database security'),
              'MaxWords=15, MinWords=8') AS snippet
FROM   articles
WHERE  tsv @@ websearch_to_tsquery('english', 'database security')
ORDER BY rank DESC;\""

# ── Summary ───────────────────────────────────────────────────────────────────

p ""
p "=== Full-Text Search Summary ==="
p "  tsvector                     → parsed, stemmed document representation"
p "  tsquery / plainto / phrase / websearch → query parsers for every use case"
p "  @@                           → match operator: tsvector @@ tsquery"
p "  ts_rank                      → relevance score — sort results by quality"
p "  ts_headline                  → highlighted snippet with matched terms"
p "  ybgin index                  → fast single-term GIN lookups in YugabyteDB"
p "  tsvector_update_trigger      → auto-maintain tsvector on insert/update"
p ""
p "No external search engine. No ETL pipeline. No separate index cluster."
p "Full-text search lives in the database — consistent, transactional, scalable."

cmd
p ""
