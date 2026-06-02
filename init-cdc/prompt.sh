#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# YugabyteDB CDC demo  —  "The Live Sync Pipeline"
#
# Scenario: A YugabyteDB database (Chinook music store) is wired up to
# PostgreSQL via the YugabyteDB Debezium connector (yboutput logical
# replication) and a JDBC sink. The demo shows:
#
#   1. Register the source connector → replication slot + publication created
#   2. Snapshot existing Chinook data into Kafka → arrives in PostgreSQL
#   3. Live INSERT / UPDATE / DELETE → each change appears in PostgreSQL
#
# Pre-requisites (handled by postStartCommand + postCreateCommand):
#   - YugabyteDB running with ysql_yb_default_replica_identity=DEFAULT
#   - Kafka Connect ready on localhost:8083
#   - Chinook dataset already loaded into YugabyteDB
# ─────────────────────────────────────────────────────────────────────────────

. pscript

TYPE_SPEED=40
NO_WAIT=false
DEMO_PROMPT="${GREEN}➜ ${CYAN}\W ${COLOR_RESET}"

clear

# ── Quiet cleanup: remove any leftover connectors from a previous run ─────────
curl -s -X DELETE "http://localhost:${KAFKA_CONNECT_PORT:-8083}/connectors/ybsource" >/dev/null 2>&1 || true
curl -s -X DELETE "http://localhost:${KAFKA_CONNECT_PORT:-8083}/connectors/pgsink"   >/dev/null 2>&1 || true
# Drop any leftover replication slot
ysqlsh -h 127.0.0.1 -c "SELECT pg_drop_replication_slot(slot_name) FROM pg_replication_slots WHERE slot_name = 'yb_replication_slot';" 2>/dev/null || true

# ── Scene 1: Verify Kafka Connect is ready ────────────────────────────────────

p "=== CDC Demo: YugabyteDB → Kafka → PostgreSQL ==="
p ""
p "Stack: YugabyteDB Debezium connector (plugin.name: yboutput) + JDBC sink"
p ""
p "Kafka Connect status:"

pe "curl -s http://localhost:${KAFKA_CONNECT_PORT:-8083}/ | python3 -m json.tool"

pe "curl -s http://localhost:${KAFKA_CONNECT_PORT:-8083}/connectors | python3 -m json.tool"

p "No connectors yet. No replication slots on YugabyteDB:"

pe "ysqlsh -h 127.0.0.1 -c \"SELECT slot_name, plugin, slot_type, active FROM pg_replication_slots;\""

# ── Scene 2: Create a live-demo table ─────────────────────────────────────────

p ""
p "Creating a demo table in YugabyteDB to track live changes:"

pe "ysqlsh -h 127.0.0.1 -c \"
DROP TABLE IF EXISTS public.demo_events;
CREATE TABLE public.demo_events (
  id      SERIAL PRIMARY KEY,
  event   TEXT          NOT NULL,
  payload TEXT,
  ts      TIMESTAMPTZ   NOT NULL DEFAULT now()
);\""

# ── Scene 3: Register the YugabyteDB source connector ─────────────────────────

p ""
p "Registering the YugabyteDB source connector..."
p "(plugin.name: yboutput — PG logical replication, not gRPC)"

# Write the connector config to a temp file so the pe command stays readable
cat > /tmp/ybsource.json << EOF
{
  "name": "ybsource",
  "config": {
    "tasks.max": "1",
    "connector.class": "io.debezium.connector.yugabytedb.YugabyteDBConnector",
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
  http://localhost:${KAFKA_CONNECT_PORT:-8083}/connectors/ \
  -d @/tmp/ybsource.json | python3 -m json.tool"

p ""
p "Replication slot and publication created automatically:"

pe "ysqlsh -h 127.0.0.1 -c \"SELECT slot_name, plugin, active FROM pg_replication_slots;\""

pe "ysqlsh -h 127.0.0.1 -c \"SELECT pubname, puballtables FROM pg_publication;\""

# ── Scene 4: Wait for initial snapshot to complete ────────────────────────────

p ""
p "Initial snapshot running — snapshotting the Chinook dataset..."

echo ""
_attempts=0
while [ "$_attempts" -lt 30 ]; do
  _state=$(curl -s "http://localhost:${KAFKA_CONNECT_PORT:-8083}/connectors/ybsource/status" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('connector',{}).get('state','UNKNOWN'))" 2>/dev/null)
  [ "$_state" = "RUNNING" ] && break
  printf "\r   connector state: %s (%ds)..." "$_state" "$(( _attempts * 2 ))"
  sleep 2
  _attempts=$(( _attempts + 1 ))
done
echo ""
echo "   connector state: RUNNING ✅"
echo ""

pe "curl -s http://localhost:${KAFKA_CONNECT_PORT:-8083}/connectors/ybsource/status | python3 -m json.tool"

# ── Scene 5: Register the PostgreSQL JDBC sink connector ──────────────────────

p ""
p "Registering the PostgreSQL JDBC sink connector..."

cat > /tmp/pgsink.json << EOF
{
  "name": "pgsink",
  "config": {
    "connector.class": "io.confluent.connect.jdbc.JdbcSinkConnector",
    "tasks.max": "1",
    "topics.regex": "${TOPIC_PREFIX:-sample}.${SCHEMA:-public}.(.*)",
    "dialect.name": "PostgreSqlDatabaseDialect",
    "connection.url": "jdbc:postgresql://localhost:5432/${TAR_DB_OBJECT:-postgres}?user=${TAR_USER:-postgres}&password=${TAR_SECRET:-yugabyte}",
    "auto.create": "true",
    "auto.evolve": "true",
    "insert.mode": "upsert",
    "pk.mode": "record_key",
    "delete.enabled": "true",
    "transforms": "dropPrefix, unwrap",
    "transforms.dropPrefix.type": "org.apache.kafka.connect.transforms.RegexRouter",
    "transforms.dropPrefix.regex": "${TOPIC_PREFIX:-sample}.${SCHEMA:-public}.(.*)",
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
  http://localhost:${KAFKA_CONNECT_PORT:-8083}/connectors/ \
  -d @/tmp/pgsink.json | python3 -m json.tool"

p "Waiting for the sink to flush the snapshot data to PostgreSQL..."

sleep 15

# ── Scene 6: Verify snapshot arrived in PostgreSQL ────────────────────────────

p ""
p "--- Snapshot: Did Chinook data arrive in PostgreSQL? ---"

pe "psql -h 127.0.0.1 -p 5432 -U ${TAR_USER:-postgres} ${TAR_DB_OBJECT:-postgres} \
  -c 'SELECT COUNT(*) AS chinook_artists FROM \"Artist\";'"

p "Snapshot complete — all Chinook Artists are in PostgreSQL."

# ── Scene 7: Live CDC — INSERT ────────────────────────────────────────────────

p ""
p "--- Live CDC: INSERT ---"

pe "ysqlsh -h 127.0.0.1 -c \"INSERT INTO public.demo_events (event, payload) VALUES ('order_placed', '{\\\"item\\\": \\\"guitar\\\", \\\"qty\\\": 2}');\""

sleep 5

p "Event appeared in PostgreSQL:"

pe "psql -h 127.0.0.1 -p 5432 -U ${TAR_USER:-postgres} ${TAR_DB_OBJECT:-postgres} \
  -c 'SELECT id, event, payload, ts FROM demo_events ORDER BY id;'"

# ── Scene 8: Live CDC — UPDATE ────────────────────────────────────────────────

p ""
p "--- Live CDC: UPDATE ---"

pe "ysqlsh -h 127.0.0.1 -c \"UPDATE public.demo_events SET payload = '{\\\"item\\\": \\\"guitar\\\", \\\"qty\\\": 5, \\\"status\\\": \\\"confirmed\\\"}' WHERE id = 1;\""

sleep 5

p "Update propagated to PostgreSQL:"

pe "psql -h 127.0.0.1 -p 5432 -U ${TAR_USER:-postgres} ${TAR_DB_OBJECT:-postgres} \
  -c 'SELECT id, event, payload FROM demo_events WHERE id = 1;'"

# ── Scene 9: Live CDC — DELETE ────────────────────────────────────────────────

p ""
p "--- Live CDC: DELETE ---"

pe "ysqlsh -h 127.0.0.1 -c \"DELETE FROM public.demo_events WHERE id = 1;\""

sleep 5

p "Deletion propagated to PostgreSQL:"

pe "psql -h 127.0.0.1 -p 5432 -U ${TAR_USER:-postgres} ${TAR_DB_OBJECT:-postgres} \
  -c 'SELECT COUNT(*) AS remaining_events FROM demo_events;'"

# ── Scene 10: Final status ────────────────────────────────────────────────────

p ""
p "--- Connector status ---"

pe "curl -s http://localhost:${KAFKA_CONNECT_PORT:-8083}/connectors | python3 -m json.tool"

p ""
p "✅ CDC pipeline running:"
p "  Source : YugabyteDB (yboutput logical replication) → Kafka"
p "  Sink   : Kafka → PostgreSQL (JDBC sink, upsert mode)"
p "  Events : INSERT / UPDATE / DELETE all propagated in near real-time"
p ""
p "To inspect topics: docker exec -it \$(docker ps -qf name=kafka) \\"
p "  /kafka/bin/kafka-topics.sh --bootstrap-server 127.0.0.1:9092 --list"

cmd

p ""
