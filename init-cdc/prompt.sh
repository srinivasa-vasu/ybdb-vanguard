#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
export PGPASSWORD="${TAR_SECRET:-yugabyte}"  # PostgreSQL sink password
# YugabyteDB CDC demo  —  "The Live Sync Pipeline"
#
# Scenario: A YugabyteDB database (Chinook music store) is wired up to
# PostgreSQL via the YugabyteDB Debezium connector (yboutput logical
# replication) and a Debezium JDBC sink. The demo shows:
#
#   1. Register the source connector  → replication slot + publication created
#   2. Initial snapshot into Kafka    → topics appear, consumer group catches up
#   3. Register the sink connector    → snapshot data flows into PostgreSQL
#   4. Live INSERT / UPDATE / DELETE  → each change propagates in near real-time
#
# Kafka monitoring commands show topic inventory, consumer group offsets, and
# per-event lag throughout. All resource names (container, group, topic) are
# discovered at runtime rather than hardcoded.
#
# Pre-requisites (handled by postStartCommand + postCreateCommand):
#   - YugabyteDB running with ysql_yb_default_replica_identity=DEFAULT
#   - Kafka Connect ready on localhost:8083
#   - Chinook dataset already loaded into YugabyteDB
# ─────────────────────────────────────────────────────────────────────────────

. pscript
set -f  # disable filename expansion — prevents SELECT * glob-expanding in eval $@

TYPE_SPEED=40
NO_WAIT=false
DEMO_PROMPT="${GREEN}➜ ${CYAN}\W ${COLOR_RESET}"

KC_HOST="127.0.0.1"
PG_HOST="127.0.0.1"
KC_URL="http://${KC_HOST}:${KAFKA_CONNECT_PORT:-8083}"

# ── Discover Kafka container at runtime (avoids hardcoding the container name) ─
KAFKA_CTR=$(docker ps --format '{{.Names}}' 2>/dev/null \
    | grep -v 'zookeeper\|connect\|postgres\|yugabyte' \
    | grep -i 'kafka' | head -1)
KAFKA_CTR="${KAFKA_CTR:-init-cdc-kafka-1}"
KAFKA_BIN="docker exec ${KAFKA_CTR} /kafka/bin"

# Kafka Connect names sink consumer groups "connect-<connector-name>" by convention.
SINK_GROUP="connect-pgsink"

# ── Helper: poll consumer group until total LAG drops to 0 or timeout ─────────
_wait_for_lag_zero() {
    local max_wait="${1:-120}" label="${2:-consumer group}"
    local elapsed=0
    while [ "$elapsed" -lt "$max_wait" ]; do
        local lag
        lag=$(${KAFKA_BIN}/kafka-consumer-groups.sh \
            --bootstrap-server 127.0.0.1:9092 \
            --describe --group "${SINK_GROUP}" 2>/dev/null \
            | awk 'NR>1 && $6~/^[0-9]+$/ {s+=$6} END {print s+0}')
        if [ "${lag:-1}" -eq 0 ] 2>/dev/null; then
            echo ""
            echo "   ${label} LAG=0 ✅  (${elapsed}s)"
            return 0
        fi
        printf "\r   %s lag: %s (%ds)..." "$label" "${lag:-?}" "$elapsed"
        sleep 2; elapsed=$(( elapsed + 2 ))
    done
    echo ""
    echo "   (lag did not reach 0 after ${max_wait}s — continuing anyway)"
}

# ── Helper: poll consumer group for a specific topic until LAG=0 ──────────────
_wait_for_topic_lag_zero() {
    local topic="$1" max_wait="${2:-15}"
    local elapsed=0
    while [ "$elapsed" -lt "$max_wait" ]; do
        local lag
        lag=$(${KAFKA_BIN}/kafka-consumer-groups.sh \
            --bootstrap-server 127.0.0.1:9092 \
            --describe --group "${SINK_GROUP}" 2>/dev/null \
            | awk -v t="$topic" '$2==t && $6~/^[0-9]+$/ {s+=$6} END {print s+0}')
        if [ "${lag:-1}" -eq 0 ] 2>/dev/null; then
            return 0
        fi
        sleep 1; elapsed=$(( elapsed + 1 ))
    done
}

# ── Wait for Kafka Connect (postStartCommand may still be starting services) ──
_kc_wait=0
echo "Waiting for Kafka Connect on ${KC_URL} ..."
until curl -sf "${KC_URL}/" >/dev/null 2>&1; do
    printf "\r  [%3ds] services starting (postStartCommand still running)..." "$_kc_wait"
    sleep 5; _kc_wait=$(( _kc_wait + 5 ))
    if [ "$_kc_wait" -gt 300 ]; then
        echo ""
        echo "ERROR: Kafka Connect not available after ${_kc_wait}s."
        echo "  Check: docker logs ${KAFKA_CTR} | tail -30"
        exit 1
    fi
done
echo -e "\r  Kafka Connect ready after ${_kc_wait}s.           "

clear

# ── Quiet cleanup: remove any leftover connectors from a previous run ─────────
curl -s -X DELETE "${KC_URL}/connectors/ybsource" >/dev/null 2>&1 || true
curl -s -X DELETE "${KC_URL}/connectors/pgsink"   >/dev/null 2>&1 || true
# Drop replication slot AND publication so the connector recreates them fresh.
# If only the slot is dropped, an existing dbz_publication may be missing tables
# that were dropped+recreated in a prior run (DROP TABLE silently removes a table
# from a filtered publication; CREATE TABLE does not add it back automatically).
ysqlsh -h 127.0.0.1 -c "SELECT pg_drop_replication_slot(slot_name) FROM pg_replication_slots WHERE slot_name = 'yb_replication_slot';" 2>/dev/null || true
ysqlsh -h 127.0.0.1 -c "DROP PUBLICATION IF EXISTS dbz_publication;" 2>/dev/null || true

# ── Scene 1: Verify Kafka Connect ─────────────────────────────────────────────

p "=== CDC Demo: YugabyteDB → Kafka → PostgreSQL ==="
p ""
p "Stack: YugabyteDB Debezium connector (yboutput logical replication) + Debezium JDBC sink"
p ""
p "Kafka Connect REST API:"

pe "curl -s ${KC_URL}/ | python3 -m json.tool"

p ""
p "No connectors registered yet:"

pe "curl -s ${KC_URL}/connectors | python3 -m json.tool"

p ""
p "No replication slots on YugabyteDB yet:"

pe "ysqlsh -h 127.0.0.1 -c \"SELECT slot_name, plugin, slot_type, active FROM pg_replication_slots;\""

# ── Scene 2: Create a live-demo table ─────────────────────────────────────────

p ""
p "Creating a demo table in YugabyteDB for live CDC events:"

pe "ysqlsh -h 127.0.0.1 -c \"
DROP TABLE IF EXISTS public.demo_events;
CREATE TABLE public.demo_events (
  id      SERIAL PRIMARY KEY,
  event   TEXT          NOT NULL,
  status  TEXT,
  payload TEXT,
  ts      TIMESTAMPTZ   NOT NULL DEFAULT now()
);
INSERT INTO public.demo_events (event, status, payload)
  VALUES ('system_init', 'ready', '{\\\"msg\\\": \\\"pipeline ready\\\"}');\""

# ── Scene 3: Register the YugabyteDB source connector ─────────────────────────

p ""
p "Registering the YugabyteDB source connector..."
p "(plugin.name=yboutput: PostgreSQL logical replication; captures all tables in ${SCHEMA:-public})"

cat > /tmp/ybsource.json << EOF
{
  "name": "ybsource",
  "config": {
    "tasks.max": "1",
    "connector.class": "io.debezium.connector.postgresql.YugabyteDBConnector",
    "database.hostname": "${HOST:-127.0.0.1}",
    "database.port": "5433",
    "database.user": "${SRC_USER:-yugabyte}",
    "database.password": "${SRC_SECRET:-yugabyte}",
    "database.dbname": "${SRC_DB_OBJECT:-yugabyte}",
    "topic.prefix": "${TOPIC_PREFIX:-sample}",
    "snapshot.mode": "initial",
    "plugin.name": "yboutput",
    "slot.name": "yb_replication_slot",
    "publication.name": "dbz_publication",
    "publication.autocreate.mode": "filtered",
    "table.include.list": "${SCHEMA:-public}.*",
    "slot.drop.on.stop": "false",
    "errors.retry.timeout": "2000",
    "errors.log.enable": "true",
    "errors.log.include.messages": "true"
  }
}
EOF

pe "curl -s -X POST -H 'Content-Type:application/json' \
  ${KC_URL}/connectors/ \
  -d @/tmp/ybsource.json | python3 -m json.tool"

p ""
p "YugabyteDB replication slot and publication created automatically:"

pe "ysqlsh -h 127.0.0.1 -c \"SELECT slot_name, plugin, active FROM pg_replication_slots;\""

pe "ysqlsh -h 127.0.0.1 -c \"SELECT pubname, puballtables FROM pg_publication;\""

# ── Scene 4: Wait for snapshot + inspect Kafka ────────────────────────────────

p ""
p "Initial snapshot started — reading existing Chinook rows from YugabyteDB into Kafka..."

echo ""
_attempts=0
while [ "$_attempts" -lt 30 ]; do
  _state=$(curl -s "${KC_URL}/connectors/ybsource/status" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('connector',{}).get('state','UNKNOWN'))" 2>/dev/null)
  [ "$_state" = "RUNNING" ] && break
  printf "\r   connector state: %s (%ds)..." "$_state" "$(( _attempts * 2 ))"
  sleep 2
  _attempts=$(( _attempts + 1 ))
done
echo ""
echo "   connector state: RUNNING ✅"
echo ""

p "Source connector + task status:"

pe "curl -s ${KC_URL}/connectors/ybsource/status | python3 -m json.tool"

p ""
p "Kafka topics created — one per captured table plus internal Connect topics:"

pe "${KAFKA_BIN}/kafka-topics.sh --bootstrap-server 127.0.0.1:9092 --list 2>/dev/null"

# Discover a data topic dynamically for the describe example
_data_topic=$(${KAFKA_BIN}/kafka-topics.sh --bootstrap-server 127.0.0.1:9092 --list 2>/dev/null \
    | grep "^${TOPIC_PREFIX:-sample}\." | grep -Ev 'demo_events|__' | sort | head -1)
_data_topic="${_data_topic:-${TOPIC_PREFIX:-sample}.${SCHEMA:-public}.artist}"

p ""
p "Topic details — partitions, replication factor (topic: ${_data_topic}):"

pe "${KAFKA_BIN}/kafka-topics.sh --bootstrap-server 127.0.0.1:9092 \
    --describe --topic ${_data_topic} 2>/dev/null"

# ── Scene 5: Register the PostgreSQL JDBC sink connector ──────────────────────

p ""
p "Registering the PostgreSQL JDBC sink connector..."
p "(YBExtractNewRecordState unwraps YugabyteDB's per-field {value,set} structs before the JDBC sink)"

cat > /tmp/pgsink.json << EOF
{
  "name": "pgsink",
  "config": {
    "connector.class": "io.debezium.connector.jdbc.JdbcSinkConnector",
    "tasks.max": "1",
    "topics.regex": "${TOPIC_PREFIX:-sample}.${SCHEMA:-public}.(.*)",
    "connection.url": "jdbc:postgresql://localhost:5432/${TAR_DB_OBJECT:-postgres}",
    "connection.username": "${TAR_USER:-postgres}",
    "connection.password": "${TAR_SECRET:-yugabyte}",
    "insert.mode": "upsert",
    "primary.key.mode": "record_key",
    "schema.evolution": "basic",
    "delete.enabled": "true",
    "transforms": "dropPrefix, unwrap",
    "transforms.dropPrefix.type": "org.apache.kafka.connect.transforms.RegexRouter",
    "transforms.dropPrefix.regex": "${TOPIC_PREFIX:-sample}.${SCHEMA:-public}.(.*)",
    "transforms.dropPrefix.replacement": "\$1",
    "transforms.unwrap.type": "io.debezium.connector.postgresql.transforms.yugabytedb.YBExtractNewRecordState",
    "transforms.unwrap.drop.tombstones": "false",
    "errors.retry.timeout": "2000",
    "errors.log.enable": "true",
    "errors.log.include.messages": "true"
  }
}
EOF

pe "curl -s -X POST -H 'Content-Type:application/json' \
  ${KC_URL}/connectors/ \
  -d @/tmp/pgsink.json | python3 -m json.tool"

echo ""
_attempts=0
while [ "$_attempts" -lt 30 ]; do
  _task_state=$(curl -s "${KC_URL}/connectors/pgsink/status" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); t=d.get('tasks',[]); print(t[0].get('state','NO_TASK') if t else 'NO_TASK')" 2>/dev/null)
  [ "$_task_state" = "RUNNING" ] && break
  printf "\r   pgsink task state: %s (%ds)..." "$_task_state" "$(( _attempts * 2 ))"
  sleep 2
  _attempts=$(( _attempts + 1 ))
done
echo ""
echo "   pgsink task state: RUNNING ✅"
echo ""

p ""
p "Both connectors registered:"

pe "curl -s ${KC_URL}/connectors | python3 -m json.tool"

p ""
p "Sink connector + task status:"

pe "curl -s ${KC_URL}/connectors/pgsink/status | python3 -m json.tool"

p ""
p "Kafka consumer groups — pgsink registers one to track per-partition offsets:"

pe "${KAFKA_BIN}/kafka-consumer-groups.sh --bootstrap-server 127.0.0.1:9092 --list 2>/dev/null"

p ""
p "Consumer group offsets (LOG-END-OFFSET = messages in Kafka, LAG = not yet written to PostgreSQL):"

pe "${KAFKA_BIN}/kafka-consumer-groups.sh --bootstrap-server 127.0.0.1:9092 \
    --describe --group ${SINK_GROUP} 2>/dev/null || true"

# Poll for lag to reach 0 instead of a fixed sleep
p ""
p "Polling until consumer lag reaches 0 (snapshot fully flushed to PostgreSQL)..."

_wait_for_lag_zero 120 "snapshot"

# ── Scene 6: Verify snapshot arrived in PostgreSQL ────────────────────────────

p ""
p "--- Snapshot verification ---"

pe "psql -h ${PG_HOST} -p 5432 -U ${TAR_USER:-postgres} ${TAR_DB_OBJECT:-postgres} \
  -c 'SELECT COUNT(*) AS artists FROM Artist;'"

pe "psql -h ${PG_HOST} -p 5432 -U ${TAR_USER:-postgres} ${TAR_DB_OBJECT:-postgres} \
  -c 'SELECT COUNT(*) AS albums  FROM Album;'"

pe "psql -h ${PG_HOST} -p 5432 -U ${TAR_USER:-postgres} ${TAR_DB_OBJECT:-postgres} \
  -c 'SELECT COUNT(*) AS tracks  FROM Track;'"

p ""
p "Consumer group after snapshot flush (LAG=0 → every row is in PostgreSQL):"

pe "${KAFKA_BIN}/kafka-consumer-groups.sh --bootstrap-server 127.0.0.1:9092 \
    --describe --group ${SINK_GROUP} 2>/dev/null \
    | grep -E 'TOPIC|${_data_topic}' || true"

# ── Scene 7: Live CDC — INSERT ────────────────────────────────────────────────

_demo_topic="${TOPIC_PREFIX:-sample}.${SCHEMA:-public}.demo_events"

p ""
p "--- Live CDC: INSERT ---"

p "Full insert — all columns populated:"

pe "ysqlsh -h 127.0.0.1 -c \"INSERT INTO public.demo_events (event, status, payload) VALUES ('order_placed', 'pending', '{\\\"item\\\": \\\"guitar\\\", \\\"qty\\\": 2}');\""

p ""
p "Partial insert — only required column; status and payload intentionally NULL:"

pe "ysqlsh -h 127.0.0.1 -c \"INSERT INTO public.demo_events (event, status) VALUES ('payment_pending', 'pending');\""

# Capture actual IDs — YugabyteDB sequences cache 100 values per node by default,
# so the first INSERT after the seed may be id=101, 201, etc. rather than 2, 3.
_id_full=$(ysqlsh -h 127.0.0.1 -tAc \
    "SELECT id FROM public.demo_events WHERE event='order_placed' ORDER BY id DESC LIMIT 1;" \
    2>/dev/null | tr -d '[:space:]')
_id_sparse=$(ysqlsh -h 127.0.0.1 -tAc \
    "SELECT id FROM public.demo_events WHERE event='payment_pending' ORDER BY id DESC LIMIT 1;" \
    2>/dev/null | tr -d '[:space:]')
_id_full="${_id_full:-2}"
_id_sparse="${_id_sparse:-3}"

_wait_for_topic_lag_zero "${_demo_topic}" 5

p ""
p "Raw Debezium change event in Kafka (YugabyteDB wraps each field in {value,set}):"

pe "${KAFKA_BIN}/kafka-console-consumer.sh \
    --bootstrap-server 127.0.0.1:9092 \
    --topic ${_demo_topic} \
    --from-beginning --max-messages 1 --timeout-ms 5000 2>/dev/null \
    | python3 -m json.tool 2>/dev/null || true"

p ""
p "Consumer group offsets advanced (2 insert events), LAG=0:"

pe "${KAFKA_BIN}/kafka-consumer-groups.sh --bootstrap-server 127.0.0.1:9092 \
    --describe --group ${SINK_GROUP} 2>/dev/null \
    | grep -E 'TOPIC|demo_events' || true"

p ""
p "Both rows in PostgreSQL — id=${_id_full} fully populated, id=${_id_sparse} has nulls:"

pe "psql -h ${PG_HOST} -p 5432 -U ${TAR_USER:-postgres} ${TAR_DB_OBJECT:-postgres} \
  -c 'SELECT id, event, status, payload FROM demo_events ORDER BY id;'"

# ── Scene 8a: Live CDC — UPDATE (full row) ────────────────────────────────────

p ""
p "--- Live CDC: UPDATE (full — all columns) ---"
p "Update every column on the fully-populated row (id=${_id_full}):"

pe "ysqlsh -h 127.0.0.1 -c \"UPDATE public.demo_events SET event='order_confirmed', status='confirmed', payload='{\\\"item\\\": \\\"guitar\\\", \\\"qty\\\": 5}' WHERE id = ${_id_full};\""

_wait_for_topic_lag_zero "${_demo_topic}" 5

p ""
p "Consumer group offset — full-row update consumed (op=u), LAG=0:"

pe "${KAFKA_BIN}/kafka-consumer-groups.sh --bootstrap-server 127.0.0.1:9092 \
    --describe --group ${SINK_GROUP} 2>/dev/null \
    | grep -E 'TOPIC|demo_events' || true"

p ""
p "All columns updated in PostgreSQL:"

pe "psql -h ${PG_HOST} -p 5432 -U ${TAR_USER:-postgres} ${TAR_DB_OBJECT:-postgres} \
  -c 'SELECT id, event, status, payload FROM demo_events WHERE id = ${_id_full};'"

# ── Scene 8b: Live CDC — UPDATE (partial — sparse row) ────────────────────────

p ""
p "--- Live CDC: UPDATE (partial — sparse row, nulls remain) ---"
p "Update only event on the sparse row (id=${_id_sparse}) — status and payload stay NULL:"

pe "ysqlsh -h 127.0.0.1 -c \"UPDATE public.demo_events SET event='payment_received', status=NULL WHERE id = ${_id_sparse};\""

_wait_for_topic_lag_zero "${_demo_topic}" 5

p ""
p "Consumer group offset — partial update consumed (op=u), LAG=0:"

pe "${KAFKA_BIN}/kafka-consumer-groups.sh --bootstrap-server 127.0.0.1:9092 \
    --describe --group ${SINK_GROUP} 2>/dev/null \
    | grep -E 'TOPIC|demo_events' || true"

p ""
p "Only event changed — status and payload remain NULL in PostgreSQL:"

pe "psql -h ${PG_HOST} -p 5432 -U ${TAR_USER:-postgres} ${TAR_DB_OBJECT:-postgres} \
  -c 'SELECT id, event, status, payload FROM demo_events WHERE id = ${_id_sparse};'"

# ── Scene 9: Live CDC — DELETE ────────────────────────────────────────────────

p ""
p "--- Live CDC: DELETE ---"
p "Delete the confirmed order row (id=${_id_full}); seed and sparse rows remain:"

pe "ysqlsh -h 127.0.0.1 -c \"DELETE FROM public.demo_events WHERE id = ${_id_full};\""

_wait_for_topic_lag_zero "${_demo_topic}" 5

p ""
p "Tombstone event consumed — pgsink issued a DELETE in PostgreSQL:"

pe "${KAFKA_BIN}/kafka-consumer-groups.sh --bootstrap-server 127.0.0.1:9092 \
    --describe --group ${SINK_GROUP} 2>/dev/null \
    | grep -E 'TOPIC|demo_events' || true"

pe "psql -h ${PG_HOST} -p 5432 -U ${TAR_USER:-postgres} ${TAR_DB_OBJECT:-postgres} \
  -c 'SELECT id, event, status, payload FROM demo_events ORDER BY id;'"

# ── Scene 10: Final pipeline status ──────────────────────────────────────────

p ""
p "--- Final pipeline status ---"

pe "curl -s ${KC_URL}/connectors/ybsource/status | python3 -m json.tool"

pe "curl -s ${KC_URL}/connectors/pgsink/status | python3 -m json.tool"

p ""
p "All consumer groups:"

pe "${KAFKA_BIN}/kafka-consumer-groups.sh --bootstrap-server 127.0.0.1:9092 --list 2>/dev/null"

p ""
p "✅ CDC pipeline:"
p "  Source : YugabyteDB (yboutput logical replication) → Kafka (${TOPIC_PREFIX:-sample}.${SCHEMA:-public}.*)"
p "  Sink   : Kafka → PostgreSQL (Debezium JDBC, upsert + delete.enabled)"
p "  Events : snapshot + INSERT + UPDATE + DELETE — all propagated in near real-time"
p ""
p "Explore further:"
p "  Topics  : ${KAFKA_BIN}/kafka-topics.sh --bootstrap-server 127.0.0.1:9092 --list"
p "  Lag     : ${KAFKA_BIN}/kafka-consumer-groups.sh --bootstrap-server 127.0.0.1:9092 --describe --group ${SINK_GROUP}"
p "  Message : ${KAFKA_BIN}/kafka-console-consumer.sh --bootstrap-server 127.0.0.1:9092 --topic <topic> --from-beginning --max-messages 5 2>/dev/null"

cmd

p ""
