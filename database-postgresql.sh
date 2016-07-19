#!/bin/bash

# -------------------------------------------------------------------------------------
# A backup and restore strategy for PostgreSQL with "pg_dump" and "pg_restore" commands.
# -------------------------------------------------------------------------------------

check_command "pg_dump"
check_command "psql"
check_command "pg_restore"

SCRIPT_DIR=$(dirname "$0")
source "${SCRIPT_DIR}/utils.sh"

function prepare_backup_db {
    no_op
}

function backup_db {
    rm -r "${BITBUCKET_BACKUP_DB}"
    run pg_dump -U "${POSTGRES_USERNAME}" -h "${POSTGRES_HOST}" --port=${POSTGRES_PORT} ${PG_PARALLEL} -Fd \
        "${BITBUCKET_DB}" ${PG_SNAPSHOT_OPT} -f "${BITBUCKET_BACKUP_DB}"
}

function prepare_restore_db {
    run psql -U "${POSTGRES_USERNAME}" -h "${POSTGRES_HOST}" --port=${POSTGRES_PORT} -d "${BITBUCKET_DB}" -c ''
}

function restore_db {
    run pg_restore -U "${POSTGRES_USERNAME}" -h "${POSTGRES_HOST}" --port=${POSTGRES_PORT} -d postgres -C -Fd \
        ${PG_PARALLEL} "${BITBUCKET_RESTORE_DB}"
}
