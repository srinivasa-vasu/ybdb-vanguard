[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/srinivasa-vasu/ybdb-vanguard?devcontainer_path=.devcontainer%2Finit-cdc-sqlserver-ybdb%2Fdevcontainer.json)

## Change data capture workflow from SQL Server to YugabyteDB

SQL Server acts as the CDC source using native **SQL Server Change Data Capture (CDC)** tables and SQL Server Agent jobs.
The **Debezium SQL Server connector** (`io.debezium.connector.sqlserver.SqlServerConnector`) consumes changes from SQL Server and publishes change events to Kafka.
A **Debezium JDBC sink connector** (`io.debezium.connector.jdbc.JdbcSinkConnector`) consumes those events from Kafka and writes them to the YugabyteDB target database.

**Quick start:** Four terminals open automatically:
- **`cdc-sqlserver-ybdb-demo`** — guided demo: run `bash prompt.sh` for the full walkthrough
- **`cdc-sqlserver-ybdb-ws`** — Workshop shell for the manual commands below
- **`sqlserver`** — SQL Server command-line client (`sqlcmd`)
- **`ysql`** — YugabyteDB command-line client (`ysqlsh`)

Run all manual `curl` / `docker exec` commands from the `cdc-sqlserver-ybdb-ws` shell.

---

### Wait for Kafka Connect to be ready

```bash
curl -s http://localhost:8083/ | python3 -m json.tool
```

---

### Create the demo table and enable CDC in SQL Server

Inside the `sqlserver` terminal (or via `docker exec`):

```sql
USE [chinook];
GO

DROP TABLE IF EXISTS dbo.demo_events;
CREATE TABLE dbo.demo_events (
  id      INT IDENTITY(1,1) PRIMARY KEY,
  event   VARCHAR(255)  NOT NULL,
  status  VARCHAR(50),
  payload VARCHAR(MAX),
  ts      DATETIME2     NOT NULL DEFAULT CURRENT_TIMESTAMP
);
GO

-- Enable CDC on the newly created table
EXEC sys.sp_cdc_enable_table
    @source_schema = N'dbo',
    @source_name = N'demo_events',
    @role_name = NULL;
GO
```

Insert events into the `demo_events` table in the `sqlserver` terminal:

```sql
USE [chinook];
GO

INSERT INTO dbo.demo_events (event, status, payload)
VALUES ('order_placed', 'pending', '{"item": "keyboard", "qty": 2}');

INSERT INTO dbo.demo_events (event, status)
VALUES ('payment_pending', 'pending');
GO
```

---

### Create the SQL Server source connector

Register the Debezium SQL Server connector to capture tables:

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
    "database.encrypt": "false",
    "topic.prefix": "sqlserver",
    "table.include.list": "dbo.Artist,dbo.Album,dbo.Track,dbo.demo_events",
    "schema.history.internal.kafka.bootstrap.servers": "127.0.0.1:9092",
    "schema.history.internal.kafka.topic": "schema-changes.sqlserver",
    "errors.retry.timeout": "2000",
    "errors.log.enable": "true",
    "errors.log.include.messages": "true",
    "database.encrypt": "false"
  }
}'
```

Confirm that the connector starts up and transitions to `RUNNING`:

```bash
curl -s http://localhost:8083/connectors/mssqlsource/status | python3 -m json.tool
```

---

### Inspect Kafka topics

```bash
KAFKA_CTR=init-cdc-sqlserver-ybdb-kafka-1

# List all topics (including the internal database history topic + table data topics)
docker exec $KAFKA_CTR /kafka/bin/kafka-topics.sh \
  --bootstrap-server 127.0.0.1:9092 --list
```

---

### Create the YugabyteDB JDBC sink connector

We register the Debezium JDBC sink connector. This will read records from Kafka and write them into YugabyteDB. The connector uses `ExtractNewRecordState` SMT to flatten Debezium envelopes, and `RegexRouter` to strip `sqlserver.dbo.` topic prefixes:

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

Verify that the sink connector task status is `RUNNING`:

```bash
curl -s http://localhost:8083/connectors/ybsink/status | python3 -m json.tool
```

---

### Monitor consumer group offsets and lag

The sink connector reads events under the consumer group name `connect-ybsink`:

```bash
docker exec $KAFKA_CTR /kafka/bin/kafka-consumer-groups.sh \
  --bootstrap-server 127.0.0.1:9092 \
  --describe --group connect-ybsink
```

When all partition offsets show `LAG=0`, the initial snapshot is fully loaded into YugabyteDB.

---

### Verify snapshot in YugabyteDB

Inside your `ysql` terminal (or running `ysqlsh`):

```sql
SELECT COUNT(*) AS artists FROM Artist;
SELECT COUNT(*) AS albums  FROM Album;
SELECT COUNT(*) AS tracks  FROM Track;
```

---

### Live CDC — INSERT

Insert new events in the `sqlserver` terminal:

```sql
USE [chinook];
GO

INSERT INTO dbo.demo_events (event, status, payload)
VALUES ('order_placed', 'pending', '{"item": "guitar", "qty": 2}');

INSERT INTO dbo.demo_events (event, status)
VALUES ('payment_pending', 'pending');
GO
```

Find the generated IDs in SQL Server:

```sql
SELECT id, event, status FROM dbo.demo_events;
```

In the `ysql` terminal, query the replicated table to verify that the rows propagated:

```sql
SELECT id, event, status, payload FROM demo_events ORDER BY id;
```

---

### Live CDC — UPDATE

Update a record in the `sqlserver` terminal (e.g. updating the record with `id = 1`):

```sql
USE [chinook];
GO

UPDATE dbo.demo_events
SET event = 'order_confirmed', status = 'confirmed', payload = '{"item": "guitar", "qty": 5}'
WHERE id = 3;
GO
```

Query the YugabyteDB database (`ysql`) to verify the update:

```sql
SELECT id, event, status, payload FROM demo_events WHERE id = 3;
```

---

### Live CDC — DELETE

Delete a record in the `sqlserver` terminal:

```sql
USE [chinook];
GO

DELETE FROM dbo.demo_events WHERE id = 3;
GO
```

Query the YugabyteDB database (`ysql`) to verify the row is deleted:

```sql
SELECT id, event, status, payload FROM demo_events ORDER BY id;
```

---

### Key notes

- **SQL Server Agent requirement**: SQL Server Agent must be running. If the SQL Server Agent container job is stopped, row modifications will not populate the underlying system CDC tables, and Debezium will not capture changes.
- **Database History**: The SQL Server connector stores schema history inside the Kafka topic `schema-changes.sqlserver` using `schema.history.internal.kafka.topic`.
- **Target database schema evolution**: We set `"schema.evolution": "basic"` in the JDBC sink, which automatically creates the target tables in YugabyteDB matching the source schema during the initial snapshot.
