## Live data migration workflow from PostgreSQL to YugabyteDB

Run **pre-step** from the `psql` shell.  
Run **Steps 0–2** from the `yb-voyager-export` shell.  
Run **Step 3** from the `yb-voyager-import` shell.  
Run **Step 4** from the `yb-voyager-export` shell.  
Run **Step 5** from the `yb-voyager-import` shell (keep running alongside Step 4).  
Run **Steps 6–11** from the `yb-voyager-wa` shell.

---

### Pre-step: Load source data

Run from the `psql` shell:

```
\i init-voyager-postgres/chinook.sql
```

---

### Step 0: Assess Migration

```
yb-voyager assess-migration --export-dir ${PWD}/${DATA_PATH} \
  --source-db-type ${SRC_DB_TYPE} \
  --source-db-host ${SRC_HOST} \
  --source-db-user ${SRC_USER} \
  --source-db-password ${SRC_SECRET} \
  --source-db-name ${SRC_DB_ID} \
  --source-db-schema ${SOURCE_DB_SCHEMA}
```

### Step 1: Export Schema

```
yb-voyager export schema --export-dir ${PWD}/${DATA_PATH} \
        --source-db-type ${SRC_DB_TYPE} \
        --source-db-host ${HOST} \
        --source-db-user ${SRC_USER} \
        --source-db-password ${SRC_SECRET} \
        --source-db-name ${SRC_DB_ID} \
        --source-db-schema ${SOURCE_DB_SCHEMA}
```

### Step 2: Analyze Schema

```
yb-voyager analyze-schema --export-dir ${PWD}/${DATA_PATH} --output-format html
```

---

### Step 3: Import Schema

```
yb-voyager import schema --export-dir ${PWD}/${DATA_PATH} \
        --target-db-host ${HOST} \
        --target-db-user ${TARGET_USER} \
        --target-db-password ${TARGET_SECRET} \
        --target-db-name ${TARGET_DB_ID} \
        --target-db-schema ${SCHEMA}
```

---

### Step 4: Export Data (keep running — captures snapshot then streams changes)

```
yb-voyager export data from source --export-dir ${PWD}/${DATA_PATH} \
        --source-db-type ${SRC_DB_TYPE} \
        --source-db-host ${HOST} \
        --source-db-user ${SRC_USER} \
        --source-db-password ${SRC_SECRET} \
        --source-db-name ${SRC_DB_ID} \
        --source-db-schema ${SOURCE_DB_SCHEMA} \
        --export-type snapshot-and-changes
```

### Step 5: Import Data (run alongside Step 4)

```
yb-voyager import data to target --export-dir ${PWD}/${DATA_PATH} \
        --target-db-host ${HOST} \
        --target-db-user ${TARGET_USER} \
        --target-db-password ${TARGET_SECRET} \
        --target-db-name ${TARGET_DB_ID} \
        --target-db-schema ${SCHEMA}
```

---

### Step 6: Get migration report

```
yb-voyager get data-migration-report --export-dir ${PWD}/${DATA_PATH} \
        --target-db-password ${TARGET_SECRET}
```

### Step 7: Cutover to the target

```
yb-voyager initiate cutover to target --export-dir ${PWD}/${DATA_PATH} \
        --prepare-for-fall-back false
```

### Step 8: Check cutover status

```
yb-voyager cutover status --export-dir ${PWD}/${DATA_PATH}
```

### Step 9: Finalize Schema (indexes, triggers, materialized views)

```
yb-voyager finalize-schema-post-data-import --export-dir ${PWD}/${DATA_PATH} \
        --target-db-host ${HOST} \
        --target-db-user ${TARGET_USER} \
        --target-db-password ${TARGET_SECRET} \
        --target-db-name ${TARGET_DB_ID} \
        --target-db-schema ${SCHEMA} \
        --refresh-mviews true
```

### Step 10: Archive Changes

```
yb-voyager archive changes --export-dir ${PWD}/${DATA_PATH} \
        --policy delete-on-success
```

### Step 11: End Migration

```
yb-voyager end migration --export-dir ${PWD}/${DATA_PATH} \
        --backup-log-files yes \
        --backup-data-files no \
        --backup-schema-files no \
        --save-migration-reports yes \
        --backup-dir ${PWD}/${DATA_PATH}/backup
```
