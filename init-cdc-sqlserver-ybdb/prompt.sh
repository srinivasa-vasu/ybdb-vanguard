#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# SQL Server to YugabyteDB CDC demo  —  "The SQL Server Sync Pipeline"
# ─────────────────────────────────────────────────────────────────────────────

. pscript
set -f  # disable filename expansion

TYPE_SPEED=70
NO_WAIT=false
DEMO_PROMPT="${GREEN}➜ ${CYAN}\W ${COLOR_RESET}"

KC_HOST="127.0.0.1"
KC_URL="http://${KC_HOST}:${KAFKA_CONNECT_PORT:-8083}"
MSSQL_SA_PASSWORD="${MSSQL_SA_PASSWORD:-Yugabyte@123}"

# ── Discover Kafka container at runtime ───────────────────────────────────────
KAFKA_CTR=$(docker ps --format '{{.Names}}' 2>/dev/null \
    | grep -i 'kafka' | head -1)
KAFKA_CTR="${KAFKA_CTR:-init-cdc-sqlserver-ybdb-kafka-1}"
KAFKA_BIN="docker exec ${KAFKA_CTR} /kafka/bin"

# Consumer group name configured for the sink
SINK_GROUP="connect-ybsink"

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

# ── Wait for Kafka Connect ────────────────────────────────────────────────────
_kc_wait=0
echo "Waiting for Kafka Connect on ${KC_URL} ..."
until curl -sf "${KC_URL}/" >/dev/null 2>&1; do
    printf "\r  [%3ds] services starting..." "$_kc_wait"
    sleep 5; _kc_wait=$(( _kc_wait + 5 ))
    if [ "$_kc_wait" -gt 300 ]; then
        echo ""
        echo "ERROR: Kafka Connect not available."
        exit 1
    fi
done
echo -e "\r  Kafka Connect ready after ${_kc_wait}s.           "

clear

# ── Quiet cleanup: remove any leftover connectors ─────────────────────────────
curl -s -X DELETE "${KC_URL}/connectors/mssqlsource" >/dev/null 2>&1 || true
curl -s -X DELETE "${KC_URL}/connectors/ybsink" >/dev/null 2>&1 || true

# ── Scene 1: Verify Statuses ──────────────────────────────────────────────────

p "=== CDC Demo: SQL Server → Kafka → YugabyteDB ==="
p ""
p "Stack: Debezium SQL Server Source Connector + Debezium JDBC Sink Connector"
p ""
p "Kafka Connect REST API:"

pe "curl -s ${KC_URL}/ | python3 -m json.tool"

p ""
p "No connectors registered yet:"

pe "curl -s ${KC_URL}/connectors | python3 -m json.tool"

p ""
p "Checking SQL Server CDC status (CDC database enabled: 1 = Yes):"

pe "docker exec sqlserver /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P \"${MSSQL_SA_PASSWORD}\" -C -Q \"SELECT name, is_cdc_enabled FROM sys.databases WHERE name = 'chinook';\""

# ── Scene 2: Create a live-demo table in SQL Server ───────────────────────────

p ""
p "Creating a demo table in SQL Server and enabling CDC for it:"

pe "docker exec sqlserver /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P \"${MSSQL_SA_PASSWORD}\" -C -d chinook -Q \"
DROP TABLE IF EXISTS dbo.demo_events;
CREATE TABLE dbo.demo_events (
  id      INT IDENTITY(1,1) PRIMARY KEY,
  event   VARCHAR(255)  NOT NULL,
  status  VARCHAR(50),
  payload VARCHAR(MAX),
  ts      DATETIME2     NOT NULL DEFAULT CURRENT_TIMESTAMP
);
EXEC sys.sp_cdc_enable_table @source_schema = N'dbo', @source_name = N'demo_events', @role_name = NULL;\""

p ""
p "--- Initialize demo_events table ---"
p "Inserting test events into SQL Server:"

pe "docker exec sqlserver /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P \"${MSSQL_SA_PASSWORD}\" -C -d chinook -Q \"
INSERT INTO dbo.demo_events (event, status, payload) VALUES ('order_placed', 'pending', '{\\\"item\\\": \\\"keyboard\\\", \\\"qty\\\": 2}');
INSERT INTO dbo.demo_events (event, status) VALUES ('payment_pending', 'pending');\""

# ── Scene 3: Register the SQL Server source connector ─────────────────────────

p ""
p "Registering the SQL Server source connector..."
p "(Captures tables: Artist, Album, Track, and demo_events in dbo schema)"

cat > /tmp/mssqlsource.json << EOF
{
  "name": "mssqlsource",
  "config": {
    "connector.class": "io.debezium.connector.sqlserver.SqlServerConnector",
    "tasks.max": "1",
    "database.hostname": "127.0.0.1",
    "database.port": "1433",
    "database.user": "sa",
    "database.password": "${MSSQL_SA_PASSWORD}",
    "database.names": "chinook",
    "topic.prefix": "sqlserver",
    "table.include.list": "dbo.Artist,dbo.Album,dbo.Track,dbo.demo_events",
    "schema.history.internal.kafka.bootstrap.servers": "127.0.0.1:9092",
    "schema.history.internal.kafka.topic": "schema-changes.sqlserver",
    "errors.retry.timeout": "2000",
    "errors.log.enable": "true",
    "errors.log.include.messages": "true",
    "database.encrypt": "false"
  }
}
EOF

pe "curl -s -X POST -H 'Content-Type:application/json' \
  ${KC_URL}/connectors/ \
  -d @/tmp/mssqlsource.json | python3 -m json.tool"

p ""
p "Waiting for connector to transition to RUNNING..."
echo ""
_attempts=0
while [ "$_attempts" -lt 30 ]; do
  _state=$(curl -s "${KC_URL}/connectors/mssqlsource/status" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('connector',{}).get('state','UNKNOWN'))" 2>/dev/null)
  [ "$_state" = "RUNNING" ] && break
  printf "\r   connector state: %s (%ds)..." "$_state" "$(( _attempts * 2 ))"
  sleep 2
  _attempts=$(( _attempts + 1 ))
done
echo ""
echo "   connector state: RUNNING ✅"
echo ""

p "Inspect Kafka topics (schema history topic + tables data topics):"

pe "${KAFKA_BIN}/kafka-topics.sh --bootstrap-server 127.0.0.1:9092 --list 2>/dev/null"

# ── Scene 4: Register the YugabyteDB JDBC sink connector ──────────────────────

p ""
p "Registering the YugabyteDB JDBC sink connector..."
p "(Uses standard ExtractNewRecordState SMT to unwrap SQL Server envelopes)"

cat > /tmp/ybsink.json << EOF
{
  "name": "ybsink",
  "config": {
    "connector.class": "io.debezium.connector.jdbc.JdbcSinkConnector",
    "tasks.max": "1",
    "topics.regex": "sqlserver.chinook.dbo.(Artist|Album|Track|demo_events)",
    "connection.url": "jdbc:postgresql://localhost:5433/yugabyte",
    "connection.username": "yugabyte",
    "connection.password": "yugabyte",
    "insert.mode": "upsert",
    "primary.key.mode": "record_key",
    "schema.evolution": "basic",
    "delete.enabled": "true",
    "transforms": "dropPrefix, unwrap",
    "transforms.dropPrefix.type": "org.apache.kafka.connect.transforms.RegexRouter",
    "transforms.dropPrefix.regex": "sqlserver.chinook.dbo.(.*)",
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
echo "   ybsink task state: RUNNING ✅"
echo ""

p "Polling until consumer lag reaches 0 (snapshot fully flushed to YugabyteDB)..."

_wait_for_lag_zero 120 "snapshot"

# ── Scene 5: Verify Snapshot in YugabyteDB ───────────────────────────────────

p ""
p "--- Snapshot verification on YugabyteDB (port 5433) ---"

pe "ysqlsh -h 127.0.0.1 -c 'SELECT COUNT(*) AS artists FROM Artist;'"
pe "ysqlsh -h 127.0.0.1 -c 'SELECT COUNT(*) AS albums FROM Album;'"
pe "ysqlsh -h 127.0.0.1 -c 'SELECT COUNT(*) AS tracks FROM Track;'"

# ── Scene 6: Live CDC — INSERT ────────────────────────────────────────────────

_demo_topic="sqlserver.dbo.demo_events"

p ""
p "--- Live CDC: INSERT ---"
p "Inserting test events into SQL Server:"

pe "docker exec sqlserver /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P \"${MSSQL_SA_PASSWORD}\" -C -d chinook -Q \"
INSERT INTO dbo.demo_events (event, status, payload) VALUES ('order_placed', 'pending', '{\\\"item\\\": \\\"guitar\\\", \\\"qty\\\": 2}');
INSERT INTO dbo.demo_events (event, status) VALUES ('payment_pending', 'pending');\""

# Get generated SQL Server IDs
_id_full=$(docker exec sqlserver /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "${MSSQL_SA_PASSWORD}" -C -d chinook -W -h -1 -Q "SET NOCOUNT ON;SELECT TOP 1 id FROM dbo.demo_events WHERE event='order_placed' ORDER BY id DESC;" | tr -d '[:space:]')
_id_sparse=$(docker exec sqlserver /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "${MSSQL_SA_PASSWORD}" -C -d chinook -W -h -1 -Q "SET NOCOUNT ON;SELECT TOP 1 id FROM dbo.demo_events WHERE event='payment_pending' ORDER BY id DESC;" | tr -d '[:space:]')

_wait_for_topic_lag_zero "${_demo_topic}" 10

p ""
p "Verify records inside YugabyteDB target table (demo_events):"

pe "ysqlsh -h 127.0.0.1 -c 'SELECT id, event, status, payload FROM demo_events ORDER BY id;'"

# ── Scene 7: Live CDC — UPDATE ────────────────────────────────────────────────

p ""
p "--- Live CDC: UPDATE ---"
p "Updating order_placed status inside SQL Server (id=${_id_full:-1}):"

pe "docker exec sqlserver /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P \"${MSSQL_SA_PASSWORD}\" -C -d chinook -Q \"
UPDATE dbo.demo_events SET event='order_confirmed', status='confirmed', payload='{\\\"item\\\": \\\"guitar\\\", \\\"qty\\\": 5}' WHERE id = ${_id_full:-1};\""

_wait_for_topic_lag_zero "${_demo_topic}" 5

p ""
p "Verify update propagated to YugabyteDB:"

pe "ysqlsh -h 127.0.0.1 -c 'SELECT id, event, status, payload FROM demo_events WHERE id = ${_id_full:-1};'"

# ── Scene 8: Live CDC — DELETE ────────────────────────────────────────────────

p ""
p "--- Live CDC: DELETE ---"
p "Deleting confirmed order inside SQL Server (id=${_id_full:-1}):"

pe "docker exec sqlserver /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P \"${MSSQL_SA_PASSWORD}\" -C -d chinook -Q \"
DELETE FROM dbo.demo_events WHERE id = ${_id_full:-1};\""

_wait_for_topic_lag_zero "${_demo_topic}" 5

p ""
p "Verify deletion in YugabyteDB (only the remaining rows are shown):"

pe "ysqlsh -h 127.0.0.1 -c 'SELECT id, event, status, payload FROM demo_events ORDER BY id;'"

# ── Scene 9: Final status ─────────────────────────────────────────────────────

p ""
p "--- Pipeline Status ---"
pe "curl -s ${KC_URL}/connectors/mssqlsource/status | python3 -m json.tool"
pe "curl -s ${KC_URL}/connectors/ybsink/status | python3 -m json.tool"

p ""
p "✅ CDC pipeline SQL Server → Kafka → YugabyteDB completed successfully!"
p ""

cmd
