[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/srinivasa-vasu/ybdb-vanguard?devcontainer_path=.devcontainer%2Finit-pubsub-ybdb%2Fdevcontainer.json)

## Pub/Sub change data capture — YugabyteDB → YugabyteDB, without middleware

Two single-node YugabyteDB clusters. The **publisher** exposes its changes through the **PostgreSQL logical replication protocol** (`yboutput` plugin); a Spring Boot **applier** embeds [Debezium's engine](https://debezium.io/documentation/reference/development/engine.html) in its own process, reads the replication slot, and writes each change to the **subscriber**.

There is no Kafka, no Kafka Connect, and no sink connector anywhere in this pipeline — the change events never leave the applier's JVM. That is the whole point of the exercise: for a single-consumer, low-latency sync, the broker is a component you can delete.

| | |
|---|---|
| **Publisher** (source) | `127.0.0.1:5433` — seeded with `customers`, `products`, `orders` |
| **Subscriber** (sink) | `127.0.0.11:5433` — same schema, zero rows |
| **Applier** | JVM process; source from [`srinivasa-vasu/spring-boot-cdc-stream`](https://github.com/srinivasa-vasu/spring-boot-cdc-stream/tree/feat/cdc-txn-apply), cloned and built at container create |
| **Config** | [`application-lab.yml`](application-lab.yml) — edit it, restart the applier, done |

**Quick start:** Five terminals open automatically:
- **`pubsub-demo`** — guided demo: run `bash prompt.sh` for the full walkthrough
- **`pubsub-ws`** — Workshop shell for the manual commands below
- **`ysql-pub`** — YSQL shell on the publisher
- **`ysql-sub`** — YSQL shell on the subscriber
- **`ysql`** — general YSQL shell (`127.0.0.1`, the publisher)

## Workshop

> Use the **`pubsub-ws`** terminal — it opens automatically when the container starts. The **`pubsub-demo`** terminal is for the guided walkthrough. All commands below run from the `init-pubsub-ybdb` directory, which is where both shells start.

---

### The starting state

The publisher holds the seeded data:

```bash
ysqlsh -h $SRC_HOST -c "SELECT 'customers' AS table_name, COUNT(*) FROM $SCHEMA.customers UNION ALL SELECT 'products', COUNT(*) FROM $SCHEMA.products UNION ALL SELECT 'orders', COUNT(*) FROM $SCHEMA.orders ORDER BY 1;"
```

The subscriber has the **same schema and no rows**. Its schema was created out of band, by the startup script loading the same [`schema.sql`](schema.sql) on both sides — this pipeline replicates data and issues no DDL, ever:

```bash
ysqlsh -h $TAR_HOST -c "SELECT 'customers' AS table_name, COUNT(*) FROM $SCHEMA.customers UNION ALL SELECT 'products', COUNT(*) FROM $SCHEMA.products UNION ALL SELECT 'orders', COUNT(*) FROM $SCHEMA.orders ORDER BY 1;"
```

Replica identity on the publisher — `f` = `FULL`, so `UPDATE` and `DELETE` events carry the previous values of every column, not just the key:

```bash
ysqlsh -h $SRC_HOST -c "SELECT relname, relreplident FROM pg_class WHERE relname IN ('customers','products','orders') ORDER BY relname;"
```

No replication slot yet — nothing is being captured:

```bash
ysqlsh -h $SRC_HOST -c "SELECT slot_name, plugin, slot_type, active FROM pg_replication_slots;"
```

---

### What the applier is configured to do

The capture side — which slot, which plugin, which tables:

```bash
grep -E '^[[:space:]]+(plugin-name|replication-slot|publication-name|table-list|snapshot-mode|provide-transaction-metadata):' application-lab.yml
```

The apply side — commit granularity and loop prevention:

```bash
grep -E '^[[:space:]]+(enable-transaction-boundary|transactions-per-commit|batch-size|apply-state-table|apply-origin-name|ignore-replicated-changes):' application-lab.yml
```

Read the whole file when you have a minute — every setting is commented with why it is set the way it is.

---

### Start the applier

Creating the replication slot is what establishes the snapshot's consistent point, so this single command is what starts the pipeline:

```bash
bash applier.sh start
```

`applier.sh` is a thin wrapper around `java -jar`; it waits for the Spring context to report started and prints the log path. Other subcommands: `stop`, `restart`, `status`, `logs [n]`, `tail`.

The slot and publication are created by the connector, on the publisher:

```bash
ysqlsh -h $SRC_HOST -c "SELECT slot_name, plugin, slot_type, active FROM pg_replication_slots;"
ysqlsh -h $SRC_HOST -c "SELECT pubname, puballtables FROM pg_publication;"
```

Only the three captured tables are in the publication — the offset table is deliberately excluded, so the pipeline never captures its own bookkeeping:

```bash
ysqlsh -h $SRC_HOST -c "SELECT schemaname, tablename FROM pg_publication_tables WHERE pubname = '$PUBLICATION' ORDER BY tablename;"
```

---

### Initial snapshot

Every existing row of every captured table is read once, before streaming starts. Watch the subscriber fill up:

```bash
watch -n 1 "ysqlsh -h $TAR_HOST -tAc \"SELECT 'customers ' || COUNT(*) FROM $SCHEMA.customers UNION ALL SELECT 'products  ' || COUNT(*) FROM $SCHEMA.products UNION ALL SELECT 'orders    ' || COUNT(*) FROM $SCHEMA.orders;\""
```

Press `Ctrl-C` once it reads 200 / 50 / 500, then confirm the two sides agree:

```bash
ysqlsh -h $TAR_HOST -c "SELECT 'customers' AS table_name, COUNT(*) FROM $SCHEMA.customers UNION ALL SELECT 'products', COUNT(*) FROM $SCHEMA.products UNION ALL SELECT 'orders', COUNT(*) FROM $SCHEMA.orders ORDER BY 1;"
```

Spot-check a snapshotted row — `NUMERIC` and `TIMESTAMPTZ` survive the round trip:

```bash
ysqlsh -h $TAR_HOST -c "SELECT id, sku, name, price, in_stock FROM $SCHEMA.products WHERE id IN (1, 25, 50) ORDER BY id;"
```

Two pieces of bookkeeping sit on opposite sides of the pipeline. Debezium's own offset store, on the **publisher** — how far the engine has read:

```bash
ysqlsh -h $SRC_HOST -c "SELECT id, offset_key, record_insert_ts FROM $SCHEMA.$OFFSET_TABLE ORDER BY record_insert_ts DESC LIMIT 3;"
```

The applied-LSN watermark, on the **subscriber** — written inside the same transaction as the rows, so it can never claim more than was committed:

```bash
ysqlsh -h $TAR_HOST -c "SELECT slot_name, last_txn_id, last_lsn, applied_at FROM $SCHEMA.$APPLY_STATE_TABLE;"
```

---

### Live CDC — INSERT

Streaming has taken over from the snapshot. A new customer on the publisher:

```bash
ysqlsh -h $SRC_HOST -c "INSERT INTO $SCHEMA.customers (id, name, email, tier) VALUES (9001, 'Ada Lovelace', 'ada@example.com', 'premium');"
```

…arrives on the subscriber:

```bash
ysqlsh -h $TAR_HOST -c "SELECT id, name, email, tier FROM $SCHEMA.customers WHERE id = 9001;"
```

A sparse insert too — `email` and `tier` left NULL:

```bash
ysqlsh -h $SRC_HOST -c "INSERT INTO $SCHEMA.customers (id, name) VALUES (9002, 'Grace Hopper');"

ysqlsh -h $TAR_HOST -c "SELECT id, name, email, tier FROM $SCHEMA.customers WHERE id IN (9001, 9002) ORDER BY id;"
```

---

### Live CDC — UPDATE

Change two columns on one row:

```bash
ysqlsh -h $SRC_HOST -c "UPDATE $SCHEMA.customers SET tier = 'enterprise', email = 'ada@lovelace.io' WHERE id = 9001;"
```

The applier turns it into an upsert keyed on the primary key:

```bash
ysqlsh -h $TAR_HOST -c "SELECT id, name, email, tier FROM $SCHEMA.customers WHERE id = 9001;"
```

A partial update on the sparse row — `name` changes, the NULLs stay NULL:

```bash
ysqlsh -h $SRC_HOST -c "UPDATE $SCHEMA.customers SET name = 'Rear Adm. Grace Hopper' WHERE id = 9002;"

ysqlsh -h $TAR_HOST -c "SELECT id, name, email, tier FROM $SCHEMA.customers WHERE id = 9002;"
```

---

### Live CDC — DELETE

```bash
ysqlsh -h $SRC_HOST -c "DELETE FROM $SCHEMA.customers WHERE id = 9002;"
```

Deleted on the subscriber too — 9001 remains, 9002 is gone:

```bash
ysqlsh -h $TAR_HOST -c "SELECT id, name, tier FROM $SCHEMA.customers WHERE id IN (9001, 9002) ORDER BY id;"
```

---

### Transaction boundaries — all of it, or none of it

With `consumer.enable-transaction-boundary: true` the applier buffers rows until the source transaction's END marker and commits them as one sink transaction. A reader of the subscriber never sees half a publisher transaction.

A small multi-table transaction — an order placed, stock decremented, the customer upgraded — three tables, one commit:

```bash
ysqlsh -h $SRC_HOST -c "BEGIN; INSERT INTO $SCHEMA.orders (id, customer_id, product_id, qty, status) VALUES (9101, 9001, 7, 3, 'placed'); UPDATE $SCHEMA.products SET in_stock = in_stock - 3 WHERE id = 7; UPDATE $SCHEMA.customers SET tier = 'vip' WHERE id = 9001; COMMIT;"

ysqlsh -h $TAR_HOST -c "SELECT o.id AS order_id, o.qty, c.tier AS customer_tier, p.in_stock FROM $SCHEMA.orders o JOIN $SCHEMA.customers c ON c.id = o.customer_id JOIN $SCHEMA.products p ON p.id = o.product_id WHERE o.id = 9101;"
```

Now the observable version. Note the count first:

```bash
_before=$(ysqlsh -h $TAR_HOST -tAc "SELECT COUNT(*) FROM $SCHEMA.orders;" | tr -d '[:space:]')
echo "subscriber orders before: $_before"
```

Insert 2000 rows in **one** transaction, backgrounded, and sample the subscriber's row count in a tight loop while the applier works through it:

```bash
ysqlsh -h $SRC_HOST -c "BEGIN; INSERT INTO $SCHEMA.orders (id, customer_id, product_id, qty, status) SELECT 20000 + g, 1 + (g % 200), 1 + (g % 50), 1 + (g % 4), 'bulk' FROM generate_series(1, 2000) AS g; COMMIT;" &

_samples="$_before"
for _i in $(seq 1 400); do
  _s=$(ysqlsh -h $TAR_HOST -tAc "SELECT COUNT(*) FROM $SCHEMA.orders;" 2>/dev/null | tr -d '[:space:]')
  case " $_samples " in *" $_s "*) : ;; *) _samples="$_samples $_s" ;; esac
  [ "${_s:-0}" -eq "$(( _before + 2000 ))" ] && break
  sleep 0.025
done
echo "distinct counts observed: $_samples"
```

The only counts observed are `$_before` and `$_before + 2000`. Nothing in between — that is the transaction boundary doing its job. Turn `enable-transaction-boundary` off in `application-lab.yml`, `bash applier.sh restart`, and run this again to watch intermediate counts appear.

Confirm the totals match:

```bash
ysqlsh -h $SRC_HOST -c "SELECT 'publisher' AS side, COUNT(*) AS orders FROM $SCHEMA.orders;"
ysqlsh -h $TAR_HOST -c "SELECT 'subscriber' AS side, COUNT(*) AS orders FROM $SCHEMA.orders;"
```

---

### Loop prevention — replication origins

Every row the applier writes is tagged with a [replication origin](https://docs.yugabyte.com/stable/additional-features/change-data-capture/using-logical-replication/advanced-topic/#replication-origins), composed as `<prefix>_<slot>_<lane>` and registered on the subscriber at startup:

```bash
ysqlsh -h $TAR_HOST -c "SELECT roname FROM pg_replication_origin ORDER BY roname;"
```

That tag is the whole mechanism behind two-way replication. A pipeline reading the subscriber sees these rows carrying an origin, and `consumer.ignore-replicated-changes` tells it to discard them — so changes stop instead of ping-ponging forever. An ordinary application write carries no origin at all, which is exactly what marks it as worth replicating.

---

### Pipeline state

The slot is active and its confirmed LSN has advanced:

```bash
ysqlsh -h $SRC_HOST -c "SELECT slot_name, plugin, active, confirmed_flush_lsn FROM pg_replication_slots WHERE slot_name = '$REPL_SLOT';"
```

The applier's own account of what it did:

```bash
grep -iE 'started changeeventapplication|replication origin|snapshot|transaction boundary|apply' $APPLIER_LOG | tail -12 || true

bash applier.sh status
bash applier.sh logs 40
bash applier.sh tail          # follow; Ctrl-C to leave
```

---

### Change the configuration and restart

The whole edit loop is one file:

```bash
code application-lab.yml      # or: vi application-lab.yml
bash applier.sh restart
```

Things worth trying:

| Change | What you should see |
|---|---|
| `consumer.enable-transaction-boundary: false` | the bulk-insert sampler starts catching intermediate counts |
| `consumer.transactions-per-commit: 10` | fewer, larger sink commits; still never a partial transaction |
| `consumer.batch-size: 50` | more, smaller JDBC batches during the snapshot |
| `consumer.unknown-columns: fail` | add a column on the publisher only, and the applier refuses the table instead of skipping the column |
| `consumer.apply-origin-name:` (blank) | writes stop being tagged; `pg_replication_origin` on the subscriber gains no new row on restart |

---

### Cleanup

```bash
bash applier.sh stop

ysqlsh -h $SRC_HOST -c "SELECT pg_drop_replication_slot('$REPL_SLOT');"
ysqlsh -h $SRC_HOST -c "DROP PUBLICATION IF EXISTS $PUBLICATION;"
ysqlsh -h $SRC_HOST -c "DROP TABLE IF EXISTS $SCHEMA.$OFFSET_TABLE;"
ysqlsh -h $TAR_HOST -c "DROP TABLE IF EXISTS $SCHEMA.$APPLY_STATE_TABLE;"
```

> Drop the slot **before** dropping or recreating any captured table. YugabyteDB does not support `DROP TABLE` or `TRUNCATE` on a table once a slot covering it exists, and a table dropped from a filtered publication is not re-added automatically when it is recreated.

Re-running `bash prompt.sh` does all of this for you and re-seeds both sides, so the demo is repeatable.

---

### Key notes

- **A primary key is mandatory.** YugabyteDB CDC does not support tables without one, and the applier needs a unique constraint to target its upserts (`ON CONFLICT`) and deletes at. The applier checks this up front, per table, and halts with a readable message rather than letting PostgreSQL report `42P10` against SQL that is perfectly well formed.
- **`plugin.name: yboutput`** is YugabyteDB's native logical replication output plugin. Do not use `pgoutput` with the YugabyteDB connector.
- **Replica identity is fixed at slot creation.** The publisher starts with `ysql_yb_default_replica_identity=FULL`, so tables get `FULL` when they are created. An `ALTER TABLE ... REPLICA IDENTITY` after the slot exists has no effect on that slot — you would have to drop and recreate it.
- **No DDL is replicated, deliberately.** Logical decoding emits no DDL events, so the only way to infer a schema change would be to diff each event's schema against the sink — an inference that cannot tell a rename from a drop-plus-add and cannot backfill a new column with the source's default. Migrate the subscriber *before* the publisher starts sending the new column. `consumer.unknown-columns: skipIfNull` (the default) tolerates the gap while the column is null and stops the pipeline on the first non-null value, so nothing is lost silently.
- **Adding a table to the capture set gets streaming only.** An existing slot never backfills rows a table already holds, and neither `snapshot.mode: initial` nor `signal.data.collection` changes that — the snapshot point was established when the slot was created, and incremental snapshots are not supported against YugabyteDB logical replication. Backfilling an already-populated table needs a *second* deployment with its own slot, publication and offset table. Add the table to the main pipeline first, then start the backfill slot: overlap is harmless because every statement is idempotent, but a gap is not.
- **Do not run DDL** between slot creation and the end of the last table's snapshot.
- **The apply path is single-threaded on purpose.** The slot already delivers changes in commit order and the embedded engine invokes the consumer on one thread, so concurrency on the apply side would only discard a guarantee that already exists. Throughput comes from batching and `transactions-per-commit`, not parallelism.
- **The apply pool is pinned to one connection.** A replication origin can be held by only one session at a time, and the tagged session must be the one the transaction runs on. A second, untagged pool handles schema metadata reads so they do not queue behind row applies.
- **`consumer.skip-applied-lsn` is off**, and should stay off here: a YugabyteDB slot's LSNs restart low when the slot is recreated, which would make every new transaction look already-applied. Replay is safe without it because every generated statement is idempotent.
- **Replication origins are an Early Access feature** in YugabyteDB (2025.2.1+). If you pin an older build, blank `consumer.apply-origin-name` in `application-lab.yml` to disable tagging.
- **YugabyteDB 2024.1.1 or later** is required for the `yboutput` plugin.
