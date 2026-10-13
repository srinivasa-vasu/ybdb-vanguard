[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/srinivasa-vasu/ybdb-vanguard?devcontainer_path=.devcontainer%2Finit-cdc-mysql-ybdb%2Fdevcontainer.json)

## Change data capture workflow from MySQL to YugabyteDB

MySQL acts as the CDC source using **binlog-based change data capture** (the connector registers as a replica and streams the row-based binary log).
The **Debezium MySQL source connector** (`io.debezium.connector.mysql.MySqlConnector`) consumes those changes and publishes change events to Kafka.
A **Debezium JDBC sink connector** (`io.debezium.connector.jdbc.JdbcSinkConnector`) writes those events into YugabyteDB.

Unlike the YugabyteDB → PostgreSQL exercise, MySQL emits **standard Debezium envelopes**, so the sink uses the stock `ExtractNewRecordState` SMT — not YugabyteDB's `YBExtractNewRecordState`.

**Quick start:** Four terminals open automatically:
- **`cdc-mysql-ybdb-demo`** — guided demo: run `bash prompt.sh` for the full walkthrough
- **`cdc-mysql-ybdb-ws`** — Workshop shell for the manual commands below
- **`mysql-cdc`** — MySQL CLI (`mysql`)
- **`ysql`** — YugabyteDB CLI (`ysqlsh`)

Run all manual `curl` / `docker exec` commands from the `cdc-mysql-ybdb-ws` shell.

The MySQL `mysql` client lives inside the container; a convenient shorthand for the workshop shell:

```bash
MYSQL="docker exec -e MYSQL_PWD=yugabyte mysql-cdc mysql -uroot"
```

> Passing the password through `MYSQL_PWD` keeps the client from printing the
> "Using a password on the command line interface can be insecure" warning.
> `docker exec` has no TTY, so add `-t` when you want bordered table output.

---

### Wait for Kafka Connect to be ready

```bash
curl -s http://localhost:8083/ | python3 -m json.tool
```

---

### Verify the MySQL binlog is ready for CDC

```bash
# Binary logging on, ROW format, FULL row images, GTIDs enabled
$MYSQL -t -e "SHOW VARIABLES WHERE Variable_name IN ('log_bin','binlog_format','binlog_row_image','gtid_mode','server_id');"

# Current binlog file / position / executed GTID set (MySQL 8.4 syntax)
$MYSQL -e "SHOW BINARY LOG STATUS\G"

# Privileges granted to the Debezium connector user
$MYSQL -t -e "SHOW GRANTS FOR 'debezium'@'%';"
```

---

### Create the demo table

```sql
-- $MYSQL chinook -e "..."
DROP TABLE IF EXISTS demo_events;
CREATE TABLE demo_events (
  id      INT AUTO_INCREMENT PRIMARY KEY,
  event   VARCHAR(255) NOT NULL,
  status  VARCHAR(50),
  payload TEXT,
  ts      DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP
);
-- No per-table enable step: every committed row change is already in the binlog
INSERT INTO demo_events (event, status, payload)
  VALUES ('system_init', 'ready', '{"msg": "pipeline ready"}');
```

---

### Create the MySQL source connector

```bash
curl -i -X POST -H "Accept:application/json" -H "Content-Type:application/json" \
  localhost:8083/connectors/ -d '{
  "name": "mysqlsource",
  "config": {
    "connector.class": "io.debezium.connector.mysql.MySqlConnector",
    "tasks.max": "1",
    "database.hostname": "127.0.0.1",
    "database.port": "3306",
    "database.user": "debezium",
    "database.password": "dbz",
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
}'
```

> `database.server.id` is the replica ID the connector uses when it joins the
> MySQL replication topology — it must differ from the server's own `server_id`
> (`1`) and from any other replica.
>
> The MySQL connector persists captured DDL to a dedicated **schema-history topic**
> (`schema-changes.mysql`). The YugabyteDB connector has no such requirement.

---

### Connector and task status

```bash
# Source connector
curl -s http://localhost:8083/connectors/mysqlsource/status | python3 -m json.tool

# Both connectors (after sink is also registered)
curl -s http://localhost:8083/connectors | python3 -m json.tool
```

---

### Inspect Kafka topics

Topics are named `<topic.prefix>.<database>.<table>`, e.g. `mysql.chinook.Artist` — MySQL has no schema layer between database and table.

```bash
KAFKA_CTR=init-cdc-mysql-ybdb-kafka-1

# List all topics (schema-change topic + schema-history topic + data topics + internal Connect topics)
docker exec $KAFKA_CTR /kafka/bin/kafka-topics.sh \
  --bootstrap-server 127.0.0.1:9092 --list

# Describe a single topic (partitions, replicas, leader)
docker exec $KAFKA_CTR /kafka/bin/kafka-topics.sh \
  --bootstrap-server 127.0.0.1:9092 \
  --describe --topic mysql.chinook.Artist
```

> The bare `mysql` topic (named after `topic.prefix`) carries **schema-change events**
> for consumers that want to react to DDL. The sink's `topics.regex` excludes it.

---

### Create the YugabyteDB JDBC sink connector

```bash
curl -i -X POST -H "Accept:application/json" -H "Content-Type:application/json" \
  localhost:8083/connectors/ -d '{
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
KAFKA_CTR=init-cdc-mysql-ybdb-kafka-1

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

> `CURRENT-OFFSET` shows `-` until the sink commits for the first time. Kafka Connect
> commits sink offsets periodically (`OFFSET_FLUSH_INTERVAL_MS`, set to 5 s here;
> 60 s by default), so a row can already be in YugabyteDB while `LAG` still reads 1–2.

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
-- $MYSQL chinook -e "..."
INSERT INTO demo_events (event, status, payload)
  VALUES ('order_placed', 'pending', '{"item": "guitar", "qty": 2}');

-- sparse row — status and payload are NULL
INSERT INTO demo_events (event, status) VALUES ('payment_pending', 'pending');
```

> **Note:** MySQL `AUTO_INCREMENT` keys are sequential on a single server
> (`auto_increment_increment=1`), so the IDs are predictable: the seed row is `id=1`,
> `order_placed` is `id=2`, `payment_pending` is `id=3`. (This is the opposite of the
> YugabyteDB exercise, where sequence caching jumps IDs to 101, 201, …) The commands
> below capture the actual IDs anyway, so they stay correct across re-runs:

```bash
_id_full=$($MYSQL -N -B chinook -e \
  "SELECT id FROM demo_events WHERE event='order_placed' ORDER BY id DESC LIMIT 1;")
_id_sparse=$($MYSQL -N -B chinook -e \
  "SELECT id FROM demo_events WHERE event='payment_pending' ORDER BY id DESC LIMIT 1;")
echo "order_placed id: $_id_full   payment_pending id: $_id_sparse"
```

> MySQL writes each transaction to the binlog **at commit**, and the connector is
> streaming it like a replica — changes reach Kafka almost immediately (no capture-job
> polling interval as with SQL Server).

Inspect the raw Debezium event for the live insert (offset `0` is the snapshot read of the
seed row, `op=r`; offset `1` is the `order_placed` insert, `op=c`) — payload only:

```bash
docker exec $KAFKA_CTR /kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server 127.0.0.1:9092 \
  --topic mysql.chinook.demo_events \
  --partition 0 --offset 1 --max-messages 1 --timeout-ms 5000 2>/dev/null \
  | python3 -c 'import sys,json; print(json.dumps(json.load(sys.stdin)["payload"], indent=2))'
```

> The `source` block of a streamed MySQL event records the binlog coordinates — `file`,
> `pos`, `row`, `gtid`, `server_id` and `thread` — which is what the connector stores as its
> offset. Snapshot reads carry only `file`/`pos`; `gtid` is `null` and `server_id` is `0`.

Check consumer group offsets (2 events consumed, LAG=0):

```bash
docker exec $KAFKA_CTR /kafka/bin/kafka-consumer-groups.sh \
  --bootstrap-server 127.0.0.1:9092 \
  --describe --group connect-ybsink \
  | grep -E 'TOPIC|demo_events'
```

Verify both rows in YugabyteDB — fully-populated and sparse:

```bash
ysqlsh -h 127.0.0.1 -P null=NULL -c 'SELECT id, event, status, payload FROM demo_events ORDER BY id;'
```

---

### Live CDC — UPDATE (full row)

Update every column on the fully-populated row:

```bash
$MYSQL chinook -e "UPDATE demo_events
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
ysqlsh -h 127.0.0.1 -P null=NULL -c "SELECT id, event, status, payload FROM demo_events WHERE id = $_id_full;"
```

---

### Live CDC — UPDATE (partial / sparse row)

Update only `event` on the sparse row — `status` and `payload` remain NULL:

```bash
$MYSQL chinook -e "UPDATE demo_events SET event='payment_received', status=NULL WHERE id = $_id_sparse;"
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
ysqlsh -h 127.0.0.1 -P null=NULL -c "SELECT id, event, status, payload FROM demo_events WHERE id = $_id_sparse;"
```

---

### Live CDC — DELETE

Delete the confirmed-order row; the seed and sparse rows remain:

```bash
$MYSQL chinook -e "DELETE FROM demo_events WHERE id = $_id_full;"
```

A delete event followed by a tombstone is emitted; the sink issues a `DELETE` in YugabyteDB:

```bash
docker exec $KAFKA_CTR /kafka/bin/kafka-consumer-groups.sh \
  --bootstrap-server 127.0.0.1:9092 \
  --describe --group connect-ybsink \
  | grep -E 'TOPIC|demo_events'

ysqlsh -h 127.0.0.1 -P null=NULL -c 'SELECT id, event, status, payload FROM demo_events ORDER BY id;'
```

---

### Check connector status

```bash
# Source
curl -s http://localhost:8083/connectors/mysqlsource/status | python3 -m json.tool

# Sink
curl -s http://localhost:8083/connectors/ybsink/status | python3 -m json.tool

# All consumer groups
docker exec $KAFKA_CTR /kafka/bin/kafka-consumer-groups.sh \
  --bootstrap-server 127.0.0.1:9092 --list
```

---

### Delete connectors (cleanup)

```bash
curl -X DELETE http://localhost:8083/connectors/mysqlsource
curl -X DELETE http://localhost:8083/connectors/ybsink
```

Optionally drop the demo table in MySQL:

```bash
$MYSQL chinook -e "DROP TABLE IF EXISTS demo_events;"
```

---

### Key notes

- Tables must have a primary key — the Debezium JDBC sink needs a `record_key` to upsert and delete.
- There is **no per-table CDC switch** in MySQL. The binlog is server-wide; the connector chooses what to capture with `database.include.list` / `table.include.list`. Contrast SQL Server, where CDC is enabled per database *and* per table.
- The binlog must be **on, in `ROW` format, with `binlog_row_image=FULL`** — all MySQL 8.x defaults, set explicitly on the container. GTID mode (`gtid_mode=ON`) is optional but lets the connector resume from a position-independent offset after failover.
- The connector user needs `SELECT, RELOAD, SHOW DATABASES, REPLICATION SLAVE, REPLICATION CLIENT` — created as `debezium` in `chinook.sql`. `RELOAD` is for the global read lock taken during the initial snapshot.
- The connector joins the replication topology as a replica, so `database.server.id` must be unique across the MySQL server and all its replicas.
- The connector needs a **schema-history topic** (`schema.history.internal.kafka.topic`) to persist captured DDL; this is specific to log-based connectors like MySQL and SQL Server.
- Topics are named `<topic.prefix>.<database>.<table>` — here `mysql.chinook.<Table>` — with no schema segment, because a MySQL database *is* the schema.
- The sink uses the **standard** `io.debezium.transforms.ExtractNewRecordState` SMT. MySQL change events are plain Debezium envelopes, so unlike the YugabyteDB source (which wraps every field in a `{"value": <v>, "set": true}` struct and needs `YBExtractNewRecordState`), stock unwrapping is enough.
- The sink's auto-created `ts` column gets `DEFAULT '1970-01-01 00:00:00'`, not `CURRENT_TIMESTAMP`: Debezium cannot carry a function default through the schema, so it emits the type's zero value. Every change event carries an explicit `ts`, so replicated rows are unaffected — but pre-create the target table if you need the real default in YugabyteDB.
- `AUTO_INCREMENT` keys are sequential on a single server — the seed row is `id=1`, the first live insert `id=2`, and so on. Contrast the YugabyteDB exercise, where sequence caching (100/node) makes the first live insert `id=101`.
