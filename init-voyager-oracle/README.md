[![Open in GitHub Codespaces](https://github.com/codespaces/badge.svg)](https://codespaces.new/srinivasa-vasu/ybdb-vanguard?devcontainer_path=.devcontainer%2Finit-voyager-oracle%2Fdevcontainer.json)

## Data migration workflow from Oracle to YugabyteDB

Run **pre-step** from the `oracle` shell, then **Steps 1–8** from the `yb-voyager` shell.

---

### Pre-step: Load source data

First, copy the Chinook schema into the Oracle client container:

```bash
docker cp init-voyager-oracle/chinook.sql oracle-client:/tmp/chinook.sql
```

Then run from the `oracle` shell:

```sql
@/tmp/chinook.sql
```

---

### Step 1: Assess Migration

```
yb-voyager assess-migration --export-dir ${PWD}/${DATA_PATH} \
        --source-db-type ${SRC_DB_TYPE} \
        --source-db-host ${HOST} \
        --source-db-user ${SRC_USER} \
        --source-db-password ${SRC_SECRET} \
        --source-db-name ${ORACLE_PDB}
```

Review the generated report under `${DATA_PATH}/reports/`.

### Step 2: Export Schema

```
yb-voyager export schema --export-dir ${PWD}/${DATA_PATH} \
        --source-db-type ${SRC_DB_TYPE} \
        --source-db-host ${HOST} \
        --source-db-user ${SRC_USER} \
        --source-db-password ${SRC_SECRET} \
        --source-db-name ${ORACLE_PDB}
```

### Step 3: Analyze Schema

```
yb-voyager analyze-schema --export-dir ${PWD}/${DATA_PATH} --output-format html
```

### Step 4: Export Data

```
yb-voyager export data --export-dir ${PWD}/${DATA_PATH} \
        --source-db-type ${SRC_DB_TYPE} \
        --source-db-host ${HOST} \
        --source-db-user ${SRC_USER} \
        --source-db-password ${SRC_SECRET} \
        --source-db-name ${ORACLE_PDB}
```

Check export progress:

```
yb-voyager export data status --export-dir ${PWD}/${DATA_PATH}
```

---

### Step 5: Import Schema

```
yb-voyager import schema --export-dir ${PWD}/${DATA_PATH} \
        --target-db-host ${HOST} \
        --target-db-user ${TARGET_USER} \
        --target-db-password ${TARGET_SECRET} \
        --target-db-name ${TARGET_DB_ID} \
        --target-db-schema ${SCHEMA}
```

### Step 6: Import Data

```
yb-voyager import data --export-dir ${PWD}/${DATA_PATH} \
        --target-db-host ${HOST} \
        --target-db-user ${TARGET_USER} \
        --target-db-password ${TARGET_SECRET} \
        --target-db-name ${TARGET_DB_ID} \
        --target-db-schema ${SCHEMA}
```

Check import progress:

```
yb-voyager import data status --export-dir ${PWD}/${DATA_PATH}
```

---

### Step 7: Finalize Schema (indexes, triggers, constraints)

```
yb-voyager finalize-schema-post-data-import --export-dir ${PWD}/${DATA_PATH} \
        --target-db-host ${HOST} \
        --target-db-user ${TARGET_USER} \
        --target-db-password ${TARGET_SECRET} \
        --target-db-name ${TARGET_DB_ID} \
        --target-db-schema ${SCHEMA}
```

### Step 8: End Migration

```
yb-voyager end migration --export-dir ${PWD}/${DATA_PATH} \
        --backup-log-files yes \
        --backup-data-files no \
        --backup-schema-files yes \
        --save-migration-reports yes \
        --backup-dir ${PWD}/${DATA_PATH}/backup
```
