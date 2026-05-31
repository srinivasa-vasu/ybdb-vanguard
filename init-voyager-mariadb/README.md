## Data migration workflow from MariaDB to YugabyteDB

Run **pre-step** from the `mariadb` shell, then **Steps 1–8** from the `yb-voyager` shell.

---

### Pre-step: Load source data

Run from the `mariadb` shell:

```sql
source init-voyager-mariadb/chinook.sql
```

---

### Step 1: Assess Migration

```
yb-voyager assess-migration --export-dir ${PWD}/${DATA_PATH} \
        --source-db-type ${SRC_DB_TYPE} \
        --source-db-host ${HOST} \
        --source-db-user ${SRC_USER} \
        --source-db-password ${SRC_SECRET} \
        --source-db-name ${SRC_DB_ID}
```

Review the generated report under `${DATA_PATH}/reports/`.

### Step 2: Export Schema

```
yb-voyager export schema --export-dir ${PWD}/${DATA_PATH} \
        --source-db-type ${SRC_DB_TYPE} \
        --source-db-host ${HOST} \
        --source-db-user ${SRC_USER} \
        --source-db-password ${SRC_SECRET} \
        --source-db-name ${SRC_DB_ID}
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
        --source-db-name ${SRC_DB_ID}
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
