#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Two-way YugabyteDB pub/sub demo  —  "Both Ways at Once"
#
# Scenario: two YugabyteDB sites, each simultaneously publisher and subscriber.
# Two applier lanes (A→B and B→A) run as separate JVMs with Debezium's engine
# embedded. No Kafka anywhere. The demo shows:
#
#   1. Both sites start identical; origins pre-created before any slot exists
#   2. Start both lanes           → two slots, two publications, two origins
#   3. A → B and B → A            → writes flow both ways
#   4. LOOP DETECTION             → 12k rows applied once, echoed back, and
#                                   discarded by origin; counts prove it stops
#   5. CONFLICT → CONVERGENCE     → both sites write the same rows; the
#                                   timestamp guard makes them agree, and the
#                                   edits that lost are queryable, not lost
#   6. DISJOINT OWNERSHIP         → ownership as a routing rule, not a column
#
# Pre-requisites (postCreateCommand + postStartCommand):
#   - site A on 127.0.0.1, site B on 127.0.0.11, identical schema + seed
#   - both replication origins already created (see start-pubsub-bidir-ybdb.sh)
#   - the applier jar built into ${APPLIER_HOME}
# ─────────────────────────────────────────────────────────────────────────────

. pscript
set -f  # disable filename expansion — prevents SELECT * glob-expanding in eval $@

# demo-magic's run_cmd() executes with `eval $@` -- UNQUOTED. Bash word-splits
# the command string and rejoins the words with single spaces, so any run of two
# or more consecutive spaces inside a pe "..." argument is silently collapsed
# before the command runs. A regex like '^  (foo|bar)' arrives as '^ (foo|bar)'
# and matches nothing, with no error to show for it. Never rely on repeated
# spaces in a pe argument: use [[:space:]]+ in patterns, and let psql align
# columns rather than padding string literals by hand.

TYPE_SPEED=70
NO_WAIT=false
DEMO_PROMPT="${GREEN}➜ ${CYAN}\W ${COLOR_RESET}"

A_HOST="${A_HOST:-127.0.0.1}"
B_HOST="${B_HOST:-127.0.0.11}"
SCHEMA="${SCHEMA:-public}"
A2B_SLOT="${A2B_SLOT:-a2b_slot}"
B2A_SLOT="${B2A_SLOT:-b2a_slot}"
A2B_PUB="${A2B_PUB:-a2b_pub}"
B2A_PUB="${B2A_PUB:-b2a_pub}"
A2B_ORIGIN="${A2B_ORIGIN:-atob}"
B2A_ORIGIN="${B2A_ORIGIN:-btoa}"
A2B_OFFSET_TABLE="${A2B_OFFSET_TABLE:-cdc_offset_a2b}"
B2A_OFFSET_TABLE="${B2A_OFFSET_TABLE:-cdc_offset_b2a}"
A2B_APPLY_STATE="${A2B_APPLY_STATE:-cdc_apply_state_a2b}"
B2A_APPLY_STATE="${B2A_APPLY_STATE:-cdc_apply_state_b2a}"
A2B_CONFLICT_LOG="${A2B_CONFLICT_LOG:-cdc_conflict_log_a2b}"
B2A_CONFLICT_LOG="${B2A_CONFLICT_LOG:-cdc_conflict_log_b2a}"

A2B_ORIGIN_FULL="${A2B_ORIGIN}_${A2B_SLOT}_1"
B2A_ORIGIN_FULL="${B2A_ORIGIN}_${B2A_SLOT}_1"

A2B_LOG="${A2B_LOG:-/tmp/cdc-applier-a2b.log}"
B2A_LOG="${B2A_LOG:-/tmp/cdc-applier-b2a.log}"

# Enough rows to push the B→A lane's discard counter past its 10,000-row
# logging threshold, so the "discarded N so far" line carries a real number.
LOOP_PROOF_ROWS="${LOOP_PROOF_ROWS:-12000}"

# ── Wait for the startup script, then for both sites ─────────────────────────
while pgrep -f start-pubsub-bidir-ybdb.sh >/dev/null 2>&1; do
    printf "\r  waiting for the two sites to start..."
    sleep 2
done

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
_svc_wait "${A_HOST}" "Site A ${A_HOST}:5433"
_svc_wait "${B_HOST}" "Site B ${B_HOST}:5433"

# ── Helpers ──────────────────────────────────────────────────────────────────
_q() {  # _q <host> <sql>   -> single scalar
    ysqlsh -h "$1" -tAc "$2" 2>/dev/null | tr -d '[:space:]'
}

_count() { _q "$1" "SELECT COUNT(*) FROM ${SCHEMA}.$2;"; }

# Wait until a predicate holds on a site.
_wait_for() {  # _wait_for <host> <sql-scalar> <expected> [max_wait] [label]
    local host="$1" sql="$2" want="$3" max="${4:-60}" label="${5:-}" n=0 got
    while [ "${n}" -lt "${max}" ]; do
        got=$(_q "${host}" "${sql}")
        [ "${got}" = "${want}" ] && {
            [ -n "${label}" ] && printf "\r   %-46s ✅ (%ds)   \n" "${label}" "${n}"
            return 0
        }
        [ -n "${label}" ] && printf "\r   %-46s %s/%s (%ds)..." "${label}" "${got:-?}" "${want}" "${n}"
        sleep 1; n=$(( n + 1 ))
    done
    [ -n "${label}" ] && printf "\r   %-46s stalled at %s (want %s)\n" "${label}" "${got:-?}" "${want}"
    return 1
}

# ── Quiet reset so the demo is repeatable ────────────────────────────────────
# Note what is NOT reset: the replication origins. They must exist before the
# slots stream, so dropping and recreating them here would reintroduce exactly
# the ordering bug the startup script avoids.
bash applier.sh stop both >/dev/null 2>&1 || true
ysqlsh -h "${A_HOST}" -q -c "SELECT pg_drop_replication_slot(slot_name) FROM pg_replication_slots WHERE slot_name = '${A2B_SLOT}';" >/dev/null 2>&1 || true
ysqlsh -h "${B_HOST}" -q -c "SELECT pg_drop_replication_slot(slot_name) FROM pg_replication_slots WHERE slot_name = '${B2A_SLOT}';" >/dev/null 2>&1 || true
ysqlsh -h "${A_HOST}" -q -c "DROP PUBLICATION IF EXISTS ${A2B_PUB};"               >/dev/null 2>&1 || true
ysqlsh -h "${B_HOST}" -q -c "DROP PUBLICATION IF EXISTS ${B2A_PUB};"               >/dev/null 2>&1 || true
ysqlsh -h "${A_HOST}" -q -c "DROP TABLE IF EXISTS ${SCHEMA}.${A2B_OFFSET_TABLE};"  >/dev/null 2>&1 || true
ysqlsh -h "${B_HOST}" -q -c "DROP TABLE IF EXISTS ${SCHEMA}.${B2A_OFFSET_TABLE};"  >/dev/null 2>&1 || true
ysqlsh -h "${B_HOST}" -q -c "DROP TABLE IF EXISTS ${SCHEMA}.${A2B_APPLY_STATE};"   >/dev/null 2>&1 || true
ysqlsh -h "${A_HOST}" -q -c "DROP TABLE IF EXISTS ${SCHEMA}.${B2A_APPLY_STATE};"   >/dev/null 2>&1 || true
ysqlsh -h "${B_HOST}" -q -c "DROP TABLE IF EXISTS ${SCHEMA}.${A2B_CONFLICT_LOG};"  >/dev/null 2>&1 || true
ysqlsh -h "${A_HOST}" -q -c "DROP TABLE IF EXISTS ${SCHEMA}.${B2A_CONFLICT_LOG};"  >/dev/null 2>&1 || true
for _h in "${A_HOST}" "${B_HOST}"; do
    ysqlsh -h "${_h}" -q -f schema.sql >/dev/null 2>&1 || true
    ysqlsh -h "${_h}" -q -f seed.sql   >/dev/null 2>&1 || true
done

clear

# ── Scene 1: Two sites, both active ──────────────────────────────────────────

p "=== Two-way pub/sub CDC: YugabyteDB ⇄ YugabyteDB ==="
p ""
p "Site A ${A_HOST}:5433   — publisher AND subscriber"
p "Site B ${B_HOST}:5433  — publisher AND subscriber"
p ""
p "Two applier lanes, each a separate JVM with Debezium embedded:"
p "  a2b : reads A's slot ${A2B_SLOT}, writes to B"
p "  b2a : reads B's slot ${B2A_SLOT}, writes to A"
p ""
p "Both sites start byte-identical — neither lane snapshots:"

pe "ysqlsh -h ${A_HOST} -c \"SELECT 'site-A' AS site, (SELECT COUNT(*) FROM ${SCHEMA}.orders) AS orders, (SELECT COUNT(*) FROM ${SCHEMA}.stock) AS stock, (SELECT MAX(updated_at) FROM ${SCHEMA}.stock) AS stock_version;\""

pe "ysqlsh -h ${B_HOST} -c \"SELECT 'site-B' AS site, (SELECT COUNT(*) FROM ${SCHEMA}.orders) AS orders, (SELECT COUNT(*) FROM ${SCHEMA}.stock) AS stock, (SELECT MAX(updated_at) FROM ${SCHEMA}.stock) AS stock_version;\""

p ""
p "--- Note what is NOT in the schema ---"

pe "ysqlsh -h ${A_HOST} -c \"\\d ${SCHEMA}.orders\""

p ""
p "There is no 'which site wrote this' column. Tagging every row with its writer"
p "would mean reshaping every table in the database to suit the replication"
p "topology. Write ownership is a routing rule that lives OUTSIDE the data —"
p "here, each site owns a disjoint range of order ids."
p ""
p "The timestamp column is a different matter: last_modified is a column this"
p "table would carry anyway, and that is exactly why last-writer-wins can use it."

p ""
p "--- The ORIGIN rule that makes loop prevention work ---"
p ""
p "YugabyteDB requires an origin to EXIST BEFORE a slot starts streaming, or"
p "that slot never reports it. Each lane creates its own origin on its sink —"
p "but the origin a lane must SEE belongs to the other lane. So both were"
p "created up front, by the startup script, before either slot existed:"

pe "ysqlsh -h ${A_HOST} -c \"SELECT 'site-A' AS site, roname FROM pg_replication_origin ORDER BY roname;\""

pe "ysqlsh -h ${B_HOST} -c \"SELECT 'site-B' AS site, roname FROM pg_replication_origin ORDER BY roname;\""

p ""
p "No slots yet on either site:"

pe "ysqlsh -h ${A_HOST} -c \"SELECT slot_name, plugin, active FROM pg_replication_slots;\""

# ── Scene 2: The two lane configs ────────────────────────────────────────────

p ""
p "--- Two configs, mirrored ---"
p ""
p "Every lane identity differs. Sharing any of these would corrupt the other"
p "lane's bookkeeping:"

pe "grep -hE '^[[:space:]]+(hostname|replication-slot|publication-name|offset-storage-jdbc-table|apply-state-table|apply-origin-name):' application-a2b.yml application-b2a.yml"

p ""
p "Each lane also binds its own HTTP port — two JVMs, and Spring Boot starts"
p "Tomcat even though the applier exposes no endpoints at all."

p ""
p "The rule that breaks the loop, set on BOTH lanes:"

pe "grep -hE '^[[:space:]]+ignore-replicated-changes:' application-a2b.yml application-b2a.yml"

p ""
p "'Discard every change that carries ANY replication origin.' An application"
p "write carries none; a replication apply carries one. Neither lane needs to"
p "know the other's origin name for this to work."

p ""
p "And the rule that makes the two sites AGREE when they write the same row:"

pe "grep -hE '^[[:space:]]+(conflict-resolution|conflict-columns|conflict-tiebreak|conflict-node-id|conflict-peer-id|conflict-log|conflict-log-table):' application-a2b.yml application-b2a.yml"

p ""
p "Last-writer-wins on a timestamp the table already carries. Note the node ids"
p "are mirrored — node/peer here is peer/node there — so when two versions are"
p "exactly equal, both lanes derive the SAME winner instead of each keeping its"
p "own. Identical ids are rejected at startup."

# ── Scene 3: Start both lanes ────────────────────────────────────────────────

p ""
p "--- Starting both lanes ---"

pe "bash applier.sh start both"

p ""
p "Each lane announced its rules at startup:"

pe "grep -hE 'Loop prevention|Conflict log table' ${A2B_LOG} ${B2A_LOG} || true"

p ""
p "One slot per site — each site is being read by the lane that publishes it:"

pe "ysqlsh -h ${A_HOST} -c \"SELECT 'site-A' AS site, slot_name, plugin, active FROM pg_replication_slots;\""

pe "ysqlsh -h ${B_HOST} -c \"SELECT 'site-B' AS site, slot_name, plugin, active FROM pg_replication_slots;\""

# ── Scene 4: A → B ───────────────────────────────────────────────────────────

p ""
p "--- Direction 1: write on A, read on B ---"
p "Site A owns the orders id range 1000-1999:"

pe "ysqlsh -h ${A_HOST} -c \"INSERT INTO ${SCHEMA}.orders (id, item, qty, status) VALUES (1001, 'Anvil', 3, 'placed');\""

echo ""
_wait_for "${B_HOST}" "SELECT COUNT(*) FROM ${SCHEMA}.orders WHERE id = 1001;" "1" 60 "order 1001 arriving on site B"
echo ""

pe "ysqlsh -h ${B_HOST} -c \"SELECT id, item, qty, status FROM ${SCHEMA}.orders WHERE id = 1001;\""

# ── Scene 5: B → A ───────────────────────────────────────────────────────────

p ""
p "--- Direction 2: write on B, read on A ---"
p "Site B owns the orders id range 2000-2999:"

pe "ysqlsh -h ${B_HOST} -c \"INSERT INTO ${SCHEMA}.orders (id, item, qty, status) VALUES (2001, 'Rocket Skates', 1, 'placed');\""

echo ""
_wait_for "${A_HOST}" "SELECT COUNT(*) FROM ${SCHEMA}.orders WHERE id = 2001;" "1" 60 "order 2001 arriving on site A"
echo ""

pe "ysqlsh -h ${A_HOST} -c \"SELECT id, item, qty, status FROM ${SCHEMA}.orders WHERE id = 2001;\""

p ""
p "Both sites now hold both orders — replication is genuinely two-way:"

pe "ysqlsh -h ${A_HOST} -c \"SELECT 'site-A' AS site, id, item FROM ${SCHEMA}.orders WHERE id IN (1001, 2001) ORDER BY id;\""

pe "ysqlsh -h ${B_HOST} -c \"SELECT 'site-B' AS site, id, item FROM ${SCHEMA}.orders WHERE id IN (1001, 2001) ORDER BY id;\""

# ── Scene 6: Loop detection ──────────────────────────────────────────────────

p ""
p "--- Loop detection: the reason this terminates ---"
p ""
p "Row 1001 was written on A with no origin, applied to B tagged '${A2B_ORIGIN_FULL}',"
p "and then read straight back by the b2a lane out of B's WAL. Here is that lane"
p "seeing the tag arrive — direct proof the origin survived the round trip:"

pe "grep -h 'First change event carrying replication origin' ${A2B_LOG} ${B2A_LOG} || true"

p ""
p "And here is what it did with it:"

pe "grep -h 'Discarding change from ignored origin' ${A2B_LOG} ${B2A_LOG} || true"

p ""
p "That discard is the loop terminating. Now let us make it a measurement."
p ""
p "${LOOP_PROOF_ROWS} rows inserted on A in one transaction. Each one is applied to B"
p "exactly once, echoed back to the b2a lane, and discarded there. If the filter"
p "were not working, these rows would bounce between the sites indefinitely."

_a_before=$(_count "${A_HOST}" orders)
_expected=$(( _a_before + LOOP_PROOF_ROWS ))
p ""
p "Before — site A: ${_a_before} orders"

pe "ysqlsh -h ${A_HOST} -c \"INSERT INTO ${SCHEMA}.orders (id, item, qty, status) SELECT 1000000 + g, 'Bulk ' || g, 1, 'placed' FROM generate_series(1, ${LOOP_PROOF_ROWS}) AS g;\""

echo ""
_wait_for "${B_HOST}" "SELECT COUNT(*) FROM ${SCHEMA}.orders;" "${_expected}" 300 "site B catching up"
echo ""

p "Both sites hold exactly the same number of rows — applied once, not repeatedly:"

pe "ysqlsh -h ${A_HOST} -tAc \"SELECT 'site-A orders: ' || COUNT(*) FROM ${SCHEMA}.orders;\""

pe "ysqlsh -h ${B_HOST} -tAc \"SELECT 'site-B orders: ' || COUNT(*) FROM ${SCHEMA}.orders;\""

p ""
p "The b2a lane's discard counter, now well past its 10,000-row log threshold —"
p "it processed every echoed row and dropped every one:"

pe "grep -h 'Discarding change from ignored origin' ${B2A_LOG} | tail -3 || true"

p ""
p "Now hold still for 15 seconds and re-count. In an unbroken loop these numbers"
p "would keep climbing; the slots would never go quiet."

echo ""
for _i in 1 2 3; do
    sleep 5
    printf "   t+%2ds   site A: %-8s site B: %s\n" \
        "$(( _i * 5 ))" "$(_count "${A_HOST}" orders)" "$(_count "${B_HOST}" orders)"
done
echo ""

p "Stable. The loop is closed."

# ── Scene 7: Conflicts → convergence ─────────────────────────────────────────

p ""
p "--- Both sites write the same rows ---"
p ""
p "Loop prevention stops changes circulating. On its own it says nothing about"
p "two sites writing the SAME row — with conflict-resolution: none, each site"
p "applies the other's change last and they diverge permanently."
p ""
p "These lanes run conflict-resolution: timestamp. Watch what that changes."
p ""
p "To make the outcome deterministic rather than a race, stop both lanes first."
p "This is a network partition in miniature:"

pe "bash applier.sh stop both"

p ""
p "Site A updates all five SKUs — note updated_at is set explicitly, because a"
p "DEFAULT now() fires on INSERT only:"

pe "ysqlsh -h ${A_HOST} -c \"UPDATE ${SCHEMA}.stock SET qty = 111, updated_at = now();\""

p ""
p "Two seconds later, site B updates the same five rows to a different value:"

sleep 2

pe "ysqlsh -h ${B_HOST} -c \"UPDATE ${SCHEMA}.stock SET qty = 999, updated_at = now();\""

p ""
p "While replication is down the sites disagree, which is unsurprising:"

pe "ysqlsh -h ${A_HOST} -c \"SELECT 'site-A' AS reading_from, sku, qty, updated_at FROM ${SCHEMA}.stock ORDER BY sku LIMIT 3;\""

pe "ysqlsh -h ${B_HOST} -c \"SELECT 'site-B' AS reading_from, sku, qty, updated_at FROM ${SCHEMA}.stock ORDER BY sku LIMIT 3;\""

p ""
p "Heal the partition. Each site's five changes are delivered to the other:"

pe "bash applier.sh start both"

echo ""
_wait_for "${A_HOST}" "SELECT COUNT(*) FROM ${SCHEMA}.stock WHERE qty = 999;" "5" 90 "site A applying B's later writes"
echo ""
echo "   letting the losing direction settle..."
sleep 8
echo ""

p "Each table is guarded by the timestamp column it actually has —"
p "detected per table, from columns the applier was already reading:"

pe "grep -h 'Conflict resolution on' ${A2B_LOG} ${B2A_LOG} | sort -u || true"

p ""
p "And now the point. Both sites AGREE, on B's later value:"

pe "ysqlsh -h ${A_HOST} -c \"SELECT 'site-A' AS reading_from, sku, qty, updated_at FROM ${SCHEMA}.stock ORDER BY sku;\""

pe "ysqlsh -h ${B_HOST} -c \"SELECT 'site-B' AS reading_from, sku, qty, updated_at FROM ${SCHEMA}.stock ORDER BY sku;\""

p ""
p "Site A took B's change because A's row was older. Site B REJECTED A's change"
p "because B's row was already newer — the guard is part of the statement:"
p ""
p "  DO UPDATE SET ... WHERE \"stock\".\"updated_at\" < EXCLUDED.\"updated_at\""
p ""
p "Five edits made on site A lost. That is a real decision about somebody's"
p "write, so it is recorded rather than merely logged:"

pe "ysqlsh -h ${B_HOST} -c \"SELECT table_name, row_key, incoming_version, reason, source_origin FROM ${SCHEMA}.${A2B_CONFLICT_LOG} ORDER BY rejected_at;\""

p ""
p "The full rejected payload is kept too, so the edit can be reconciled by hand:"

pe "ysqlsh -h ${B_HOST} -c \"SELECT row_key, payload FROM ${SCHEMA}.${A2B_CONFLICT_LOG} ORDER BY rejected_at LIMIT 2;\""

p ""
p "Site A's conflict log is empty — nothing arriving there lost:"

pe "ysqlsh -h ${A_HOST} -tAc \"SELECT 'site-A rejected rows: ' || COUNT(*) FROM ${SCHEMA}.${B2A_CONFLICT_LOG};\""

p ""
p "This is a conflict LOG, not a dead-letter queue. Nothing in it should be"
p "replayed — last-writer-wins already decided. It exists so that 'someone's"
p "edit was discarded' is a queryable fact rather than a line in a log file."

# ── Scene 8: Disjoint ownership ──────────────────────────────────────────────

p ""
p "--- The pattern that avoids conflicts entirely: disjoint ownership ---"
p ""
p "Last-writer-wins resolves a conflict; it does not make the losing edit not"
p "have happened. Better to make collisions impossible. Give every row one"
p "owning site — here by id range, with nothing in the schema to say so."
p ""
p "Both sites insert into their own range, at the same time:"

pe "ysqlsh -h ${A_HOST} -c \"INSERT INTO ${SCHEMA}.orders (id, item, qty, status) SELECT 1100 + g, 'A-item ' || g, 1, 'placed' FROM generate_series(1, 50) AS g;\" & ysqlsh -h ${B_HOST} -c \"INSERT INTO ${SCHEMA}.orders (id, item, qty, status) SELECT 2100 + g, 'B-item ' || g, 1, 'placed' FROM generate_series(1, 50) AS g;\" & wait"

_target=$(( _expected + 100 ))
echo ""
_wait_for "${A_HOST}" "SELECT COUNT(*) FROM ${SCHEMA}.orders;" "${_target}" 120 "site A converging"
_wait_for "${B_HOST}" "SELECT COUNT(*) FROM ${SCHEMA}.orders;" "${_target}" 120 "site B converging"
echo ""

p "Both sites hold all 100 new rows, 50 from each writer. Reading site A:"

pe "ysqlsh -h ${A_HOST} -c \"SELECT CASE WHEN id < 2000 THEN 'site-A range' ELSE 'site-B range' END AS written_by, COUNT(*) FROM ${SCHEMA}.orders WHERE id BETWEEN 1101 AND 2150 GROUP BY 1 ORDER BY 1;\""

p "Reading site B — identical:"

pe "ysqlsh -h ${B_HOST} -c \"SELECT CASE WHEN id < 2000 THEN 'site-A range' ELSE 'site-B range' END AS written_by, COUNT(*) FROM ${SCHEMA}.orders WHERE id BETWEEN 1101 AND 2150 GROUP BY 1 ORDER BY 1;\""

p ""
p "No conflicts arose, so no timestamps were compared and nothing was rejected:"

pe "ysqlsh -h ${B_HOST} -tAc \"SELECT 'rejected rows on site B: ' || COUNT(*) FROM ${SCHEMA}.${A2B_CONFLICT_LOG};\""

# ── Scene 9: Pipeline state ──────────────────────────────────────────────────

p ""
p "--- Pipeline state ---"
p ""
p "Each site's watermark records what the lane writing INTO it has committed:"

pe "ysqlsh -h ${A_HOST} -c \"SELECT 'site-A' AS site, slot_name, last_lsn, applied_at FROM ${SCHEMA}.${B2A_APPLY_STATE};\""

pe "ysqlsh -h ${B_HOST} -c \"SELECT 'site-B' AS site, slot_name, last_lsn, applied_at FROM ${SCHEMA}.${A2B_APPLY_STATE};\""

p ""
p "Both lanes:"

pe "bash applier.sh status"

p ""
p "✅ Two-way pub/sub:"
p "  Topology   : A ⇄ B, two independent one-way lanes, no coordination"
p "  Loop break : every applied row is origin-tagged; both lanes discard tagged rows"
p "  Conflicts  : last-writer-wins on a timestamp column the table already had"
p "  Ties       : mirrored node ids, so both lanes pick the same winner"
p "  Rejections : recorded in the conflict log, queryable and reconcilable"
p "  Ownership  : a routing rule (id ranges), NOT a column in every table"
p "  Bootstrap  : seed both sites identically, snapshot-mode never"
p "  Ordering   : origins must exist BEFORE the slots stream"
p ""
p "Explore further:"
p "  Lane logs     : bash applier.sh tail a2b   |   bash applier.sh tail b2a"
p "  Stop / start  : bash applier.sh stop both  |   bash applier.sh start both"
p "  Conflict log  : ysqlsh -h ${B_HOST} -c 'SELECT * FROM ${SCHEMA}.${A2B_CONFLICT_LOG};'"
p "  See the README to switch conflict-resolution back to none and watch the"
p "  same writes diverge, and to run a real replication loop with the filter off."

cmd

p ""
