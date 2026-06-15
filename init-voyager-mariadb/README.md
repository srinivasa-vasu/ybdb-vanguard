[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/srinivasa-vasu/ybdb-vanguard?devcontainer_path=.devcontainer%2Finit-voyager-mariadb%2Fdevcontainer.json)

## Data migration workflow from MariaDB to YugabyteDB

**Quick start:** The `mariadb-demo` terminal opens automatically — run `bash prompt.sh` for the guided demo.
The `yb-voyager` terminal is available for running commands manually.

Run **`bash prompt.sh`** from the `mariadb-demo` shell — it loads Chinook and runs all steps automatically.

---

### Pre-step: Load source data

The guided demo handles this automatically. The full Chinook dataset (~3 500 tracks, 412 invoices, 59 customers) is downloaded from [lerocha/chinook-database](https://github.com/lerocha/chinook-database) at `postCreateCommand` time into `chinook_data.sql`.

To load manually from the `mariadb-demo` shell:

```bash
docker-compose -f compose.yml exec -T mysql mariadb -uroot -p${SRC_SECRET} < chinook_data.sql
```

---

### Step 1: Assess Migration

```
yb-voyager assess-migration --export-dir /workspaces/ybdb-vanguard/init-voyager-mariadb/voyager-data \
        --source-db-type ${SRC_DB_TYPE} \
        --source-db-host ${SRC_HOST:-mariadb} \
        --source-db-user ${SRC_USER} \
        --source-db-password ${SRC_SECRET} \
        --source-db-name ${SRC_DB_ID} \
        --source-db-schema ${SRC_DB_ID}
```

Review the generated report under `init-voyager-mariadb/voyager-data/reports/`.

### Step 2: Export Schema

```
yb-voyager export schema --export-dir /workspaces/ybdb-vanguard/init-voyager-mariadb/voyager-data \
        --source-db-type ${SRC_DB_TYPE} \
        --source-db-host ${SRC_HOST:-mariadb} \
        --source-db-user ${SRC_USER} \
        --source-db-password ${SRC_SECRET} \
        --source-db-name ${SRC_DB_ID} \
        --source-db-schema ${SRC_DB_ID}
```

### Step 3: Analyze Schema

```
yb-voyager analyze-schema --export-dir /workspaces/ybdb-vanguard/init-voyager-mariadb/voyager-data --output-format txt
```

### Step 4: Export Data

```
yb-voyager export data --export-dir /workspaces/ybdb-vanguard/init-voyager-mariadb/voyager-data \
        --source-db-type ${SRC_DB_TYPE} \
        --source-db-host ${SRC_HOST:-mariadb} \
        --source-db-user ${SRC_USER} \
        --source-db-password ${SRC_SECRET} \
        --source-db-name ${SRC_DB_ID} \
        --source-db-schema ${SRC_DB_ID}
```

Check export progress:

```
yb-voyager export data status --export-dir /workspaces/ybdb-vanguard/init-voyager-mariadb/voyager-data
```

---

### Step 5: Import Schema

```
yb-voyager import schema --export-dir /workspaces/ybdb-vanguard/init-voyager-mariadb/voyager-data \
        --target-db-host 127.0.0.1 \
        --target-db-user ${TARGET_USER} \
        --target-db-password ${TARGET_SECRET} \
        --target-db-name ${TARGET_DB_ID} \
        --target-db-schema ${SCHEMA}
```

### Step 6: Import Data

```
yb-voyager import data --export-dir /workspaces/ybdb-vanguard/init-voyager-mariadb/voyager-data \
        --target-db-host 127.0.0.1 \
        --target-db-user ${TARGET_USER} \
        --target-db-password ${TARGET_SECRET} \
        --target-db-name ${TARGET_DB_ID} \
        --target-db-schema ${SCHEMA}
```

Check import progress:

```
yb-voyager import data status --export-dir /workspaces/ybdb-vanguard/init-voyager-mariadb/voyager-data
```

---

### Step 7: Finalize Schema (indexes, triggers, constraints)

```
yb-voyager finalize-schema-post-data-import --export-dir /workspaces/ybdb-vanguard/init-voyager-mariadb/voyager-data \
        --target-db-host 127.0.0.1 \
        --target-db-user ${TARGET_USER} \
        --target-db-password ${TARGET_SECRET} \
        --target-db-name ${TARGET_DB_ID} \
        --target-db-schema ${SCHEMA}
```

### Step 8: End Migration

```
yb-voyager end migration --export-dir /workspaces/ybdb-vanguard/init-voyager-mariadb/voyager-data \
        --backup-log-files yes \
        --backup-data-files no \
        --backup-schema-files yes \
        --save-migration-reports yes \
        --backup-dir /workspaces/ybdb-vanguard/init-voyager-mariadb/voyager-data/backup
```
