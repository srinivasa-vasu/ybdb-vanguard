#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# YugabyteDB pub/sub CDC demo  —  "The Middleware-less Pipeline"
#
# Scenario: two single-node YugabyteDB clusters. The publisher exposes its
# changes through the PostgreSQL logical replication protocol (yboutput plugin);
# a Spring Boot applier embeds Debezium's engine in-process, reads the slot, and
# writes each change to the subscriber. There is no Kafka, no Kafka Connect and
# no sink connector anywhere in this pipeline.
#
#   1. Two clusters, same schema — publisher seeded, subscriber empty
#   2. Start the applier          → replication slot + publication created
#   3. Initial snapshot           → existing rows land on the subscriber
#   4. Live INSERT / UPDATE / DELETE
#   5. Transaction boundaries     → a multi-row source transaction is applied
#                                   atomically, never half-visible
#   6. Replication origins        → how the loop is broken in a two-way setup
#
# Pre-requisites (handled by postCreateCommand + postStartCommand):
#   - publisher on 127.0.0.1, subscriber on 127.0.0.11, both with the schema
#   - the applier built from source into ${APPLIER_HOME}
# ─────────────────────────────────────────────────────────────────────────────

. pscript
set -f  # disable filename expansion — prevents SELECT * glob-expanding in eval $@

# demo-magic's run_cmd() executes with `eval $@` -- UNQUOTED. Bash therefore
# word-splits the command string and rejoins the words with single spaces, so
# any run of two or more consecutive spaces inside a pe "..." argument is
# silently collapsed before the command ever runs. A regex like '^  (foo|bar)'
# arrives as '^ (foo|bar)' and matches nothing, with no error to show for it.
# Never rely on repeated spaces in a pe argument: use [[:space:]]+ in patterns
# and let psql align columns rather than padding string literals by hand.

TYPE_SPEED=70
NO_WAIT=false
DEMO_PROMPT="${GREEN}➜ ${CYAN}\W ${COLOR_RESET}"

SRC_HOST="${SRC_HOST:-127.0.0.1}"
TAR_HOST="${TAR_HOST:-127.0.0.11}"
SCHEMA="${SCHEMA:-public}"
REPL_SLOT="${REPL_SLOT:-pubsub_slot}"
PUBLICATION="${PUBLICATION:-pubsub_pub}"
OFFSET_TABLE="${OFFSET_TABLE:-cdc_offset}"
APPLY_STATE_TABLE="${APPLY_STATE_TABLE:-cdc_apply_state}"
APPLIER_LOG="${APPLIER_LOG:-/tmp/cdc-applier.log}"

# ── Wait for start-pubsub-ybdb.sh to finish before touching anything ─────────
while pgrep -f start-pubsub-ybdb.sh >/dev/null 2>&1; do
    printf "\r  waiting for the pub/sub clusters to start..."
    sleep 2
done

# ── Service readiness gate: both clusters must accept YSQL connections ───────
_svc_wait() {
    local host="$1" label="$2" waited=0
    until (echo >/dev/tcp/"${host}"/5433) 2>/dev/null; do
        printf "\r⏳ waiting for %s..." "${label}"
        sleep 3; waited=$(( waited + 3 ))
        if [ "${waited}" -gt 300 ]; then
            printf "\r❌ %s did not become ready after %ds\n" "${label}" "${waited}"
            exit 1
        fi
    done
    printf "\r✅ %-50s\n" "${label} is ready"
}
_svc_wait "${SRC_HOST}" "Publisher  ${SRC_HOST}:5433"
_svc_wait "${TAR_HOST}" "Subscriber ${TAR_HOST}:5433"

# ── Helpers ──────────────────────────────────────────────────────────────────
_count() {  # _count <host> <table>
    ysqlsh -h "$1" -tAc "SELECT COUNT(*) FROM ${SCHEMA}.$2;" 2>/dev/null | tr -d '[:space:]'
}

# Poll the subscriber until a table reaches an expected row count.
_wait_rows() {  # _wait_rows <table> <expected> [max_wait]
    local table="$1" expected="$2" max_wait="${3:-180}" elapsed=0 seen
    while [ "${elapsed}" -lt "${max_wait}" ]; do
        seen=$(_count "${TAR_HOST}" "${table}")
        if [ "${seen:-0}" -eq "${expected}" ] 2>/dev/null; then
            printf "\r   %-12s %s/%s rows on the subscriber ✅ (%ds)   \n" \
                "${table}" "${seen}" "${expected}" "${elapsed}"
            return 0
        fi
        printf "\r   %-12s %s/%s rows replicated (%ds)..." \
            "${table}" "${seen:-0}" "${expected}" "${elapsed}"
        sleep 1; elapsed=$(( elapsed + 1 ))
    done
    printf "\r   %-12s stalled at %s/%s after %ds — see %s\n" \
        "${table}" "${seen:-0}" "${expected}" "${elapsed}" "${APPLIER_LOG}"
    return 1
}

# Wait until one specific row is visible (or gone) on the subscriber.
_wait_row() {  # _wait_row <table> <predicate> <expected-count> [max_wait]
    local table="$1" predicate="$2" expected="$3" max_wait="${4:-60}" elapsed=0 seen
    while [ "${elapsed}" -lt "${max_wait}" ]; do
        seen=$(ysqlsh -h "${TAR_HOST}" -tAc \
            "SELECT COUNT(*) FROM ${SCHEMA}.${table} WHERE ${predicate};" 2>/dev/null \
            | tr -d '[:space:]')
        [ "${seen:-(-1)}" -eq "${expected}" ] 2>/dev/null && return 0
        sleep 1; elapsed=$(( elapsed + 1 ))
    done
    return 1
}

# ── Quiet reset: leave no state behind from a previous run of this demo ──────
bash applier.sh stop >/dev/null 2>&1 || true
ysqlsh -h "${SRC_HOST}" -q -c "SELECT pg_drop_replication_slot(slot_name) FROM pg_replication_slots WHERE slot_name = '${REPL_SLOT}';" >/dev/null 2>&1 || true
ysqlsh -h "${SRC_HOST}" -q -c "DROP PUBLICATION IF EXISTS ${PUBLICATION};"        >/dev/null 2>&1 || true
ysqlsh -h "${SRC_HOST}" -q -c "DROP TABLE IF EXISTS ${SCHEMA}.${OFFSET_TABLE};"   >/dev/null 2>&1 || true
ysqlsh -h "${TAR_HOST}" -q -c "DROP TABLE IF EXISTS ${SCHEMA}.${APPLY_STATE_TABLE};" >/dev/null 2>&1 || true
# Re-seed both sides so the demo always starts from the same place.
ysqlsh -h "${SRC_HOST}" -q -f schema.sql >/dev/null 2>&1 || true
ysqlsh -h "${TAR_HOST}" -q -f schema.sql >/dev/null 2>&1 || true
ysqlsh -h "${SRC_HOST}" -q -f seed.sql   >/dev/null 2>&1 || true

clear

# ── Scene 1: The two clusters ────────────────────────────────────────────────

p "=== YugabyteDB Pub/Sub CDC: publisher → subscriber, no middleware ==="
p ""
p "Publisher  ${SRC_HOST}:5433   — logical replication source (yboutput plugin)"
p "Subscriber ${TAR_HOST}:5433  — the sink the applier writes to"
p ""
p "The applier is a Spring Boot process with Debezium's engine embedded."
p "No Kafka, no Kafka Connect, no sink connector."
p ""
p "The publisher holds the seeded data:"

pe "ysqlsh -h ${SRC_HOST} -c \"SELECT 'customers' AS table_name, COUNT(*) FROM ${SCHEMA}.customers UNION ALL SELECT 'products', COUNT(*) FROM ${SCHEMA}.products UNION ALL SELECT 'orders', COUNT(*) FROM ${SCHEMA}.orders ORDER BY 1;\""

p ""
p "The subscriber has the SAME schema and NO rows —"
p "created out of band, because this pipeline replicates data and issues no DDL:"

pe "ysqlsh -h ${TAR_HOST} -c \"SELECT 'customers' AS table_name, COUNT(*) FROM ${SCHEMA}.customers UNION ALL SELECT 'products', COUNT(*) FROM ${SCHEMA}.products UNION ALL SELECT 'orders', COUNT(*) FROM ${SCHEMA}.orders ORDER BY 1;\""

p ""
p "Replica identity on the publisher — 'f' = FULL, so UPDATE and DELETE events"
p "carry the previous values of every column, not just the key:"

pe "ysqlsh -h ${SRC_HOST} -c \"SELECT relname, relreplident FROM pg_class WHERE relname IN ('customers','products','orders') ORDER BY relname;\""

p ""
p "No replication slot yet — nothing is being captured:"

pe "ysqlsh -h ${SRC_HOST} -c \"SELECT slot_name, plugin, slot_type, active FROM pg_replication_slots;\""

# ── Scene 2: The applier configuration ───────────────────────────────────────

p ""
p "--- What the applier is configured to do ---"
p ""
p "The capture side — which slot, which plugin, which tables:"

pe "grep -E '^[[:space:]]+(plugin-name|replication-slot|publication-name|table-list|snapshot-mode|provide-transaction-metadata):' application-lab.yml"

p ""
p "The apply side — commit granularity and loop prevention:"

pe "grep -E '^[[:space:]]+(enable-transaction-boundary|transactions-per-commit|batch-size|apply-state-table|apply-origin-name|ignore-replicated-changes):' application-lab.yml"

# ── Scene 3: Start the applier ───────────────────────────────────────────────

p ""
p "--- Starting the applier ---"
p "Creating the slot is what establishes the snapshot's consistent point."

pe "bash applier.sh start"

p ""
p "The slot and publication were created by the connector, on the publisher:"

pe "ysqlsh -h ${SRC_HOST} -c \"SELECT slot_name, plugin, slot_type, active FROM pg_replication_slots;\""

pe "ysqlsh -h ${SRC_HOST} -c \"SELECT pubname, puballtables FROM pg_publication;\""

p ""
p "Only the three captured tables are in the publication — the offset table is"
p "deliberately excluded, so the pipeline never captures its own bookkeeping:"

pe "ysqlsh -h ${SRC_HOST} -c \"SELECT schemaname, tablename FROM pg_publication_tables WHERE pubname = '${PUBLICATION}' ORDER BY tablename;\""

# ── Scene 4: Initial snapshot ────────────────────────────────────────────────

p ""
p "--- Initial snapshot ---"
p "Every existing row of every captured table, read once, before streaming starts."

echo ""
_wait_rows customers 200
_wait_rows products   50
_wait_rows orders    500
echo ""

p "Publisher and subscriber now agree:"

pe "ysqlsh -h ${TAR_HOST} -c \"SELECT 'customers' AS table_name, COUNT(*) FROM ${SCHEMA}.customers UNION ALL SELECT 'products', COUNT(*) FROM ${SCHEMA}.products UNION ALL SELECT 'orders', COUNT(*) FROM ${SCHEMA}.orders ORDER BY 1;\""

p ""
p "Spot-check a snapshotted row — NUMERIC and TIMESTAMPTZ survive the round trip:"

pe "ysqlsh -h ${TAR_HOST} -c \"SELECT id, sku, name, price, in_stock FROM ${SCHEMA}.products WHERE id IN (1, 25, 50) ORDER BY id;\""

p ""
p "Two pieces of bookkeeping, on opposite sides of the pipeline."
p ""
p "Debezium's own offset store, on the publisher — how far the engine has read:"

pe "ysqlsh -h ${SRC_HOST} -c \"SELECT id, offset_key, record_insert_ts FROM ${SCHEMA}.${OFFSET_TABLE} ORDER BY record_insert_ts DESC LIMIT 3;\""

p ""
p "The applied-LSN watermark, on the subscriber — written INSIDE the same"
p "transaction as the rows, so it can never claim more than was committed:"

pe "ysqlsh -h ${TAR_HOST} -c \"SELECT slot_name, last_txn_id, last_lsn, applied_at FROM ${SCHEMA}.${APPLY_STATE_TABLE};\""

# ── Scene 5: Live INSERT ─────────────────────────────────────────────────────

p ""
p "--- Live CDC: INSERT ---"
p "Streaming has taken over from the snapshot. A new customer on the publisher:"

pe "ysqlsh -h ${SRC_HOST} -c \"INSERT INTO ${SCHEMA}.customers (id, name, email, tier) VALUES (9001, 'Ada Lovelace', 'ada@example.com', 'premium');\""

_wait_row customers "id = 9001" 1

p ""
p "…arrives on the subscriber:"

pe "ysqlsh -h ${TAR_HOST} -c \"SELECT id, name, email, tier FROM ${SCHEMA}.customers WHERE id = 9001;\""

p ""
p "A sparse insert too — email and tier left NULL:"

pe "ysqlsh -h ${SRC_HOST} -c \"INSERT INTO ${SCHEMA}.customers (id, name) VALUES (9002, 'Grace Hopper');\""

_wait_row customers "id = 9002" 1

pe "ysqlsh -h ${TAR_HOST} -c \"SELECT id, name, email, tier FROM ${SCHEMA}.customers WHERE id IN (9001, 9002) ORDER BY id;\""

# ── Scene 6: Live UPDATE ─────────────────────────────────────────────────────

p ""
p "--- Live CDC: UPDATE ---"
p "Change two columns on one row:"

pe "ysqlsh -h ${SRC_HOST} -c \"UPDATE ${SCHEMA}.customers SET tier = 'enterprise', email = 'ada@lovelace.io' WHERE id = 9001;\""

_wait_row customers "id = 9001 AND tier = 'enterprise'" 1

p ""
p "The applier turns it into an upsert keyed on the primary key:"

pe "ysqlsh -h ${TAR_HOST} -c \"SELECT id, name, email, tier FROM ${SCHEMA}.customers WHERE id = 9001;\""

p ""
p "A partial update on the sparse row — name changes, the NULLs stay NULL:"

pe "ysqlsh -h ${SRC_HOST} -c \"UPDATE ${SCHEMA}.customers SET name = 'Rear Adm. Grace Hopper' WHERE id = 9002;\""

_wait_row customers "id = 9002 AND name = 'Rear Adm. Grace Hopper'" 1

pe "ysqlsh -h ${TAR_HOST} -c \"SELECT id, name, email, tier FROM ${SCHEMA}.customers WHERE id = 9002;\""

# ── Scene 7: Live DELETE ─────────────────────────────────────────────────────

p ""
p "--- Live CDC: DELETE ---"

pe "ysqlsh -h ${SRC_HOST} -c \"DELETE FROM ${SCHEMA}.customers WHERE id = 9002;\""

_wait_row customers "id = 9002" 0

p ""
p "Deleted on the subscriber too — 9001 remains, 9002 is gone:"

pe "ysqlsh -h ${TAR_HOST} -c \"SELECT id, name, tier FROM ${SCHEMA}.customers WHERE id IN (9001, 9002) ORDER BY id;\""

# ── Scene 8: Transaction boundaries ──────────────────────────────────────────

p ""
p "--- Transaction boundaries: all of it, or none of it ---"
p ""
p "With consumer.enable-transaction-boundary=true the applier buffers rows until"
p "the source transaction's END marker and commits them as one sink transaction."
p "A reader of the subscriber never sees half a publisher transaction."
p ""
p "First, a small multi-table transaction — an order placed, stock decremented,"
p "the customer upgraded — three tables, one commit:"

pe "ysqlsh -h ${SRC_HOST} -c \"BEGIN; INSERT INTO ${SCHEMA}.orders (id, customer_id, product_id, qty, status) VALUES (9101, 9001, 7, 3, 'placed'); UPDATE ${SCHEMA}.products SET in_stock = in_stock - 3 WHERE id = 7; UPDATE ${SCHEMA}.customers SET tier = 'vip' WHERE id = 9001; COMMIT;\""

_wait_row orders "id = 9101" 1

pe "ysqlsh -h ${TAR_HOST} -c \"SELECT o.id AS order_id, o.qty, c.tier AS customer_tier, p.in_stock FROM ${SCHEMA}.orders o JOIN ${SCHEMA}.customers c ON c.id = o.customer_id JOIN ${SCHEMA}.products p ON p.id = o.product_id WHERE o.id = 9101;\""

p ""
p "Now the observable version: 2000 rows in ONE transaction, while a sampler"
p "reads the subscriber's row count in a tight loop."
p ""
p "If the subscriber ever exposed a partial transaction, the sampler would catch"
p "an intermediate count. It should only ever see 'before' or 'after'."

_orders_before=$(_count "${TAR_HOST}" orders)
_orders_after=$(( _orders_before + 2000 ))
p ""
p "Subscriber orders before: ${_orders_before}"

pe "ysqlsh -h ${SRC_HOST} -c \"BEGIN; INSERT INTO ${SCHEMA}.orders (id, customer_id, product_id, qty, status) SELECT 20000 + g, 1 + (g % 200), 1 + (g % 50), 1 + (g % 4), 'bulk' FROM generate_series(1, 2000) AS g; COMMIT;\" &"

# Sample the subscriber while the applier works through the transaction. Each
# sample is its own connection, so this is not a high-frequency probe — but it
# runs for the whole apply, which is what matters.
_samples="${_orders_before}"
for _i in $(seq 1 400); do
    _s=$(ysqlsh -h "${TAR_HOST}" -tAc "SELECT COUNT(*) FROM ${SCHEMA}.orders;" 2>/dev/null | tr -d '[:space:]')
    case " ${_samples} " in
        *" ${_s} "*) : ;;
        *) _samples="${_samples} ${_s}" ;;
    esac
    [ "${_s:-0}" -eq "${_orders_after}" ] 2>/dev/null && break
    sleep 0.025
done
wait 2>/dev/null || true

echo ""
echo "   distinct row counts observed on the subscriber: ${_samples}"
echo "   expected: ${_orders_before} then ${_orders_after} — nothing in between"
echo ""

p "Confirm the totals match:"

pe "ysqlsh -h ${SRC_HOST} -c \"SELECT 'publisher' AS side, COUNT(*) AS orders FROM ${SCHEMA}.orders;\""

pe "ysqlsh -h ${TAR_HOST} -c \"SELECT 'subscriber' AS side, COUNT(*) AS orders FROM ${SCHEMA}.orders;\""

# ── Scene 9: Replication origins ─────────────────────────────────────────────

p ""
p "--- Loop prevention: replication origins ---"
p ""
p "Every row the applier writes is tagged with a replication origin, composed as"
p "<prefix>_<slot>_<lane>. It is registered on the subscriber at startup:"

pe "ysqlsh -h ${TAR_HOST} -c \"SELECT roname FROM pg_replication_origin ORDER BY roname;\""

p ""
p "That tag is the whole mechanism behind two-way replication. A pipeline reading"
p "the subscriber sees these rows carrying an origin, and ignore-replicated-changes"
p "tells it to discard them — so changes stop instead of ping-ponging forever."
p "An ordinary application write carries no origin at all, which is exactly what"
p "marks it as worth replicating."

# ── Scene 10: Pipeline state ─────────────────────────────────────────────────

p ""
p "--- Pipeline state ---"
p ""
p "The slot is active and its confirmed LSN has advanced:"

pe "ysqlsh -h ${SRC_HOST} -c \"SELECT slot_name, plugin, active, confirmed_flush_lsn FROM pg_replication_slots WHERE slot_name = '${REPL_SLOT}';\""

p ""
p "The applier's own account of what it did:"

pe "grep -iE 'started changeeventapplication|replication origin|snapshot|transaction boundary|apply' ${APPLIER_LOG} | tail -12 || true"

p ""
p "Applier process:"

pe "bash applier.sh status"

p ""
p "✅ Pub/Sub CDC pipeline:"
p "  Publisher  : YugabyteDB ${SRC_HOST} — logical replication, yboutput plugin"
p "  Transport  : Debezium embedded engine, in the applier's own process"
p "  Subscriber : YugabyteDB ${TAR_HOST} — upsert by key, delete by key"
p "  Events     : snapshot + INSERT + UPDATE + DELETE, applied in commit order"
p "  Atomicity  : one source transaction → one sink transaction"
p ""
p "Explore further:"
p "  Applier log   : bash applier.sh tail"
p "  Stop / start  : bash applier.sh stop   |   bash applier.sh start"
p "  Change config : edit application-lab.yml, then bash applier.sh restart"
p "  Slot state    : ysqlsh -h ${SRC_HOST} -c 'SELECT * FROM pg_replication_slots;'"
p "  Watermark     : ysqlsh -h ${TAR_HOST} -c 'SELECT * FROM ${SCHEMA}.${APPLY_STATE_TABLE};'"

cmd

p ""
