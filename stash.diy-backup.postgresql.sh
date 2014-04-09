#!/bin/bash

check_command "pg_dump"
check_command "psql"
check_command "pg_restore"

function stash_prepare_db {
    info "Prepared backup of DB ${STASH_DB} in ${STASH_BACKUP_DB}"
}

function stash_backup_db {
    rm -r ${STASH_BACKUP_DB}
    pg_dump -Fd ${STASH_DB} -j 5 --no-synchronized-snapshots -f ${STASH_BACKUP_DB}
    if [ $? != 0 ]; then
        bail "Unable to backup ${STASH_DB} to ${STASH_BACKUP_DB}"
    fi
    info "Performed backup of DB ${STASH_DB} in ${STASH_BACKUP_DB}"
}

function stash_bail_if_db_exists {
    psql -d ${STASH_DB} -c '' >/dev/null 2>&1
    if [ $? = 0 ]; then
        bail "Cannot restore over existing database ${STASH_DB}. Try dropdb ${STASH_DB} first."
    fi
}

function stash_restore_db {
    pg_restore -C -Fd -j 5 ${STASH_RESTORE_DB} | psql -q
    if [ $? != 0 ]; then
        bail "Unable to restore ${STASH_RESTORE_DB} to ${STASH_DB}"
    fi
    info "Performed restore of ${STASH_RESTORE_DB} to DB ${STASH_DB}"
}
