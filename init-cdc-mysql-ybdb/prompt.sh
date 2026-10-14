#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# MySQL to YugabyteDB CDC demo  —  "The MySQL Sync Pipeline"
#
# Scenario: A MySQL database (Chinook music store) is wired up to YugabyteDB
# via the Debezium MySQL source connector (binlog-based CDC — the connector
# joins the replication topology as a replica) and a Debezium JDBC sink. The
# demo shows:
#
#   1. Register the source connector  → schema-history topic + snapshot start
#   2. Initial snapshot into Kafka    → topics appear, consumer group catches up
#   3. Register the sink connector    → snapshot data flows into YugabyteDB
#   4. Live INSERT / UPDATE / DELETE  → each change propagates in near real-time
#
# Kafka monitoring commands show topic inventory, consumer group offsets, and
# per-event lag throughout. All resource names (container, group, topic) are
# discovered at runtime rather than hardcoded.
#
# Pre-requisites (handled by postStartCommand + postCreateCommand):
#   - MySQL running with binlog (ROW, FULL row image) and GTIDs enabled
#   - Kafka Connect ready on localhost:8083
#   - Chinook dataset already loaded into MySQL + 'debezium' replication user
#   - YugabyteDB running as the sink target on localhost:5433
#
# Note (vs the YugabyteDB → PostgreSQL exercise): MySQL emits STANDARD
# Debezium envelopes, so the sink uses the stock ExtractNewRecordState SMT — not
# YugabyteDB's YBExtractNewRecordState (which unwraps per-field {value,set}
# structs). MySQL AUTO_INCREMENT keys are also sequential on a single server, so
# the seed row is id=1, the first live insert id=2, etc.
# ─────────────────────────────────────────────────────────────────────────────

. pscript
set -f  # disable filename expansion — prevents SELECT * glob-expanding in eval $@

TYPE_SPEED=70
NO_WAIT=false
DEMO_PROMPT="${GREEN}➜ ${CYAN}\W ${COLOR_RESET}"

KC_HOST="127.0.0.1"
KC_URL="http://${KC_HOST}:${KAFKA_CONNECT_PORT:-8083}"
MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-yugabyte}"
DBZ_USER="${SRC_USER:-debezium}"
DBZ_PASSWORD="${SRC_SECRET:-dbz}"

# mysql shorthand — MYSQL_PWD avoids the "password on the command line" warning.
# docker exec has no TTY, so pass -t for bordered table output.
MYSQL="docker exec -e MYSQL_PWD=${MYSQL_ROOT_PASSWORD} mysql-cdc mysql -uroot"

# ── Discover Kafka container at runtime ───────────────────────────────────────
# The Docker socket is the host's, so other exercises' Kafka containers may be
# visible too — match this exercise's container specifically.
KAFKA_CTR=$(docker ps --format '{{.Names}}' 2>/dev/null \
    | grep 'cdc-mysql-ybdb-kafka' | head -1)
KAFKA_CTR="${KAFKA_CTR:-init-cdc-mysql-ybdb-kafka-1}"
KAFKA_BIN="docker exec ${KAFKA_CTR} /kafka/bin"

# Kafka Connect names sink consumer groups "connect-<connector-name>" by convention.
SINK_GROUP="connect-ybsink"

# ── Helper: poll consumer group until total LAG drops to 0 or timeout ─────────
_wait_for_lag_zero() {
    local max_wait="${1:-120}" label="${2:-consumer group}"
    local elapsed=0
    while [ "$elapsed" -lt "$max_wait" ]; do
        local lag
        # LAG is "-" until the sink commits its first offset (Connect commits
        # sink offsets every offset.flush.interval.ms, 60s by default) — treat
        # that as pending, otherwise an idle or stuck sink reads as LAG=0.
        lag=$(${KAFKA_BIN}/kafka-consumer-groups.sh \
            --bootstrap-server 127.0.0.1:9092 \
            --describe --group "${SINK_GROUP}" 2>/dev/null \
            | awk '$1==g && $6~/^[0-9]+$/ {s+=$6; n++} $1==g && $6=="-" {p=1}
                   END {print (p || !n) ? "-" : s+0}' g="${SINK_GROUP}")
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

# ── Helper: poll a YugabyteDB scalar query until it equals the expected value ──
# A consumer-group LAG of 0 only says the sink has caught up with what is in
# Kafka *right now* — it can fire before the source connector has published the
# change. Polling the sink target for the expected end-state is the reliable signal.
_wait_for_yb() {
    local query="$1" expected="$2" max_wait="${3:-45}"
    local elapsed=0 val
    while [ "$elapsed" -lt "$max_wait" ]; do
        val=$(ysqlsh -h 127.0.0.1 -tAc "$query" 2>/dev/null | tr -d '[:space:]')
        [ "$val" = "$expected" ] && return 0
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
curl -s -X DELETE "${KC_URL}/connectors/mysqlsource" >/dev/null 2>&1 || true
curl -s -X DELETE "${KC_URL}/connectors/ybsink"      >/dev/null 2>&1 || true

# ── Scene 1: Verify statuses ──────────────────────────────────────────────────

p "=== CDC Demo: MySQL → Kafka → YugabyteDB ==="
p ""
p "Stack: Debezium MySQL source connector (binlog-based CDC) + Debezium JDBC sink"
p ""
p "Kafka Connect REST API:"

pe "curl -s ${KC_URL}/ | python3 -m json.tool"

p ""
p "No connectors registered yet:"

pe "curl -s ${KC_URL}/connectors | python3 -m json.tool"

p ""
p "MySQL binlog settings Debezium relies on (log_bin=ON, ROW format, FULL row image, GTIDs):"

pe "${MYSQL} -t -e \"SHOW VARIABLES WHERE Variable_name IN ('log_bin','binlog_format','binlog_row_image','gtid_mode','server_id');\""

p ""
p "Current binlog coordinates — the connector records file/position/GTID as its offset:"

pe "${MYSQL} -E -e \"SHOW BINARY LOG STATUS;\""

p ""
p "Privileges held by the '${DBZ_USER}' connector user (replica + snapshot rights):"

pe "${MYSQL} -t -e \"SHOW GRANTS FOR '${DBZ_USER}'@'%';\""

# ── Scene 2: Create a live-demo table in MySQL ────────────────────────────────

p ""
p "Creating a demo table in MySQL (no per-table CDC switch — the binlog already has it):"

pe "${MYSQL} chinook -e \"
DROP TABLE IF EXISTS demo_events;
CREATE TABLE demo_events (
  id      INT AUTO_INCREMENT PRIMARY KEY,
  event   VARCHAR(255) NOT NULL,
  status  VARCHAR(50),
  payload TEXT,
  ts      DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP
);
INSERT INTO demo_events (event, status, payload) VALUES ('system_init', 'ready', '{\\\"msg\\\": \\\"pipeline ready\\\"}');\""

# ── Scene 3: Register the MySQL source connector ──────────────────────────────

p ""
p "Registering the MySQL source connector..."
p "(Captures chinook.Artist, Album, Track and demo_events; joins replication as server.id 184054)"

cat > /tmp/mysqlsource.json << EOF
{
  "name": "mysqlsource",
  "config": {
    "connector.class": "io.debezium.connector.mysql.MySqlConnector",
    "tasks.max": "1",
    "database.hostname": "127.0.0.1",
    "database.port": "3306",
    "database.user": "${DBZ_USER}",
    "database.password": "${DBZ_PASSWORD}",
    "database.server.id": "184054",
    "topic.prefix": "mysql",
    "database.include.list": "chinook",
    "table.include.list": "chinook.Artist,chinook.Album,chinook.Track,chinook.demo_events",
    "snapshot.mode": "initial",
    "schema.history.internal.kafka.bootstrap.servers": "127.0.0.1:9092",
    "schema.history.internal.kafka.topic": "schema-changes.mysql",
    "errors.retry.timeout": "2000",
    "errors.log.enable": "true",
    "errors.log.include.messages": "true"
  }
}
EOF

pe "curl -s -X POST -H 'Content-Type:application/json' \
  ${KC_URL}/connectors/ \
  -d @/tmp/mysqlsource.json | python3 -m json.tool"

p ""
p "Waiting for the source connector to transition to RUNNING..."
echo ""
_attempts=0
while [ "$_attempts" -lt 30 ]; do
  _state=$(curl -s "${KC_URL}/connectors/mysqlsource/status" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('connector',{}).get('state','UNKNOWN'))" 2>/dev/null)
  [ "$_state" = "RUNNING" ] && break
  printf "\r   connector state: %s (%ds)..." "$_state" "$(( _attempts * 2 ))"
  sleep 2
  _attempts=$(( _attempts + 1 ))
done
echo ""
if [ "$_state" = "RUNNING" ]; then
  echo "   connector state: RUNNING ✅"
else
  echo "   connector state: ${_state:-UNKNOWN} ❌ after $(( _attempts * 2 ))s — check: curl -s ${KC_URL}/connectors/mysqlsource/status"
fi
echo ""

p "Source connector + task status:"

pe "curl -s ${KC_URL}/connectors/mysqlsource/status | python3 -m json.tool"

p ""
p "The connector shows up in MySQL as a replica binlog dump thread:"

pe "${MYSQL} -t -e \"SELECT ID, USER, COMMAND, STATE FROM performance_schema.processlist WHERE COMMAND LIKE 'Binlog Dump%';\""

# ── Scene 4: Wait for snapshot + inspect Kafka ────────────────────────────────

p ""
p "Kafka topics — schema-change topic (mysql), schema-history topic + one data topic per table:"

pe "${KAFKA_BIN}/kafka-topics.sh --bootstrap-server 127.0.0.1:9092 --list 2>/dev/null"

# Discover a data topic dynamically for the describe example
_data_topic=$(${KAFKA_BIN}/kafka-topics.sh --bootstrap-server 127.0.0.1:9092 --list 2>/dev/null \
    | grep '^mysql\.chinook\.' | grep -Ev 'demo_events|__' | sort | head -1)
_data_topic="${_data_topic:-mysql.chinook.Album}"

p ""
p "Topic details — partitions, replication factor (topic: ${_data_topic}):"

pe "${KAFKA_BIN}/kafka-topics.sh --bootstrap-server 127.0.0.1:9092 \
    --describe --topic ${_data_topic} 2>/dev/null"

# ── Scene 5: Register the YugabyteDB JDBC sink connector ──────────────────────

p ""
p "Registering the YugabyteDB JDBC sink connector..."
p "(Standard ExtractNewRecordState unwraps MySQL's Debezium envelope; no per-field structs)"

cat > /tmp/ybsink.json << EOF
{
  "name": "ybsink",
  "config": {
    "connector.class": "io.debezium.connector.jdbc.JdbcSinkConnector",
    "tasks.max": "1",
    "topics.regex": "mysql.chinook.(Artist|Album|Track|demo_events)",
    "connection.url": "jdbc:postgresql://localhost:5433/yugabyte",
    "connection.username": "yugabyte",
    "connection.password": "yugabyte",
    "insert.mode": "upsert",
    "primary.key.mode": "record_key",
    "schema.evolution": "basic",
    "delete.enabled": "true",
    "transforms": "dropPrefix, unwrap",
    "transforms.dropPrefix.type": "org.apache.kafka.connect.transforms.RegexRouter",
    "transforms.dropPrefix.regex": "mysql.chinook.(.*)",
    "transforms.dropPrefix.replacement": "\$1",
    "transforms.unwrap.type": "io.debezium.transforms.ExtractNewRecordState",
    "transforms.unwrap.drop.tombstones": "false",
    "errors.retry.timeout": "2000",
    "errors.log.enable": "true",
    "errors.log.include.messages": "true"
  }
}
EOF

pe "curl -s -X POST -H 'Content-Type:application/json' \
  ${KC_URL}/connectors/ \
  -d @/tmp/ybsink.json | python3 -m json.tool"

echo ""
_attempts=0
while [ "$_attempts" -lt 30 ]; do
  _task_state=$(curl -s "${KC_URL}/connectors/ybsink/status" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); t=d.get('tasks',[]); print(t[0].get('state','NO_TASK') if t else 'NO_TASK')" 2>/dev/null)
  [ "$_task_state" = "RUNNING" ] && break
  printf "\r   ybsink task state: %s (%ds)..." "$_task_state" "$(( _attempts * 2 ))"
  sleep 2
  _attempts=$(( _attempts + 1 ))
done
echo ""
if [ "$_task_state" = "RUNNING" ]; then
  echo "   ybsink task state: RUNNING ✅"
else
  echo "   ybsink task state: ${_task_state:-UNKNOWN} ❌ after $(( _attempts * 2 ))s — check: curl -s ${KC_URL}/connectors/ybsink/status"
fi
echo ""

p ""
p "Both connectors registered:"

pe "curl -s ${KC_URL}/connectors | python3 -m json.tool"

p ""
p "Sink connector + task status:"

pe "curl -s ${KC_URL}/connectors/ybsink/status | python3 -m json.tool"

p ""
p "Kafka consumer groups — ybsink registers one to track per-partition offsets:"

pe "${KAFKA_BIN}/kafka-consumer-groups.sh --bootstrap-server 127.0.0.1:9092 --list 2>/dev/null"

p ""
p "Consumer group offsets (LOG-END-OFFSET = messages in Kafka, LAG = not yet written to YugabyteDB):"

pe "${KAFKA_BIN}/kafka-consumer-groups.sh --bootstrap-server 127.0.0.1:9092 \
    --describe --group ${SINK_GROUP} 2>/dev/null || true"

p ""
p "Polling until consumer lag reaches 0 (snapshot fully flushed to YugabyteDB)..."

_wait_for_lag_zero 120 "snapshot"

# Belt and braces: confirm the last snapshot table actually landed in YugabyteDB
_wait_for_yb "SELECT count(*) FROM Track;" 50 60

# ── Scene 6: Verify snapshot in YugabyteDB ───────────────────────────────────

p ""
p "--- Snapshot verification on YugabyteDB (port 5433) ---"

pe "ysqlsh -h 127.0.0.1 -c 'SELECT COUNT(*) AS artists FROM Artist;'"
pe "ysqlsh -h 127.0.0.1 -c 'SELECT COUNT(*) AS albums  FROM Album;'"
pe "ysqlsh -h 127.0.0.1 -c 'SELECT COUNT(*) AS tracks  FROM Track;'"

p ""
p "Consumer group after snapshot flush (LAG=0 → every row is in YugabyteDB):"

pe "${KAFKA_BIN}/kafka-consumer-groups.sh --bootstrap-server 127.0.0.1:9092 \
    --describe --group ${SINK_GROUP} 2>/dev/null \
    | grep -E 'TOPIC|${_data_topic}' || true"

# ── Scene 7: Live CDC — INSERT ────────────────────────────────────────────────

_demo_topic="mysql.chinook.demo_events"

p ""
p "--- Live CDC: INSERT ---"

p "Full insert — all columns populated:"

pe "${MYSQL} chinook -e \"INSERT INTO demo_events (event, status, payload) VALUES ('order_placed', 'pending', '{\\\"item\\\": \\\"guitar\\\", \\\"qty\\\": 2}');\""

p ""
p "Partial insert — only required column; status and payload intentionally NULL:"

pe "${MYSQL} chinook -e \"INSERT INTO demo_events (event, status) VALUES ('payment_pending', 'pending');\""

# Capture the AUTO_INCREMENT values MySQL generated. They are sequential on a
# single server, so these are the seed row +1 / +2, but capture them for robustness.
_id_full=$(${MYSQL} -N -B chinook -e "SELECT id FROM demo_events WHERE event='order_placed' ORDER BY id DESC LIMIT 1;" | tr -d '[:space:]')
_id_sparse=$(${MYSQL} -N -B chinook -e "SELECT id FROM demo_events WHERE event='payment_pending' ORDER BY id DESC LIMIT 1;" | tr -d '[:space:]')
_id_full="${_id_full:-2}"
_id_sparse="${_id_sparse:-3}"

# Wait until both live rows land in YugabyteDB (seed row + 2 inserts = 3 total)
_wait_for_yb "SELECT count(*) FROM demo_events;" 3 45
_wait_for_lag_zero 30 "insert"

p ""
p "Raw Debezium change event for the live insert (offset 0 is the snapshot read, op=r)."
p "Payload only — op=c, and source carries the binlog file/pos/row, gtid and server_id:"

pe "${KAFKA_BIN}/kafka-console-consumer.sh \
    --bootstrap-server 127.0.0.1:9092 \
    --topic ${_demo_topic} \
    --partition 0 --offset 1 --max-messages 1 --timeout-ms 5000 2>/dev/null \
    | python3 -c 'import sys,json; print(json.dumps(json.load(sys.stdin)[\"payload\"], indent=2))' 2>/dev/null || true"

p ""
p "Consumer group offsets advanced (2 insert events), LAG=0:"

pe "${KAFKA_BIN}/kafka-consumer-groups.sh --bootstrap-server 127.0.0.1:9092 \
    --describe --group ${SINK_GROUP} 2>/dev/null \
    | grep -E 'TOPIC|demo_events' || true"

p ""
p "Both rows in YugabyteDB — id=${_id_full} fully populated, id=${_id_sparse} has nulls:"

pe "ysqlsh -h 127.0.0.1 -P null=NULL -c 'SELECT id, event, status, payload FROM demo_events ORDER BY id;'"

# ── Scene 8a: Live CDC — UPDATE (full row) ────────────────────────────────────

p ""
p "--- Live CDC: UPDATE (full — all columns) ---"
p "Update every column on the fully-populated row (id=${_id_full}):"

pe "${MYSQL} chinook -e \"UPDATE demo_events SET event='order_confirmed', status='confirmed', payload='{\\\"item\\\": \\\"guitar\\\", \\\"qty\\\": 5}' WHERE id = ${_id_full};\""

_wait_for_yb "SELECT event FROM demo_events WHERE id=${_id_full};" "order_confirmed" 45
_wait_for_lag_zero 30 "update"

p ""
p "Consumer group offset — full-row update consumed (op=u), LAG=0:"

pe "${KAFKA_BIN}/kafka-consumer-groups.sh --bootstrap-server 127.0.0.1:9092 \
    --describe --group ${SINK_GROUP} 2>/dev/null \
    | grep -E 'TOPIC|demo_events' || true"

p ""
p "All columns updated in YugabyteDB:"

pe "ysqlsh -h 127.0.0.1 -P null=NULL -c 'SELECT id, event, status, payload FROM demo_events WHERE id = ${_id_full};'"

# ── Scene 8b: Live CDC — UPDATE (partial — sparse row) ────────────────────────

p ""
p "--- Live CDC: UPDATE (partial — sparse row, nulls remain) ---"
p "Update only event on the sparse row (id=${_id_sparse}) — status and payload stay NULL:"

pe "${MYSQL} chinook -e \"UPDATE demo_events SET event='payment_received', status=NULL WHERE id = ${_id_sparse};\""

_wait_for_yb "SELECT event FROM demo_events WHERE id=${_id_sparse};" "payment_received" 45
_wait_for_lag_zero 30 "update"

p ""
p "Consumer group offset — partial update consumed (op=u), LAG=0:"

pe "${KAFKA_BIN}/kafka-consumer-groups.sh --bootstrap-server 127.0.0.1:9092 \
    --describe --group ${SINK_GROUP} 2>/dev/null \
    | grep -E 'TOPIC|demo_events' || true"

p ""
p "Only event changed — status and payload remain NULL in YugabyteDB:"

pe "ysqlsh -h 127.0.0.1 -P null=NULL -c 'SELECT id, event, status, payload FROM demo_events WHERE id = ${_id_sparse};'"

# ── Scene 9: Live CDC — DELETE ────────────────────────────────────────────────

p ""
p "--- Live CDC: DELETE ---"
p "Delete the confirmed order row (id=${_id_full}); seed and sparse rows remain:"

pe "${MYSQL} chinook -e \"DELETE FROM demo_events WHERE id = ${_id_full};\""

_wait_for_yb "SELECT count(*) FROM demo_events WHERE id=${_id_full};" "0" 45
_wait_for_lag_zero 30 "delete"

p ""
p "Delete + tombstone events consumed — ybsink issued a DELETE in YugabyteDB:"

pe "${KAFKA_BIN}/kafka-consumer-groups.sh --bootstrap-server 127.0.0.1:9092 \
    --describe --group ${SINK_GROUP} 2>/dev/null \
    | grep -E 'TOPIC|demo_events' || true"

pe "ysqlsh -h 127.0.0.1 -P null=NULL -c 'SELECT id, event, status, payload FROM demo_events ORDER BY id;'"

# ── Scene 10: Final pipeline status ──────────────────────────────────────────

p ""
p "--- Final pipeline status ---"

pe "curl -s ${KC_URL}/connectors/mysqlsource/status | python3 -m json.tool"

pe "curl -s ${KC_URL}/connectors/ybsink/status | python3 -m json.tool"

p ""
p "All consumer groups:"

pe "${KAFKA_BIN}/kafka-consumer-groups.sh --bootstrap-server 127.0.0.1:9092 --list 2>/dev/null"

p ""
p "✅ CDC pipeline:"
p "  Source : MySQL (binlog streamed by a replica connector) → Kafka (mysql.chinook.*)"
p "  Sink   : Kafka → YugabyteDB (Debezium JDBC, upsert + delete.enabled)"
p "  Events : snapshot + INSERT + UPDATE + DELETE — all propagated in near real-time"
p ""
p "Explore further:"
p "  Topics  : ${KAFKA_BIN}/kafka-topics.sh --bootstrap-server 127.0.0.1:9092 --list"
p "  Lag     : ${KAFKA_BIN}/kafka-consumer-groups.sh --bootstrap-server 127.0.0.1:9092 --describe --group ${SINK_GROUP}"
p "  Message : ${KAFKA_BIN}/kafka-console-consumer.sh --bootstrap-server 127.0.0.1:9092 --topic <topic> --from-beginning --max-messages 5 2>/dev/null"

cmd

p ""
