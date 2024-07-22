## Live data migration workflow from postgresql to ybdb

### Export schema and data from the source database and import into the target database

#### Step -1: Load data
Run only Step -1 from `psql` shell
```
\i init-voyager-postgres/chinook.sql
```

Run Step 0 to Step 2 from `yb-voyager-export` shell

#### Step 0: Assess Migration
yb-voyager assess-migration --export-dir ${GITPOD_REPO_ROOT}/${DATA_PATH} \
  --source-db-type ${SRC_DB_TYPE} \
  --source-db-host ${SRC_HOST} \
  --source-db-user ${SRC_USER} \
  --source-db-password ${SRC_SECRET} \
  --source-db-name ${SRC_DB_ID} --source-db-schema ${SOURCE_DB_SCHEMA}

#### Step 1: Export Schema
```
yb-voyager export schema --export-dir ${GITPOD_REPO_ROOT}/${DATA_PATH} \
        --source-db-type ${SRC_DB_TYPE} \
        --source-db-host ${HOST} \
        --source-db-user ${SRC_USER} \
        --source-db-password ${SRC_SECRET} \
        --source-db-name ${SRC_DB_ID} --source-db-schema ${SOURCE_DB_SCHEMA}
```

#### Step 2: Analyze Schema
```
yb-voyager analyze-schema --export-dir ${GITPOD_REPO_ROOT}/${DATA_PATH} --output-format html
```

Run Step 3 from `yb-voyager-import` shell

#### Step 3: Import Schema
```
yb-voyager import schema --export-dir ${GITPOD_REPO_ROOT}/${DATA_PATH} \
        --target-db-host ${HOST} \
        --target-db-user ${TARGET_USER} \
        --target-db-password ${TARGET_SECRET} \
        --target-db-name ${TARGET_DB_ID} \
        --target-db-schema ${SCHEMA}
```

Run Step 4 from `yb-voyager-export` shell

#### Step 4: Export Data
```
yb-voyager export data from source --export-dir ${GITPOD_REPO_ROOT}/${DATA_PATH} \
        --source-db-type ${SRC_DB_TYPE} \
        --source-db-host ${HOST} \
        --source-db-user ${SRC_USER} \
        --source-db-password ${SRC_SECRET} \
        --source-db-name ${SRC_DB_ID} --source-db-schema ${SOURCE_DB_SCHEMA} --export-type snapshot-and-changes
```

Run Step 5 from `yb-voyager-import` shell

#### Step 5: Import Data
```
yb-voyager import data to target --export-dir ${GITPOD_REPO_ROOT}/${DATA_PATH} \
        --target-db-host ${HOST} \
        --target-db-user ${TARGET_USER} \
        --target-db-password ${TARGET_SECRET} \
        --target-db-name ${TARGET_DB_ID} \
        --target-db-schema ${SCHEMA}
```

Run Step 6 to Step 10 from `yb-voyager-wa` shell

#### Step 6: Get migration report
```
yb-voyager get data-migration-report --export-dir ${GITPOD_REPO_ROOT}/${DATA_PATH} \
        --target-db-password ${TARGET_SECRET}
```

#### Step 7: Cutover to the target
```
yb-voyager initiate cutover to target --export-dir ${GITPOD_REPO_ROOT}/${DATA_PATH} --prepare-for-fall-back false

```

#### Step 8: Check cutover status
```
yb-voyager cutover status --export-dir ${GITPOD_REPO_ROOT}/${DATA_PATH} --prepare-for-fall-back false

```

#### Step 9: Import indexes and triggers
```
yb-voyager import schema --export-dir ${GITPOD_REPO_ROOT}/${DATA_PATH} \
        --target-db-host ${HOST} \
        --target-db-user ${TARGET_USER} \
        --target-db-password ${TARGET_SECRET} \
        --target-db-name ${TARGET_DB_ID} \
        --target-db-schema ${SCHEMA} --post-snapshot-import true --refresh-mviews true
```

### Step 10: Check the imported data status
```
yb-voyager end migration --export-dir ${GITPOD_REPO_ROOT}/${DATA_PATH} --backup-log-files yes --backup-data-files no --backup-schema-files no --save-migration-reports yes --backup-dir ${GITPOD_REPO_ROOT}/${DATA_PATH}/backup
```
