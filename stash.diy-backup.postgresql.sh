#!/bin/bash

check_command "pg_dump"
check_command "psql"
check_command "pg_restore"

# Make use of PostgreSQL 9.3+ options if available
psql_version="$(psql --version | awk '{print $3}')"
psql_majorminor="$(printf "%03d%03d" $(echo "$psql_version" | tr "." "\n" | head -n 2))"
if [[ $psql_majorminor -ge 009003 ]]; then
    PG_PARALLELL="-j 5"
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

function stash_prepare_db {
    info "Prepared backup of DB ${STASH_DB} in ${STASH_BACKUP_DB}"
}

function stash_backup_db {
    rm -r ${STASH_BACKUP_DB}
    pg_dump ${PG_USER} ${PG_HOST} --port=${POSTGRES_PORT} ${PG_PARALLELL} -Fd ${STASH_DB} ${PG_SNAPSHOT_OPT} -f ${STASH_BACKUP_DB}
    if [ $? != 0 ]; then
        bail "Unable to backup ${STASH_DB} to ${STASH_BACKUP_DB}"
    fi
    info "Performed backup of DB ${STASH_DB} in ${STASH_BACKUP_DB}"
}

function stash_bail_if_db_exists {
    psql ${PG_USER} ${PG_HOST} --port=${POSTGRES_PORT} -d ${STASH_DB} -c '' >/dev/null 2>&1
    if [ $? = 0 ]; then
        bail "Cannot restore over existing database ${STASH_DB}. Try dropdb ${STASH_DB} first."
    fi
}

function stash_restore_db {
    pg_restore ${PG_USER} ${PG_HOST} --port=${POSTGRES_PORT} -d postgres -C -Fd ${PG_PARALLEL} ${STASH_RESTORE_DB}
    if [ $? != 0 ]; then
        bail "Unable to restore ${STASH_RESTORE_DB} to ${STASH_DB}"
    fi
    info "Performed restore of ${STASH_RESTORE_DB} to DB ${STASH_DB}"
}
