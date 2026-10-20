[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/srinivasa-vasu/ybdb-vanguard?devcontainer_path=.devcontainer%2Finit-pubsub-bidir-ybdb%2Fdevcontainer.json)

## Two-way pub/sub CDC — YugabyteDB ⇄ YugabyteDB

Two YugabyteDB sites, each **simultaneously a publisher and a subscriber**. Two applier lanes run as separate JVMs with [Debezium's embedded engine](https://debezium.io/documentation/reference/development/engine.html) — one reading site A's replication slot and writing to B, the other doing the reverse. No Kafka, no coordination between the lanes.

Two-way replication is just two one-way pipelines pointed at each other. Everything interesting follows from that: what stops a change circulating forever, and what happens when both sites write the same row.

> A companion to [`init-pubsub-ybdb`](../init-pubsub-ybdb/README.md), the one-way exercise. Start there if you have not — it covers snapshots, transaction-boundary apply, and the applier's configuration surface. This exercise assumes them and focuses on **loop prevention, conflict resolution, and bootstrapping an active-active topology**.

| | |
|---|---|
| **Site A** | `127.0.0.1:5433` — owns `orders` ids `1000-1999` |
| **Site B** | `127.0.0.11:5433` — owns `orders` ids `2000-2999` |
| **Lane `a2b`** | slot `a2b_slot` on A → writes B, tags `atob_a2b_slot_1` · [`application-a2b.yml`](application-a2b.yml) |
| **Lane `b2a`** | slot `b2a_slot` on B → writes A, tags `btoa_b2a_slot_1` · [`application-b2a.yml`](application-b2a.yml) |

**Quick start:** Five terminals open automatically:
- **`bidir-demo`** — guided demo: run `bash prompt.sh` for the full walkthrough
- **`bidir-ws`** — Workshop shell for the manual commands below
- **`ysql-a`** — YSQL shell on site A
- **`ysql-b`** — YSQL shell on site B
- **`ysql`** — general YSQL shell (`127.0.0.1`, site A)

---

### What the schema does and does not carry

There is **no "which site wrote this" column**. Tagging every row with its writer would mean reshaping every table in the database to suit the replication topology, and making the application maintain it on every write. Write ownership is a routing rule that lives *outside* the data — here, each site owns a disjoint range of order ids, and nothing in the schema says so.

The **timestamp column is different**. `orders.last_modified` and `stock.updated_at` are columns these tables would carry anyway, and that is exactly why last-writer-wins can use them: the column is *in the row*, so a local write maintains it just as a replicated write does, and the comparison always reads the row's real current version. A version store the pipeline owned on the side would be blind to direct local writes and would need a trigger on every table to close that gap.

The two tables name it differently on purpose — `consumer.conflict-columns` lists candidates and each table is matched independently.

---

### How the loop is broken

1. An application writes to A. The write carries **no** replication origin.
2. Lane `a2b` captures it and applies it to B **on a session tagged with origin `atob_a2b_slot_1`**, so the row lands in B's WAL carrying that origin.
3. Lane `b2a` reads B's WAL, sees the change carries an origin, and **discards it**.

The rule each lane applies is `consumer.ignore-replicated-changes: true` — *discard every change that carries any origin at all*. An application write has none; a replication apply has one. Neither lane needs to know the other's origin name, and neither config has to be kept in step with the other.

### How conflicts are resolved

Loop prevention is **not** convergence. With `conflict-resolution: none`, two sites writing the same key concurrently end up holding different values permanently — each applies the other's change last, and no further events exist to reconcile them.

`conflict-resolution: timestamp` applies a change only when the sink row is **older**, comparing the timestamp column the table already has. The guard becomes part of the statement:

```sql
DO UPDATE SET ... WHERE "stock"."updated_at" < EXCLUDED."updated_at"
```

Two consequences worth knowing before you rely on it:

- **The application must set that column on every `UPDATE`.** A `DEFAULT now()` fires on `INSERT` only. An update that forgets it leaves the row's version stale and the guard will reject changes it should have accepted.
- **Equal timestamps would diverge** if left alone, each side rejecting the other and keeping its own. `conflict-tiebreak: nodeId` settles it with a rule both sides evaluate to the same answer — the change from the higher node id wins. The ids are mirrored between the lanes, so exactly one lane accepts a tie. Identical ids are rejected at startup.

---

## Workshop

> Use the **`bidir-ws`** terminal — it opens automatically when the container starts. The **`bidir-demo`** terminal is for the guided walkthrough. All commands run from the `init-pubsub-bidir-ybdb` directory, which is where both shells start.

---

### The starting state

Both sites start byte-identical — same rows, same versions:

```bash
ysqlsh -h $A_HOST -c "SELECT 'site-A' AS site, (SELECT COUNT(*) FROM $SCHEMA.orders) AS orders, (SELECT COUNT(*) FROM $SCHEMA.stock) AS stock, (SELECT MAX(updated_at) FROM $SCHEMA.stock) AS stock_version;"
ysqlsh -h $B_HOST -c "SELECT 'site-B' AS site, (SELECT COUNT(*) FROM $SCHEMA.orders) AS orders, (SELECT COUNT(*) FROM $SCHEMA.stock) AS stock, (SELECT MAX(updated_at) FROM $SCHEMA.stock) AS stock_version;"
```

The seed uses fixed timestamps rather than `now()`: the two sites are seeded by separate statements a moment apart, and under last-writer-wins the starting version is exactly what the first real update is compared against.

Both lanes run `snapshot-mode: never`, so neither copies pre-existing rows — they stream changes only, from the moment their slot is created.

Note what the table does *not* have:

```bash
ysqlsh -h $A_HOST -c "\d $SCHEMA.orders"
```

No site column. Ownership is a routing rule, not data.

---

### The ORIGIN rule that makes loop prevention work

YugabyteDB requires a replication origin to **exist before a slot starts streaming**, or that slot will never report the origin on incoming changes ([issue #30068](https://github.com/yugabyte/yugabyte-db/issues/30068)).

That is awkward here. Each lane creates *its own* origin on *its own sink* at startup — but the origin a lane needs to **see** belongs to the *other* lane, on the *other* cluster. Start the lanes one after another and the second lane's origin gets created after the first lane's slot already exists, so the first lane's loop filter silently never matches, and you have an unbroken loop with no error anywhere.

So both origins are created up front by the startup script, before either slot exists:

```bash
ysqlsh -h $A_HOST -c "SELECT 'site-A' AS site, roname FROM pg_replication_origin ORDER BY roname;"
ysqlsh -h $B_HOST -c "SELECT 'site-B' AS site, roname FROM pg_replication_origin ORDER BY roname;"
```

No slots exist yet on either site:

```bash
ysqlsh -h $A_HOST -c "SELECT slot_name, plugin, active FROM pg_replication_slots;"
```

---

### The two lane configs

Every lane identity differs between the two files. Sharing any of them would corrupt the other lane's bookkeeping, and a shared origin prefix would additionally make the second lane fail to claim it with `55006 object_in_use`:

```bash
grep -hE '^[[:space:]]+(hostname|replication-slot|publication-name|offset-storage-jdbc-table|apply-state-table|apply-origin-name):' application-a2b.yml application-b2a.yml
```

Each lane also binds its own HTTP port (`server.port`, 8081 and 8082) — two JVMs, and Spring Boot starts Tomcat even though the applier exposes no endpoints at all. Without distinct ports the second lane dies with `Port 8080 was already in use`.

The rule that breaks the loop, set on both lanes:

```bash
grep -hE '^[[:space:]]+ignore-replicated-changes:' application-a2b.yml application-b2a.yml
```

And the rule that makes the two sites agree when they write the same row:

```bash
grep -hE '^[[:space:]]+(conflict-resolution|conflict-columns|conflict-tiebreak|conflict-node-id|conflict-peer-id|conflict-log|conflict-log-table):' application-a2b.yml application-b2a.yml
```

Note the node ids are mirrored — `node`/`peer` here is `peer`/`node` there.

---

### Start both lanes

```bash
bash applier.sh start both
```

`applier.sh` takes an action and an optional lane (`a2b`, `b2a`, or `both`, the default): `start`, `stop`, `restart`, `status`, `logs <lane> [n]`, `tail <lane>`.

Each lane announces its rules at startup:

```bash
grep -hE 'Loop prevention|Conflict log table' $A2B_LOG $B2A_LOG || true
```

One slot per site — each site is read by the lane that publishes it:

```bash
ysqlsh -h $A_HOST -c "SELECT 'site-A' AS site, slot_name, plugin, active FROM pg_replication_slots;"
ysqlsh -h $B_HOST -c "SELECT 'site-B' AS site, slot_name, plugin, active FROM pg_replication_slots;"
```

---

### Both directions

Site A owns the orders id range `1000-1999`:

```bash
ysqlsh -h $A_HOST -c "INSERT INTO $SCHEMA.orders (id, item, qty, status) VALUES (1001, 'Anvil', 3, 'placed');"

ysqlsh -h $B_HOST -c "SELECT id, item, qty, status FROM $SCHEMA.orders WHERE id = 1001;"
```

Site B owns `2000-2999`:

```bash
ysqlsh -h $B_HOST -c "INSERT INTO $SCHEMA.orders (id, item, qty, status) VALUES (2001, 'Rocket Skates', 1, 'placed');"

ysqlsh -h $A_HOST -c "SELECT id, item, qty, status FROM $SCHEMA.orders WHERE id = 2001;"
```

Both sites now hold both orders:

```bash
ysqlsh -h $A_HOST -c "SELECT 'site-A' AS site, id, item FROM $SCHEMA.orders WHERE id IN (1001, 2001) ORDER BY id;"
ysqlsh -h $B_HOST -c "SELECT 'site-B' AS site, id, item FROM $SCHEMA.orders WHERE id IN (1001, 2001) ORDER BY id;"
```

---

### Loop detection

Row 1001 was written on A with no origin, applied to B tagged `atob_a2b_slot_1`, then read straight back by the `b2a` lane out of B's WAL. That lane logs the first time it sees a tag arrive — direct proof the origin survived the round trip through the WAL:

```bash
grep -h 'First change event carrying replication origin' $A2B_LOG $B2A_LOG || true
```

And what it did with it:

```bash
grep -h 'Discarding change from ignored origin' $A2B_LOG $B2A_LOG || true
```

Now make it a measurement. The discard counter only logs every 10,000 rows, so push it past that threshold — 12,000 rows inserted on A in one transaction, each applied to B exactly once, echoed back, and discarded:

```bash
ysqlsh -h $A_HOST -c "INSERT INTO $SCHEMA.orders (id, item, qty, status) SELECT 1000000 + g, 'Bulk ' || g, 1, 'placed' FROM generate_series(1, $LOOP_PROOF_ROWS) AS g;"
```

Watch site B catch up, then confirm both sides hold the same count — applied once, not repeatedly:

```bash
watch -n 1 "ysqlsh -h $B_HOST -tAc \"SELECT COUNT(*) FROM $SCHEMA.orders;\""

ysqlsh -h $A_HOST -tAc "SELECT 'site-A orders: ' || COUNT(*) FROM $SCHEMA.orders;"
ysqlsh -h $B_HOST -tAc "SELECT 'site-B orders: ' || COUNT(*) FROM $SCHEMA.orders;"
```

The `b2a` lane's discard counter, now past its logging threshold:

```bash
grep -h 'Discarding change from ignored origin' $B2A_LOG | tail -3 || true
```

Wait and re-count. In an unbroken loop these numbers would keep climbing and the slots would never go quiet:

```bash
for i in 1 2 3; do
  sleep 5
  echo "t+$((i*5))s  A: $(ysqlsh -h $A_HOST -tAc "SELECT COUNT(*) FROM $SCHEMA.orders;" | tr -d '[:space:]')  B: $(ysqlsh -h $B_HOST -tAc "SELECT COUNT(*) FROM $SCHEMA.orders;" | tr -d '[:space:]')"
done
```

---

### Both sites write the same rows → convergence

Stop both lanes first, so the outcome is deterministic rather than a race. This is a network partition in miniature:

```bash
bash applier.sh stop both
```

Site A updates all five SKUs. Note `updated_at` is set explicitly — a `DEFAULT now()` fires on `INSERT` only:

```bash
ysqlsh -h $A_HOST -c "UPDATE $SCHEMA.stock SET qty = 111, updated_at = now();"
```

Wait a couple of seconds, then site B updates the same five rows to a different value:

```bash
ysqlsh -h $B_HOST -c "UPDATE $SCHEMA.stock SET qty = 999, updated_at = now();"
```

While replication is down the sites disagree, which is unsurprising:

```bash
ysqlsh -h $A_HOST -c "SELECT 'site-A' AS reading_from, sku, qty, updated_at FROM $SCHEMA.stock ORDER BY sku LIMIT 3;"
ysqlsh -h $B_HOST -c "SELECT 'site-B' AS reading_from, sku, qty, updated_at FROM $SCHEMA.stock ORDER BY sku LIMIT 3;"
```

Heal the partition — each site's five changes are delivered to the other:

```bash
bash applier.sh start both
```

Each table is guarded by the timestamp column it actually has, detected per table from metadata the applier was already reading:

```bash
grep -h 'Conflict resolution on' $A2B_LOG $B2A_LOG | sort -u || true
```

Give it a few seconds, then the point of the whole exercise — both sites **agree**, on B's later value:

```bash
ysqlsh -h $A_HOST -c "SELECT 'site-A' AS reading_from, sku, qty, updated_at FROM $SCHEMA.stock ORDER BY sku;"
ysqlsh -h $B_HOST -c "SELECT 'site-B' AS reading_from, sku, qty, updated_at FROM $SCHEMA.stock ORDER BY sku;"
```

Site A took B's change because A's row was older. Site B **rejected** A's change because B's row was already newer.

### The edits that lost

Five edits made on site A were discarded. That is a real decision about somebody's write, so with `conflict-log: true` it is recorded rather than merely logged:

```bash
ysqlsh -h $B_HOST -c "SELECT table_name, row_key, incoming_version, reason, source_origin FROM $SCHEMA.$A2B_CONFLICT_LOG ORDER BY rejected_at;"
```

The full rejected payload is kept too, so the edit can be reconciled by hand:

```bash
ysqlsh -h $B_HOST -c "SELECT row_key, payload FROM $SCHEMA.$A2B_CONFLICT_LOG ORDER BY rejected_at LIMIT 2;"
```

Site A's conflict log is empty — nothing arriving there lost:

```bash
ysqlsh -h $A_HOST -tAc "SELECT 'site-A rejected rows: ' || COUNT(*) FROM $SCHEMA.$B2A_CONFLICT_LOG;"
```

This is a conflict **log**, not a dead-letter queue. Nothing in it should be replayed — last-writer-wins already decided. It exists so that "someone's edit was discarded" is a queryable fact rather than a line in a log file.

---

### Reproducing divergence  ⚠

To see what the timestamp guard is buying, turn it off and repeat the same sequence:

```bash
# 1. Disable conflict resolution on BOTH lanes
sed -i 's/^  conflict-resolution: timestamp/  conflict-resolution: none/' application-a2b.yml application-b2a.yml
bash applier.sh restart both

# 2. Same partitioned writes as before
bash applier.sh stop both
ysqlsh -h $A_HOST -c "UPDATE $SCHEMA.stock SET qty = 111, updated_at = now();"
sleep 2
ysqlsh -h $B_HOST -c "UPDATE $SCHEMA.stock SET qty = 999, updated_at = now();"
bash applier.sh start both
sleep 15

# 3. Both changes replicated — and the sites now hold DIFFERENT values, swapped
ysqlsh -h $A_HOST -c "SELECT 'site-A' AS reading_from, sku, qty FROM $SCHEMA.stock ORDER BY sku LIMIT 3;"
ysqlsh -h $B_HOST -c "SELECT 'site-B' AS reading_from, sku, qty FROM $SCHEMA.stock ORDER BY sku LIMIT 3;"

# 4. Restore
sed -i 's/^  conflict-resolution: none/  conflict-resolution: timestamp/' application-a2b.yml application-b2a.yml
bash applier.sh restart both
```

Nothing failed in step 3. Every change was captured, shipped and applied exactly once — each site simply applied the peer's write on top of its own, so the values ended up swapped. Replication working perfectly does not imply convergence.

---

### The pattern that avoids conflicts entirely: disjoint ownership

Last-writer-wins *resolves* a conflict; it does not make the losing edit un-happen. Better to make collisions impossible. Give every row one owning site — here by id range, with nothing in the schema to say so. Both sites insert into their own range at the same time:

```bash
ysqlsh -h $A_HOST -c "INSERT INTO $SCHEMA.orders (id, item, qty, status) SELECT 1100 + g, 'A-item ' || g, 1, 'placed' FROM generate_series(1, 50) AS g;" & ysqlsh -h $B_HOST -c "INSERT INTO $SCHEMA.orders (id, item, qty, status) SELECT 2100 + g, 'B-item ' || g, 1, 'placed' FROM generate_series(1, 50) AS g;" & wait
```

Both sites converge on all 100 rows, 50 from each writer:

```bash
ysqlsh -h $A_HOST -c "SELECT CASE WHEN id < 2000 THEN 'site-A range' ELSE 'site-B range' END AS written_by, COUNT(*) FROM $SCHEMA.orders WHERE id BETWEEN 1101 AND 2150 GROUP BY 1 ORDER BY 1;"
ysqlsh -h $B_HOST -c "SELECT CASE WHEN id < 2000 THEN 'site-A range' ELSE 'site-B range' END AS written_by, COUNT(*) FROM $SCHEMA.orders WHERE id BETWEEN 1101 AND 2150 GROUP BY 1 ORDER BY 1;"
```

No conflicts arose, so no timestamps were compared and nothing was rejected:

```bash
ysqlsh -h $B_HOST -tAc "SELECT 'rejected rows on site B: ' || COUNT(*) FROM $SCHEMA.$A2B_CONFLICT_LOG;"
```

Ways to partition ownership in practice: an id range or sequence offset per site (as here), routing by a `region` the application already knows, or sharding on a natural key that is already geographic. What matters is that the assignment is decided *outside* the database and is stable — no column required.

---

### Pipeline state

Each site's watermark records what the lane writing **into** it has committed:

```bash
ysqlsh -h $A_HOST -c "SELECT 'site-A' AS site, slot_name, last_lsn, applied_at FROM $SCHEMA.$B2A_APPLY_STATE;"
ysqlsh -h $B_HOST -c "SELECT 'site-B' AS site, slot_name, last_lsn, applied_at FROM $SCHEMA.$A2B_APPLY_STATE;"
```

Both lanes:

```bash
bash applier.sh status
```

---

### Watching a real replication loop  ⚠

The most convincing way to understand the origin filter is to switch it off. **This produces an unbounded loop that will not stop on its own** — the same rows circulate between the sites indefinitely, burning CPU and growing WAL. Do it deliberately, and stop it yourself.

Turning it off on **one** lane is safe: the other lane still filters, so the loop still closes. You need both lanes unfiltered to see it run.

```bash
# 1. Disable the filter on BOTH lanes
sed -i 's/^  ignore-replicated-changes: true/  ignore-replicated-changes: false/' application-a2b.yml application-b2a.yml
bash applier.sh restart both

# 2. Each lane now warns that it will replay its peer's applies
grep -h 'no origin filter is configured' $A2B_LOG $B2A_LOG || true

# 3. One single update is enough
ysqlsh -h $A_HOST -c "UPDATE $SCHEMA.stock SET qty = 42, updated_at = now() WHERE sku = 'SKU-002';"

# 4. Watch the slots stay busy and the LSNs keep advancing, forever
for i in $(seq 1 6); do
  sleep 5
  ysqlsh -h $A_HOST -tAc "SELECT 'A confirmed_flush_lsn ' || confirmed_flush_lsn FROM pg_replication_slots WHERE slot_name = '$A2B_SLOT';"
  ysqlsh -h $B_HOST -tAc "SELECT 'B confirmed_flush_lsn ' || confirmed_flush_lsn FROM pg_replication_slots WHERE slot_name = '$B2A_SLOT';"
done

# 5. STOP IT, and restore the filter
bash applier.sh stop both
sed -i 's/^  ignore-replicated-changes: false/  ignore-replicated-changes: true/' application-a2b.yml application-b2a.yml
bash applier.sh start both
```

Interestingly the row values still converge — every statement is an idempotent upsert by key, and with the timestamp guard on, the circulating change stops changing anything almost immediately. What runs away is the *work*. That is the failure mode to recognise: a two-way topology with broken loop prevention looks healthy in the data and pathological in the metrics.

---

### The `ignore-origins` variant

`ignore-replicated-changes: true` discards changes carrying *any* origin. That is the right rule for a simple A⇄B pair, but it also stops changes **cascading**: in an A→B→C chain, C never sees A's changes, because by the time they are in B they carry B's origin.

When you need to forward some origins and filter others, name the peer's origin *family* instead:

```yaml
# in application-a2b.yml
ignore-replicated-changes: false
ignore-origins: [btoa_b2a_slot]
```

Note what is named: `btoa_b2a_slot`, the **family** (`<prefix>_<slot>`), not the full origin `btoa_b2a_slot_1`. Entries are matched as **prefixes**, so the filter survives the peer adding lanes — and slot names change more often than you would like here, because a slot must be recreated for a replica-identity change to take effect.

Apply it and confirm the lane reports the new rule:

```bash
bash applier.sh restart a2b
grep -h 'Loop prevention' $A2B_LOG || true
```

---

### Cleanup

```bash
bash applier.sh stop both

ysqlsh -h $A_HOST -c "SELECT pg_drop_replication_slot('$A2B_SLOT');"
ysqlsh -h $B_HOST -c "SELECT pg_drop_replication_slot('$B2A_SLOT');"
ysqlsh -h $A_HOST -c "DROP PUBLICATION IF EXISTS $A2B_PUB;"
ysqlsh -h $B_HOST -c "DROP PUBLICATION IF EXISTS $B2A_PUB;"
ysqlsh -h $A_HOST -c "DROP TABLE IF EXISTS $SCHEMA.$A2B_OFFSET_TABLE;"
ysqlsh -h $B_HOST -c "DROP TABLE IF EXISTS $SCHEMA.$B2A_OFFSET_TABLE;"
ysqlsh -h $B_HOST -c "DROP TABLE IF EXISTS $SCHEMA.$A2B_APPLY_STATE;"
ysqlsh -h $A_HOST -c "DROP TABLE IF EXISTS $SCHEMA.$B2A_APPLY_STATE;"
ysqlsh -h $B_HOST -c "DROP TABLE IF EXISTS $SCHEMA.$A2B_CONFLICT_LOG;"
ysqlsh -h $A_HOST -c "DROP TABLE IF EXISTS $SCHEMA.$B2A_CONFLICT_LOG;"
```

> Leave the **replication origins** in place. They must exist before the slots stream, so dropping them and letting the appliers recreate them would reintroduce the exact ordering bug described above. `bash prompt.sh` resets everything else and deliberately leaves the origins alone.

---

### Key notes

- **Two-way is two one-way lanes.** No distributed protocol, no consensus, no shared state between the lanes. Everything that makes the pair behave sensibly is per-lane configuration.
- **Origins must exist before their slot streams.** The sharpest edge in the exercise, because getting it wrong produces no error — just an unbroken loop. Create every origin a site's slot might observe *before* creating that slot.
- **Loop prevention and conflict resolution are different problems.** Origins stop a change circulating; they say nothing about which of two concurrent writes should win. You need both, and they are configured independently.
- **The timestamp guard needs the application's cooperation.** `DEFAULT now()` fires on insert only. Every `UPDATE` must set the column, or the row's version goes stale and the guard starts rejecting changes it should accept. This is the one requirement the pipeline cannot enforce for you.
- **A table with no time-like column is applied unconditionally**, and says so once in the log. "Some tables are guarded" is a very different posture from "all are", and otherwise invisible — read those startup lines.
- **Ties need mirrored node ids.** Equal timestamps diverge if left alone, and flipping the comparison diverges the other way. `conflict-tiebreak: nodeId` is pairwise only; settling ties among three or more writers needs the originating node in the change event, which the payload does not carry.
- **Deletes compare non-strictly.** The before image carries the version the *deleter* saw, so a sink row that has moved on since holds changes the deleter did not know about and survives.
- **Prefer disjoint ownership over conflict resolution.** LWW picks a winner; it does not make the loser's edit un-happen. Partition write ownership by key so conflicts cannot occur — a design decision, not a setting.
- **Bootstrap identically, with `snapshot-mode: never`.** Snapshot rows carry no origin and would be echoed back. Seed or restore both sides while nothing is writing, then start the lanes.
- **Each lane needs its own everything**: slot, publication, offset table, apply-state table, conflict-log table, origin prefix, HTTP port. The two `application-*.yml` files differ only in lane identity — diff them.
- **Replication origins are Early Access** in YugabyteDB (2025.2.1+). On an older build the origins cannot be created and loop prevention will not work; this exercise requires 2025.2.1 or later.
