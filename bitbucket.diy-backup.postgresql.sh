#!/bin/bash

check_command "pg_dump"
check_command "psql"
check_command "pg_restore"

# Contains util functions (bail, info, print)
SCRIPT_DIR=$(dirname $0)
source ${SCRIPT_DIR}/bitbucket.diy-backup.utils.sh

# Make use of PostgreSQL 9.3+ options if available
psql_version="$(psql --version | awk '{print $3}')"
psql_majorminor="$(printf "%d%03d" $(echo "$psql_version" | tr "." "\n" | head -n 2))"
if [[ $psql_majorminor -ge 9003 ]]; then
    PG_PARALLEL="-j 5"
    PG_SNAPSHOT_OPT="--no-synchronized-snapshots"
fi

# Use username if configured
if [[ -n ${POSTGRES_USERNAME} ]]; then
    PG_USER="-U ${POSTGRES_USERNAME}"
fi

# Use password if configured
if [[ -n ${POSTGRES_PASSWORD} ]]; then
    export PGPASSWORD="${POSTGRES_PASSWORD}"
fi

# Use -h option if POSTGRES_HOST is set
if [[ -n ${POSTGRES_HOST} ]]; then
    PG_HOST="-h ${POSTGRES_HOST}"
fi

# Default port
if [[ -z ${POSTGRES_PORT} ]]; then
    POSTGRES_PORT=5432
fi

function bitbucket_prepare_db {
    info "Prepared backup of DB ${BITBUCKET_DB} in ${BITBUCKET_BACKUP_DB}"
}

function bitbucket_backup_db {
    rm -r "${BITBUCKET_BACKUP_DB}"
    run pg_dump "${PG_USER}" "${PG_HOST}" --port=${POSTGRES_PORT} ${PG_PARALLEL} -Fd "${BITBUCKET_DB}" ${PG_SNAPSHOT_OPT} \
        -f "${BITBUCKET_BACKUP_DB}"
}

function bitbucket_bail_if_db_exists {
    run psql "${PG_USER}" "${PG_HOST}" --port=${POSTGRES_PORT} -d "${BITBUCKET_DB}" -c ''
}

function bitbucket_restore_db {
    run pg_restore "${PG_USER}" "${PG_HOST}" --port=${POSTGRES_PORT} -d postgres -C -Fd ${PG_PARALLEL} "${BITBUCKET_RESTORE_DB}"
}

function bitbucket_cleanup_db_backups {
    no_op
}