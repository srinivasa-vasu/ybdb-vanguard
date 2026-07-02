[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/srinivasa-vasu/ybdb-vanguard?devcontainer_path=.devcontainer%2Finit-cdc-sqlserver-ybdb%2Fdevcontainer.json)

## Change data capture workflow from SQL Server to YugabyteDB

SQL Server acts as the CDC source using **log-based change data capture** (SQL Server Agent capture jobs reading the transaction log).
The **Debezium SQL Server source connector** (`io.debezium.connector.sqlserver.SqlServerConnector`) consumes those changes and publishes change events to Kafka.
A **Debezium JDBC sink connector** (`io.debezium.connector.jdbc.JdbcSinkConnector`) writes those events into YugabyteDB.

Unlike the YugabyteDB → PostgreSQL exercise, SQL Server emits **standard Debezium envelopes**, so the sink uses the stock `ExtractNewRecordState` SMT — not YugabyteDB's `YBExtractNewRecordState`.

**Quick start:** Four terminals open automatically:
- **`cdc-sqlserver-ybdb-demo`** — guided demo: run `bash prompt.sh` for the full walkthrough
- **`cdc-sqlserver-ybdb-ws`** — Workshop shell for the manual commands below
- **`sqlserver`** — SQL Server CLI (`sqlcmd`)
- **`ysql`** — YugabyteDB CLI (`ysqlsh`)

Run all manual `curl` / `docker exec` commands from the `cdc-sqlserver-ybdb-ws` shell.

The SQL Server `sqlcmd` client lives inside the container; a convenient shorthand for the workshop shell:

```bash
SQLCMD="docker exec sqlserver /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P Yugabyte@123 -C"
```

> `-C` trusts the server certificate — the SQL Server 2022 image defaults to encrypted connections.

---

### Wait for Kafka Connect to be ready

```bash
curl -s http://localhost:8083/ | python3 -m json.tool
```

---

### Verify SQL Server CDC is enabled

```bash
# CDC enabled at the database level (is_cdc_enabled: 1 = Yes)
$SQLCMD -Q "SELECT name, is_cdc_enabled FROM sys.databases WHERE name = 'chinook';"

# Tables already tracked by the Agent capture jobs (Artist, Album, Track)
$SQLCMD -d chinook -Q "SELECT name AS captured_table FROM sys.tables WHERE is_tracked_by_cdc = 1 ORDER BY name;"
```

---

### Create the demo table

```sql
-- $SQLCMD -d chinook -Q "..."
DROP TABLE IF EXISTS dbo.demo_events;
CREATE TABLE dbo.demo_events (
  id      INT IDENTITY(1,1) PRIMARY KEY,
  event   VARCHAR(255)  NOT NULL,
  status  VARCHAR(50),
  payload VARCHAR(MAX),
  ts      DATETIME2     NOT NULL DEFAULT CURRENT_TIMESTAMP
);
-- CDC must be enabled per table (the DB-level enable alone is not enough)
EXEC sys.sp_cdc_enable_table @source_schema = N'dbo', @source_name = N'demo_events', @role_name = NULL;
INSERT INTO dbo.demo_events (event, status, payload)
  VALUES ('system_init', 'ready', '{"msg": "pipeline ready"}');
```

---

### Create the SQL Server source connector

```bash
curl -i -X POST -H "Accept:application/json" -H "Content-Type:application/json" \
  localhost:8083/connectors/ -d '{
  "name": "mssqlsource",
  "config": {
    "connector.class": "io.debezium.connector.sqlserver.SqlServerConnector",
    "tasks.max": "1",
    "database.hostname": "127.0.0.1",
    "database.port": "1433",
    "database.user": "sa",
    "database.password": "Yugabyte@123",
    "database.names": "chinook",
    "topic.prefix": "sqlserver",
    "table.include.list": "dbo.Artist,dbo.Album,dbo.Track,dbo.demo_events",
    "snapshot.mode": "initial",
    "schema.history.internal.kafka.bootstrap.servers": "127.0.0.1:9092",
    "schema.history.internal.kafka.topic": "schema-changes.sqlserver",
    "database.encrypt": "false",
    "errors.retry.timeout": "2000",
    "errors.log.enable": "true",
    "errors.log.include.messages": "true"
  }
}'
```

> The SQL Server connector persists captured DDL to a dedicated **schema-history topic**
> (`schema-changes.sqlserver`). The YugabyteDB connector has no such requirement.

---

### Connector and task status

```bash
# Source connector
curl -s http://localhost:8083/connectors/mssqlsource/status | python3 -m json.tool

# Both connectors (after sink is also registered)
curl -s http://localhost:8083/connectors | python3 -m json.tool
```

---

### Inspect Kafka topics

Topics are named `<topic.prefix>.<database>.<schema>.<table>`, e.g. `sqlserver.chinook.dbo.Artist`.

```bash
KAFKA_CTR=init-cdc-sqlserver-ybdb-kafka-1

# List all topics (schema-history topic + data topics + internal Connect topics)
docker exec $KAFKA_CTR /kafka/bin/kafka-topics.sh \
  --bootstrap-server 127.0.0.1:9092 --list

# Describe a single topic (partitions, replicas, leader)
docker exec $KAFKA_CTR /kafka/bin/kafka-topics.sh \
  --bootstrap-server 127.0.0.1:9092 \
  --describe --topic sqlserver.chinook.dbo.Artist
```

---

### Create the YugabyteDB JDBC sink connector

```bash
curl -i -X POST -H "Accept:application/json" -H "Content-Type:application/json" \
  localhost:8083/connectors/ -d '{
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
    "transforms.dropPrefix.replacement": "$1",
    "transforms.unwrap.type": "io.debezium.transforms.ExtractNewRecordState",
    "transforms.unwrap.drop.tombstones": "false",
    "errors.retry.timeout": "2000",
    "errors.log.enable": "true",
    "errors.log.include.messages": "true"
  }
}'
```

Check the sink connector task status:

```bash
curl -s http://localhost:8083/connectors/ybsink/status | python3 -m json.tool
```

---

### Monitor Kafka consumer groups

The sink connector creates a consumer group named `connect-ybsink` that tracks how many messages have been written to YugabyteDB.

```bash
KAFKA_CTR=init-cdc-sqlserver-ybdb-kafka-1

# List all consumer groups
docker exec $KAFKA_CTR /kafka/bin/kafka-consumer-groups.sh \
  --bootstrap-server 127.0.0.1:9092 --list

# Describe group offsets and lag
# CURRENT-OFFSET = messages consumed, LOG-END-OFFSET = messages in Kafka, LAG = pending
docker exec $KAFKA_CTR /kafka/bin/kafka-consumer-groups.sh \
  --bootstrap-server 127.0.0.1:9092 \
  --describe --group connect-ybsink
```

When `LAG=0` for all partitions, every Kafka message has been written to YugabyteDB.

---

### Verify snapshot in YugabyteDB

After ~15–20 seconds for the Chinook snapshot to flush (queries run against the YugabyteDB sink on port 5433):

```bash
ysqlsh -h 127.0.0.1 -c 'SELECT COUNT(*) AS artists FROM Artist;'
ysqlsh -h 127.0.0.1 -c 'SELECT COUNT(*) AS albums  FROM Album;'
ysqlsh -h 127.0.0.1 -c 'SELECT COUNT(*) AS tracks  FROM Track;'
```

Confirm consumer lag dropped to zero:

```bash
docker exec $KAFKA_CTR /kafka/bin/kafka-consumer-groups.sh \
  --bootstrap-server 127.0.0.1:9092 \
  --describe --group connect-ybsink \
  | grep -E 'TOPIC|Artist'
```

---

### Live CDC — INSERT

Full insert (all columns) and partial insert (only the required column):

```sql
-- $SQLCMD -d chinook -Q "..."
INSERT INTO dbo.demo_events (event, status, payload)
  VALUES ('order_placed', 'pending', '{"item": "guitar", "qty": 2}');

-- sparse row — status and payload are NULL
INSERT INTO dbo.demo_events (event, status) VALUES ('payment_pending', 'pending');
```

> **Note:** SQL Server `IDENTITY(1,1)` keys are strictly sequential (no per-node
> caching), so the IDs are predictable: the seed row is `id=1`, `order_placed` is
> `id=2`, `payment_pending` is `id=3`. (This is the opposite of the YugabyteDB
> exercise, where sequence caching jumps IDs to 101, 201, …) The commands below
> capture the actual IDs anyway, so they stay correct across re-runs:

```bash
_id_full=$($SQLCMD -d chinook -W -h -1 -Q \
  "SET NOCOUNT ON;SELECT TOP 1 id FROM dbo.demo_events WHERE event='order_placed' ORDER BY id DESC;" \
  | tr -d '[:space:]')
_id_sparse=$($SQLCMD -d chinook -W -h -1 -Q \
  "SET NOCOUNT ON;SELECT TOP 1 id FROM dbo.demo_events WHERE event='payment_pending' ORDER BY id DESC;" \
  | tr -d '[:space:]')
echo "order_placed id: $_id_full   payment_pending id: $_id_sparse"
```

> SQL Server CDC is **asynchronous** — the Agent capture job polls the transaction
> log every ~5 seconds, so allow a few seconds before the change appears downstream.

Inspect a raw Debezium event in Kafka:

```bash
docker exec $KAFKA_CTR /kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server 127.0.0.1:9092 \
  --topic sqlserver.chinook.dbo.demo_events \
  --from-beginning --max-messages 1 --timeout-ms 5000 2>/dev/null \
  | python3 -m json.tool
```

Check consumer group offsets (2 events consumed, LAG=0):

```bash
docker exec $KAFKA_CTR /kafka/bin/kafka-consumer-groups.sh \
  --bootstrap-server 127.0.0.1:9092 \
  --describe --group connect-ybsink \
  | grep -E 'TOPIC|demo_events'
```

Verify both rows in YugabyteDB — fully-populated and sparse:

```bash
ysqlsh -h 127.0.0.1 -c 'SELECT id, event, status, payload FROM demo_events ORDER BY id;'
```

---

### Live CDC — UPDATE (full row)

Update every column on the fully-populated row:

```bash
$SQLCMD -d chinook -Q "UPDATE dbo.demo_events
SET event='order_confirmed', status='confirmed', payload='{\"item\": \"guitar\", \"qty\": 5}'
WHERE id = $_id_full;"
```

Consumer group offset advanced (op=u, LAG=0):

```bash
docker exec $KAFKA_CTR /kafka/bin/kafka-consumer-groups.sh \
  --bootstrap-server 127.0.0.1:9092 \
  --describe --group connect-ybsink \
  | grep -E 'TOPIC|demo_events'
```

All columns updated in YugabyteDB:

```bash
ysqlsh -h 127.0.0.1 -c "SELECT id, event, status, payload FROM demo_events WHERE id = $_id_full;"
```

---

### Live CDC — UPDATE (partial / sparse row)

Update only `event` on the sparse row — `status` and `payload` remain NULL:

```bash
$SQLCMD -d chinook -Q "UPDATE dbo.demo_events SET event='payment_received', status=NULL WHERE id = $_id_sparse;"
```

Consumer group offset advanced (op=u, LAG=0):

```bash
docker exec $KAFKA_CTR /kafka/bin/kafka-consumer-groups.sh \
  --bootstrap-server 127.0.0.1:9092 \
  --describe --group connect-ybsink \
  | grep -E 'TOPIC|demo_events'
```

Only `event` changed — `status` and `payload` remain NULL in YugabyteDB:

```bash
ysqlsh -h 127.0.0.1 -c "SELECT id, event, status, payload FROM demo_events WHERE id = $_id_sparse;"
```

---

### Live CDC — DELETE

Delete the confirmed-order row; the seed and sparse rows remain:

```bash
$SQLCMD -d chinook -Q "DELETE FROM dbo.demo_events WHERE id = $_id_full;"
```

A tombstone event is emitted; the sink issues a `DELETE` in YugabyteDB:

```bash
docker exec $KAFKA_CTR /kafka/bin/kafka-consumer-groups.sh \
  --bootstrap-server 127.0.0.1:9092 \
  --describe --group connect-ybsink \
  | grep -E 'TOPIC|demo_events'

ysqlsh -h 127.0.0.1 -c 'SELECT id, event, status, payload FROM demo_events ORDER BY id;'
```

---

### Check connector status

```bash
# Source
curl -s http://localhost:8083/connectors/mssqlsource/status | python3 -m json.tool

# Sink
curl -s http://localhost:8083/connectors/ybsink/status | python3 -m json.tool

# All consumer groups
docker exec $KAFKA_CTR /kafka/bin/kafka-consumer-groups.sh \
  --bootstrap-server 127.0.0.1:9092 --list
```

---

### Delete connectors (cleanup)

```bash
curl -X DELETE http://localhost:8083/connectors/mssqlsource
curl -X DELETE http://localhost:8083/connectors/ybsink
```

Optionally disable CDC on the demo table in SQL Server:

```bash
$SQLCMD -d chinook -Q "EXEC sys.sp_cdc_disable_table @source_schema = N'dbo', @source_name = N'demo_events', @capture_instance = N'all';"
```

---

### Key notes

- Tables must have a primary key — the Debezium JDBC sink needs a `record_key` to upsert and delete.
- CDC must be enabled **twice**: once at the database level (`sys.sp_cdc_enable_db`, already done for `chinook`) and once **per table** (`sys.sp_cdc_enable_table`). Enabling a table creates a `cdc.<schema>_<table>_CT` change table and an Agent capture job.
- **SQL Server Agent must be running** for CDC — the container sets `MSSQL_AGENT_ENABLED=true`. The capture job reads the transaction log asynchronously (default poll ~5s), so changes propagate in near real-time, not instantly.
- `database.encrypt: false` is required — the SQL Server 2022 image negotiates encrypted connections by default, which the connector (and `sqlcmd -C`) must be told to relax for this local setup.
- The connector needs a **schema-history topic** (`schema.history.internal.kafka.topic`) to persist captured DDL; this is specific to log-based connectors like SQL Server and MySQL.
- Topics are named `<topic.prefix>.<database>.<schema>.<table>` — here `sqlserver.chinook.dbo.<Table>` — because `database.names` puts the database segment in the path.
- The sink uses the **standard** `io.debezium.transforms.ExtractNewRecordState` SMT. SQL Server change events are plain Debezium envelopes, so unlike the YugabyteDB source (which wraps every field in a `{"value": <v>, "set": true}` struct and needs `YBExtractNewRecordState`), stock unwrapping is enough.
- `IDENTITY(1,1)` keys are strictly sequential — the seed row is `id=1`, the first live insert `id=2`, and so on. Contrast the YugabyteDB exercise, where sequence caching (100/node) makes the first live insert `id=101`.
