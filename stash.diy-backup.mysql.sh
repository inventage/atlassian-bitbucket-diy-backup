#!/bin/bash

check_command "mysqldump"
check_command "mysqlshow"
check_command "mysql"

# Use -h option if MYSQL_HOST is set
if [[ -n ${MYSQL_HOST} ]]; then
    MYSQL_HOST_CMD="-h ${MYSQL_HOST}"
fi

function stash_prepare_db {
    info "Prepared backup of DB ${STASH_DB} in ${STASH_BACKUP_DB}"
}

function stash_backup_db {
    rm -r ${STASH_BACKUP_DB}
    mysqldump ${MYSQL_HOST_CMD} ${MYSQL_BACKUP_OPTIONS} -u ${MYSQL_USERNAME} -p${MYSQL_PASSWORD} ${STASH_DB} > ${STASH_BACKUP_DB}
    if [ $? != 0 ]; then
        bail "Unable to backup ${STASH_DB} to ${STASH_BACKUP_DB}"
    fi
    info "Performed backup of DB ${STASH_DB} in ${STASH_BACKUP_DB}"
}

function stash_bail_if_db_exists {
    mysqlshow ${MYSQL_HOST_CMD} -u ${MYSQL_USERNAME} -p${MYSQL_PASSWORD} ${STASH_DB}
    if [ $? = 0 ]; then
        bail "Cannot restore over existing database ${STASH_DB}. Try renaming or droping ${STASH_DB} first."
    fi
}

function stash_restore_db {
    mysql ${MYSQL_HOST_CMD} -u ${MYSQL_USERNAME} -p${MYSQL_PASSWORD} ${STASH_DB} < ${STASH_RESTORE_DB}
    if [ $? != 0 ]; then
        bail "Unable to restore ${STASH_RESTORE_DB} to ${STASH_DB}"
    fi
    info "Performed restore of ${STASH_RESTORE_DB} to DB ${STASH_DB}"
}
