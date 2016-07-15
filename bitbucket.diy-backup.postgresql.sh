#!/bin/bash

check_command "pg_dump"
check_command "psql"
check_command "pg_restore"

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
    rm -r ${BITBUCKET_BACKUP_DB}
    pg_dump ${PG_USER} ${PG_HOST} --port=${POSTGRES_PORT} ${PG_PARALLEL} -Fd ${BITBUCKET_DB} ${PG_SNAPSHOT_OPT} -f ${BITBUCKET_BACKUP_DB}
    if [ $? != 0 ]; then
        bail "Unable to backup ${BITBUCKET_DB} to ${BITBUCKET_BACKUP_DB}"
    fi
    info "Performed backup of DB ${BITBUCKET_DB} in ${BITBUCKET_BACKUP_DB}"
}

function bitbucket_bail_if_db_exists {
    psql ${PG_USER} ${PG_HOST} --port=${POSTGRES_PORT} -d ${BITBUCKET_DB} -c '' > /dev/null 2>&1
    if [ $? = 0 ]; then
        bail "Cannot restore over existing database ${BITBUCKET_DB}. Try dropdb ${BITBUCKET_DB} first."
    fi
}

function bitbucket_restore_db {
    pg_restore ${PG_USER} ${PG_HOST} --port=${POSTGRES_PORT} -d postgres -C -Fd ${PG_PARALLEL} ${BITBUCKET_RESTORE_DB}
    if [ $? != 0 ]; then
        bail "Unable to restore ${BITBUCKET_RESTORE_DB} to ${BITBUCKET_DB}"
    fi
    info "Performed restore of ${BITBUCKET_RESTORE_DB} to DB ${BITBUCKET_DB}"
}

function bitbucket_cleanup_db_backups {
    no_op
}

function bitbucket_prepare_restore_db {
    bitbucket_bail_if_db_exists
    no_op
}