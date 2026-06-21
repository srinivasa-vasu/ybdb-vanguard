# Full-Text Search

[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/srinivasa-vasu/ybdb-vanguard?devcontainer_path=.devcontainer%2Finit-fts%2Fdevcontainer.json)

SQL-native full-text search in YugabyteDB: stemming, boolean queries, relevance ranking, highlighted snippets, and GIN-indexed lookups — no external search engine required.

---

> **Run queries interactively**: Select any SQL block → **`Ctrl+Shift+Enter`** (Windows/Linux) or **`Cmd+Shift+Enter`** (Mac) → runs in the active terminal.

---

## Running the demo

| Task | What it runs |
|---|---|
| **Terminal → Run Task → `fts-demo`** | "The Search Engine Problem" (`prompt.sh`) |
| **Terminal → Run Task → `ysql`** | YSQL shell for the Workshop section below |

The demo loads the schema and 10 sample articles from `articles.sql` via `ysqlsh -f articles.sql`.

---

## Workshop

> Use the **`ysql`** terminal — it opens automatically when the container starts.

### Part 1 · Why LIKE falls short

```sql
-- Case-sensitive: 'Distributed' is not found
SELECT id, title FROM articles WHERE body LIKE '%distributed%';

-- Leading wildcard prevents any index from helping
EXPLAIN SELECT id, title FROM articles WHERE body LIKE '%distributed%';
-- → Seq Scan on articles
```

---

### Part 2 · tsvector and tsquery basics

`tsvector` is the parsed, stemmed representation of a document. `tsquery` is the parsed form of a search term.

```sql
-- tsvector: stop words removed, words reduced to stems with positions
SELECT to_tsvector('english', 'YugabyteDB scales distributed SQL to millions of transactions');
-- → 'distribut':3 'million':6 'scale':2 'sql':4 'transact':7 'yugabyt':1

-- tsquery: all three produce the same lexeme
SELECT to_tsquery('english', 'distributed');
SELECT to_tsquery('english', 'distributing');
SELECT to_tsquery('english', 'distribution');
-- → 'distribut' (identical — stemmed)
```

---

### Part 3 · Full-text search with @@

```sql
-- Matches distributed, distributing, distribution
SELECT id, title
FROM   articles
WHERE  to_tsvector('english', title || ' ' || body)
       @@ to_tsquery('english', 'distribute');

-- AND
WHERE  to_tsvector('english', title || ' ' || body)
       @@ to_tsquery('english', 'database & security');

-- OR
WHERE  to_tsvector('english', title || ' ' || body)
       @@ to_tsquery('english', 'kafka | replication');

-- NOT
WHERE  to_tsvector('english', title || ' ' || body)
       @@ to_tsquery('english', 'database & !encrypt');
```

---

### Part 4 · User-friendly query parsers

| Function | Input style | Example |
|---|---|---|
| `to_tsquery` | Boolean (`&`, `\|`, `!`) | `'kafka & replication'` |
| `plainto_tsquery` | Plain words (implicit AND) | `'kafka replication'` |
| `phraseto_tsquery` | Adjacent phrase | `'distributed transaction'` |
| `websearch_to_tsquery` | Google-style (`-`, `"..."`) | `'distributed -encryption'` |

```sql
-- Google-style: space = AND, minus = NOT
SELECT id, title
FROM   articles
WHERE  to_tsvector('english', title || ' ' || body)
       @@ websearch_to_tsquery('english', 'distributed database -encryption');

-- Phrase: terms must appear adjacent and in order
WHERE  to_tsvector('english', title || ' ' || body)
       @@ phraseto_tsquery('english', 'distributed transaction');
```

---

### Part 5 · Relevance ranking with ts_rank

`ts_rank` scores a match by how many times the query terms appear and at what positions. Higher is better.

```sql
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
ORDER BY rank DESC;
```

`ts_rank_cd` (cover density) rewards articles where query terms appear close together, which can be better for long documents.

---

### Part 6 · Highlighted snippets with ts_headline

```sql
SELECT
  id,
  title,
  ts_headline(
    'english', body,
    to_tsquery('english', 'distribute | transaction'),
    'MaxWords=20, MinWords=10, ShortWord=3'
  ) AS snippet
FROM articles
WHERE to_tsvector('english', title || ' ' || body)
      @@ to_tsquery('english', 'distribute | transaction');
-- Matched terms are wrapped in <b>...</b>
```

`ts_headline` options:

| Option | Default | Effect |
|---|---|---|
| `MaxWords` | 35 | Max words in a snippet |
| `MinWords` | 15 | Min words in a snippet |
| `ShortWord` | 3 | Words shorter than this are not highlighted |
| `StartSel` / `StopSel` | `<b>` / `</b>` | Highlight markers |
| `HighlightAll` | `false` | Highlight the whole document, not just a snippet |

---

### Part 7 · Persisted tsvector + GIN index

Computing `to_tsvector` at query time reparses the full text on every row. Store it in a column and index it.

```sql
-- Add the column
ALTER TABLE articles ADD COLUMN tsv tsvector;

-- Backfill
UPDATE articles
SET    tsv = to_tsvector('english', title || ' ' || body);

-- Create the GIN index (YugabyteDB uses ybgin)
CREATE INDEX idx_articles_tsv ON articles USING ybgin(tsv);

-- Single-term lookup now uses the index
EXPLAIN SELECT id, title FROM articles WHERE tsv @@ to_tsquery('english', 'distribute');
-- → Index Scan on idx_articles_tsv
```

**YugabyteDB ybgin note**: single-term tsquery lookups use the index. Multi-term AND/OR queries fall back to a sequential scan — split them into single-term indexed lookups and post-filter in the application if index performance is required.

---

### Part 8 · Auto-update trigger

```sql
CREATE TRIGGER tsvupdate
BEFORE INSERT OR UPDATE ON articles
FOR EACH ROW EXECUTE FUNCTION
  tsvector_update_trigger(tsv, 'pg_catalog.english', title, body);
-- Column list at the end: the trigger reads those columns and writes tsv automatically
```

After the trigger is in place, `INSERT` and `UPDATE` statements populate `tsv` without any application-level change.

---

### Part 9 · Full production query pattern

```sql
SELECT
  id,
  title,
  ROUND(ts_rank(tsv, websearch_to_tsquery('english', 'database security'))::numeric, 4) AS rank,
  ts_headline('english', body, websearch_to_tsquery('english', 'database security'),
              'MaxWords=15, MinWords=8') AS snippet
FROM   articles
WHERE  tsv @@ websearch_to_tsquery('english', 'database security')
ORDER BY rank DESC;
```

The pattern:
1. `WHERE tsv @@ ...` — GIN index filters rows
2. `ts_rank(tsv, ...)` — scores the survivors
3. `ts_headline(body, ...)` — generates display snippets
4. `ORDER BY rank DESC` — most relevant first

---

### Part 10 · Inspect text search configuration

```sql
-- List available configurations
SELECT cfgname, cfgparser FROM pg_ts_config ORDER BY cfgname;

-- Show what a configuration does to a string
SELECT * FROM ts_debug('english', 'YugabyteDB distributed transactions scaling');

-- See which text search configurations are available
SELECT * FROM pg_ts_config;
```

---

## Key mental models

```
tsvector
  → parsed, stemmed, stop-word-filtered representation of a document
  → stored once, used for all searches against that document

tsquery
  → parsed search expression, supports &  |  !  <->  (phrase)
  → to_tsquery: explicit operators   plainto_tsquery: implicit AND
  → phraseto_tsquery: adjacency      websearch_to_tsquery: Google-style

@@
  → the match operator: returns true if tsvector matches tsquery

ts_rank(tsvector, tsquery)
  → relevance score (0.0–1.0, higher is better match)
  → use for ORDER BY when you want best-first results

ts_headline(config, text, tsquery [, options])
  → returns a text snippet with matched terms highlighted
  → use for display, not for WHERE filtering

ybgin index (YugabyteDB GIN)
  → fast single-term tsvector lookups
  → multi-term AND/OR fall back to sequential scan — note this limitation

tsvector_update_trigger(column, config, col1, col2, ...)
  → BEFORE INSERT OR UPDATE trigger that auto-populates a tsvector column
```
