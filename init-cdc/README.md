[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/srinivasa-vasu/ybdb-vanguard?devcontainer_path=.devcontainer%2Finit-cdc%2Fdevcontainer.json)

## Change data capture workflow from YugabyteDB to PostgreSQL

YugabyteDB acts as the CDC source using **PostgreSQL logical replication** (`yboutput` plugin).  
The **YugabyteDB Debezium connector** (`io.debezium.connector.yugabytedb.YugabyteDBConnector`) consumes the replication stream and publishes change events to Kafka.  
A **Confluent JDBC sink connector** writes those events to the PostgreSQL sink.

**Quick start:** Two terminals open automatically:
- **`cdc-demo`** — guided demo: run `bash prompt.sh` for the full walkthrough
- **`connector-config`** — ad-hoc shell for curl/yb-admin commands

Run all manual `curl` commands below from the `connector-config` shell.

---

### Wait for Kafka Connect to be ready

```bash
curl -s http://localhost:8083/ | python3 -m json.tool
```

---

### Verify logical replication is active on YugabyteDB

```sql
-- Run from ysqlsh
SELECT slot_name, plugin, slot_type, active FROM pg_replication_slots;
SELECT pubname, puballtables FROM pg_publication;
```

Both will be empty before the connector is registered. The connector creates the replication slot and publication automatically.

---

### Create the YugabyteDB source connector

```bash
curl -i -X POST -H "Accept:application/json" -H "Content-Type:application/json" \
  localhost:8083/connectors/ -d '{
  "name": "ybsource",
  "config": {
    "tasks.max": "1",
    "connector.class": "io.debezium.connector.yugabytedb.YugabyteDBConnector",
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

After registration, confirm the replication slot and publication were created:

```sql
-- Run from ysqlsh
SELECT slot_name, plugin, slot_type, active FROM pg_replication_slots;
SELECT schemaname, tablename FROM pg_publication_tables;
```

---

### Create the PostgreSQL JDBC sink connector

```bash
curl -i -X POST -H "Accept:application/json" -H "Content-Type:application/json" \
  localhost:8083/connectors/ -d '{
  "name": "pgsink",
  "config": {
    "connector.class": "io.confluent.connect.jdbc.JdbcSinkConnector",
    "tasks.max": "1",
    "topics.regex": "'$TOPIC_PREFIX'.'$SCHEMA'.(.*)",
    "dialect.name": "PostgreSqlDatabaseDialect",
    "connection.url": "jdbc:postgresql://localhost:5432/'$TAR_DB_OBJECT'?user='$TAR_USER'&password='$TAR_SECRET'",
    "auto.create": "true",
    "auto.evolve": "true",
    "insert.mode": "upsert",
    "pk.mode": "record_key",
    "delete.enabled": "true",
    "transforms": "dropPrefix, unwrap",
    "transforms.dropPrefix.type": "org.apache.kafka.connect.transforms.RegexRouter",
    "transforms.dropPrefix.regex": "'$TOPIC_PREFIX'.'$SCHEMA'.(.*)",
    "transforms.dropPrefix.replacement": "$1",
    "transforms.unwrap.type": "io.debezium.transforms.ExtractNewRecordState",
    "transforms.unwrap.drop.tombstones": "false",
    "errors.retry.timeout": "2000",
    "errors.log.enable": "true",
    "errors.log.include.messages": "true"
  }
}'
```

---

### Verify CDC is working

Insert or update a row in YugabyteDB and confirm it appears in PostgreSQL:

```sql
-- YugabyteDB (ysqlsh)
INSERT INTO public."Artist" VALUES (999, 'Test Artist');
UPDATE public."Artist" SET "Name" = 'Updated Artist' WHERE "ArtistId" = 999;
```

```bash
# PostgreSQL sink
psql -h 127.0.0.1 -p 5432 -U postgres -c 'SELECT * FROM "Artist" WHERE "ArtistId" = 999;'
```

---

### Check connector status

```bash
# List all registered connectors
curl -s http://localhost:8083/connectors | python3 -m json.tool

# Source connector status
curl -s http://localhost:8083/connectors/ybsource/status | python3 -m json.tool

# Sink connector status
curl -s http://localhost:8083/connectors/pgsink/status | python3 -m json.tool
```

---

### Delete connectors (cleanup)

```bash
curl -X DELETE http://localhost:8083/connectors/ybsource
curl -X DELETE http://localhost:8083/connectors/pgsink
```

Drop the replication slot to allow WAL reclamation:

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
