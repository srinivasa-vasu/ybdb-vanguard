[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/srinivasa-vasu/ybdb-vanguard?devcontainer_path=.devcontainer%2Finit-cdc%2Fdevcontainer.json)

## Change data capture workflow from YugabyteDB to PostgreSQL

YugabyteDB acts as the CDC source using **PostgreSQL logical replication** (`yboutput` plugin).
The **YugabyteDB Debezium connector** (`io.debezium.connector.postgresql.YugabyteDBConnector`) consumes the replication stream and publishes change events to Kafka.
A **Debezium JDBC sink connector** (`io.debezium.connector.jdbc.JdbcSinkConnector`) writes those events to the PostgreSQL sink.

**Quick start:** Two terminals open automatically:
- **`cdc-demo`** — guided demo: run `bash prompt.sh` for the full walkthrough
- **`connector-config`** — ad-hoc shell for the manual commands below

Run all manual `curl` / `docker exec` commands from the `connector-config` shell.

---

### Wait for Kafka Connect to be ready

```bash
curl -s http://localhost:8083/ | python3 -m json.tool
```

---

### Create the demo table

```sql
-- ysqlsh
DROP TABLE IF EXISTS public.demo_events;
CREATE TABLE public.demo_events (
  id      SERIAL PRIMARY KEY,
  event   TEXT          NOT NULL,
  status  TEXT,
  payload TEXT,
  ts      TIMESTAMPTZ   NOT NULL DEFAULT now()
);
INSERT INTO public.demo_events (event, status, payload)
  VALUES ('system_init', 'ready', '{"msg": "pipeline ready"}');
```

---

### Create the YugabyteDB source connector

```bash
curl -i -X POST -H "Accept:application/json" -H "Content-Type:application/json" \
  localhost:8083/connectors/ -d '{
  "name": "ybsource",
  "config": {
    "tasks.max": "1",
    "connector.class": "io.debezium.connector.postgresql.YugabyteDBConnector",
    "database.hostname": "'$HOST'",
    "database.port": "5433",
    "database.user": "'$SRC_USER'",
    "database.password": "'$SRC_SECRET'",
    "database.dbname": "'$SRC_DB_OBJECT'",
    "topic.prefix": "'$TOPIC_PREFIX'",
    "snapshot.mode": "initial",
    "plugin.name": "yboutput",
    "slot.name": "yb_replication_slot",
    "publication.name": "dbz_publication",
    "publication.autocreate.mode": "filtered",
    "table.include.list": "'$SCHEMA'.*",
    "slot.drop.on.stop": "false",
    "errors.retry.timeout": "2000",
    "errors.log.enable": "true",
    "errors.log.include.messages": "true"
  }
}'
```

Confirm the replication slot and publication were created:

```sql
-- ysqlsh
SELECT slot_name, plugin, slot_type, active FROM pg_replication_slots;
SELECT pubname, puballtables FROM pg_publication;
```

---

### Connector and task status

```bash
# Source connector
curl -s http://localhost:8083/connectors/ybsource/status | python3 -m json.tool

# Both connectors (after sink is also registered)
curl -s http://localhost:8083/connectors | python3 -m json.tool
```

---

### Inspect Kafka topics

```bash
KAFKA_CTR=init-cdc-kafka-1

# List all topics (data topics + 3 internal Connect topics)
docker exec $KAFKA_CTR /kafka/bin/kafka-topics.sh \
  --bootstrap-server 127.0.0.1:9092 --list

# Describe a single topic (partitions, replicas, leader)
docker exec $KAFKA_CTR /kafka/bin/kafka-topics.sh \
  --bootstrap-server 127.0.0.1:9092 \
  --describe --topic "$TOPIC_PREFIX"."$SCHEMA".artist
```

---

### Create the PostgreSQL JDBC sink connector

```bash
curl -i -X POST -H "Accept:application/json" -H "Content-Type:application/json" \
  localhost:8083/connectors/ -d '{
  "name": "pgsink",
  "config": {
    "connector.class": "io.debezium.connector.jdbc.JdbcSinkConnector",
    "tasks.max": "1",
    "topics.regex": "'$TOPIC_PREFIX'.'$SCHEMA'.(.*)",
    "connection.url": "jdbc:postgresql://localhost:5432/'$TAR_DB_OBJECT'",
    "connection.username": "'$TAR_USER'",
    "connection.password": "'$TAR_SECRET'",
    "insert.mode": "upsert",
    "primary.key.mode": "record_key",
    "schema.evolution": "basic",
    "delete.enabled": "true",
    "transforms": "dropPrefix, unwrap",
    "transforms.dropPrefix.type": "org.apache.kafka.connect.transforms.RegexRouter",
    "transforms.dropPrefix.regex": "'$TOPIC_PREFIX'.'$SCHEMA'.(.*)",
    "transforms.dropPrefix.replacement": "$1",
    "transforms.unwrap.type": "io.debezium.connector.postgresql.transforms.yugabytedb.YBExtractNewRecordState",
    "transforms.unwrap.drop.tombstones": "false",
    "errors.retry.timeout": "2000",
    "errors.log.enable": "true",
    "errors.log.include.messages": "true"
  }
}'
```

Check the sink connector task status:

```bash
curl -s http://localhost:8083/connectors/pgsink/status | python3 -m json.tool
```

---

### Monitor Kafka consumer groups

The sink connector creates a consumer group named `connect-pgsink` that tracks how many messages have been written to PostgreSQL.

```bash
KAFKA_CTR=init-cdc-kafka-1

# List all consumer groups
docker exec $KAFKA_CTR /kafka/bin/kafka-consumer-groups.sh \
  --bootstrap-server 127.0.0.1:9092 --list

# Describe group offsets and lag
# CURRENT-OFFSET = messages consumed, LOG-END-OFFSET = messages in Kafka, LAG = pending
docker exec $KAFKA_CTR /kafka/bin/kafka-consumer-groups.sh \
  --bootstrap-server 127.0.0.1:9092 \
  --describe --group connect-pgsink
```

When `LAG=0` for all partitions, every Kafka message has been written to PostgreSQL.

---

### Verify snapshot in PostgreSQL

After ~15–20 seconds for the Chinook snapshot to flush:

```bash
psql -h 127.0.0.1 -p 5432 -U $TAR_USER $TAR_DB_OBJECT \
  -c 'SELECT COUNT(*) AS artists FROM Artist;'

psql -h 127.0.0.1 -p 5432 -U $TAR_USER $TAR_DB_OBJECT \
  -c 'SELECT COUNT(*) AS albums  FROM Album;'

psql -h 127.0.0.1 -p 5432 -U $TAR_USER $TAR_DB_OBJECT \
  -c 'SELECT COUNT(*) AS tracks  FROM Track;'
```

Confirm consumer lag dropped to zero:

```bash
docker exec $KAFKA_CTR /kafka/bin/kafka-consumer-groups.sh \
  --bootstrap-server 127.0.0.1:9092 \
  --describe --group connect-pgsink \
  | grep -E 'TOPIC|artist'
```

---

### Live CDC — INSERT

Full insert (all columns) and partial insert (only required column):

```sql
-- ysqlsh
INSERT INTO public.demo_events (event, status, payload)
VALUES ('order_placed', 'pending', '{"item": "guitar", "qty": 2}');

-- sparse row — status and payload are NULL
INSERT INTO public.demo_events (event, status) VALUES ('payment_pending', 'pending');
```

> **Note:** YugabyteDB sequences cache 100 values per node by default, so the first
> live INSERT after the seed row gets id=101, the next id=201, etc. — not id=2/3.
> Capture the actual IDs before running the UPDATE / DELETE commands below:

```bash
# Run from the connector-config shell (ysqlsh targets YugabyteDB on port 5433)
_id_full=$(ysqlsh -h 127.0.0.1 -tAc \
  "SELECT id FROM public.demo_events WHERE event='order_placed' ORDER BY id DESC LIMIT 1;" \
  | tr -d '[:space:]')
_id_sparse=$(ysqlsh -h 127.0.0.1 -tAc \
  "SELECT id FROM public.demo_events WHERE event='payment_pending' ORDER BY id DESC LIMIT 1;" \
  | tr -d '[:space:]')
echo "order_placed id: $_id_full   payment_pending id: $_id_sparse"
```

Inspect a raw Debezium event in Kafka (note the YugabyteDB `{value,set}` struct per field):

```bash
docker exec $KAFKA_CTR /kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server 127.0.0.1:9092 \
  --topic "$TOPIC_PREFIX"."$SCHEMA".demo_events \
  --from-beginning --max-messages 1 --timeout-ms 5000 2>/dev/null \
  | python3 -m json.tool
```

Check consumer group offsets (2 events consumed, LAG=0):

```bash
docker exec $KAFKA_CTR /kafka/bin/kafka-consumer-groups.sh \
  --bootstrap-server 127.0.0.1:9092 \
  --describe --group connect-pgsink \
  | grep -E 'TOPIC|demo_events'
```

Verify both rows in PostgreSQL — fully-populated and sparse:

```bash
psql -h 127.0.0.1 -p 5432 -U $TAR_USER $TAR_DB_OBJECT \
  -c 'SELECT id, event, status, payload FROM demo_events ORDER BY id;'
```

---

### Live CDC — UPDATE (full row)

Update every column on the fully-populated row:

```bash
# ysqlsh
ysqlsh -h 127.0.0.1 -c "UPDATE public.demo_events
SET event = 'order_confirmed', status = 'confirmed', payload = '{\"item\": \"guitar\", \"qty\": 5}'
WHERE id = $_id_full;"
```

Consumer group offset advanced (op=u, LAG=0):

```bash
docker exec $KAFKA_CTR /kafka/bin/kafka-consumer-groups.sh \
  --bootstrap-server 127.0.0.1:9092 \
  --describe --group connect-pgsink \
  | grep -E 'TOPIC|demo_events'
```

All columns updated in PostgreSQL:

```bash
psql -h 127.0.0.1 -p 5432 -U $TAR_USER $TAR_DB_OBJECT \
  -c "SELECT id, event, status, payload FROM demo_events WHERE id = $_id_full;"
```

---

### Live CDC — UPDATE (partial / sparse row)

Update only `event` on the sparse row — `status` and `payload` remain NULL:

```bash
# ysqlsh
ysqlsh -h 127.0.0.1 -c "UPDATE public.demo_events SET event = 'payment_received', status=NULL WHERE id = $_id_sparse;"
```

Consumer group offset advanced (op=u, LAG=0):

```bash
docker exec $KAFKA_CTR /kafka/bin/kafka-consumer-groups.sh \
  --bootstrap-server 127.0.0.1:9092 \
  --describe --group connect-pgsink \
  | grep -E 'TOPIC|demo_events'
```

Only `event` changed — `status` and `payload` remain NULL in PostgreSQL:

```bash
psql -h 127.0.0.1 -p 5432 -U $TAR_USER $TAR_DB_OBJECT \
  -c "SELECT id, event, status, payload FROM demo_events WHERE id = $_id_sparse;"
```

---

### Live CDC — DELETE

Delete the confirmed-order row; the seed and sparse rows remain:

```bash
# ysqlsh
ysqlsh -h 127.0.0.1 -c "DELETE FROM public.demo_events WHERE id = $_id_full;"
```

A tombstone event is emitted; the sink issues a `DELETE` in PostgreSQL:

```bash
docker exec $KAFKA_CTR /kafka/bin/kafka-consumer-groups.sh \
  --bootstrap-server 127.0.0.1:9092 \
  --describe --group connect-pgsink \
  | grep -E 'TOPIC|demo_events'

psql -h 127.0.0.1 -p 5432 -U $TAR_USER $TAR_DB_OBJECT \
  -c 'SELECT id, event, status, payload FROM demo_events ORDER BY id;'
```

---

### Check connector status

```bash
# Source
curl -s http://localhost:8083/connectors/ybsource/status | python3 -m json.tool

# Sink
curl -s http://localhost:8083/connectors/pgsink/status | python3 -m json.tool

# All consumer groups
docker exec $KAFKA_CTR /kafka/bin/kafka-consumer-groups.sh \
  --bootstrap-server 127.0.0.1:9092 --list
```

---

### Delete connectors (cleanup)

```bash
curl -X DELETE http://localhost:8083/connectors/ybsource
curl -X DELETE http://localhost:8083/connectors/pgsink
```

Drop the replication slot:

```sql
-- ysqlsh
SELECT pg_drop_replication_slot('yb_replication_slot');
```

---

### Key notes

- Tables must have a primary key — CDC is not supported on tables without one.
- `plugin.name: yboutput` is the YugabyteDB-native logical replication output plugin; do not use `pgoutput` with the YugabyteDB connector.
- The tserver flag `ysql_yb_default_replica_identity=DEFAULT` ensures all new tables automatically get `DEFAULT` replica identity, which is required for the connector to capture before-images on UPDATE and DELETE.
- DDL changes should not be made from the time the replication slot is created until the initial snapshot of the last table completes.
- YugabyteDB 2024.1.1 or later is required for the `yboutput` plugin.
- The sink connector uses `YBExtractNewRecordState` (bundled in the YugabyteDB source connector JAR) instead of the standard `ExtractNewRecordState`. The YugabyteDB connector wraps every field value in a `{"value": <v>, "set": true}` struct; `YBExtractNewRecordState` unwraps both the Debezium envelope and those per-field structs so the Debezium JDBC sink receives plain primitive types.
