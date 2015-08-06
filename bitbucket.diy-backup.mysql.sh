#!/bin/bash

check_command "mysqldump"
check_command "mysqlshow"
check_command "mysql"

# Use -h option if MYSQL_HOST is set
if [[ -n ${MYSQL_HOST} ]]; then
    MYSQL_HOST_CMD="-h ${MYSQL_HOST}"
fi

function bitbucket_prepare_db {
    info "Prepared backup of DB ${BITBUCKET_DB} in ${BITBUCKET_BACKUP_DB}"
}

function bitbucket_backup_db {
    rm -r ${BITBUCKET_BACKUP_DB}
    mysqldump ${MYSQL_HOST_CMD} ${MYSQL_BACKUP_OPTIONS} -u ${MYSQL_USERNAME} -p${MYSQL_PASSWORD} ${BITBUCKET_DB} > ${BITBUCKET_BACKUP_DB}
    if [ $? != 0 ]; then
        bail "Unable to backup ${BITBUCKET_DB} to ${BITBUCKET_BACKUP_DB}"
    fi
    info "Performed backup of DB ${BITBUCKET_DB} in ${BITBUCKET_BACKUP_DB}"
}

function bitbucket_bail_if_db_exists {
    mysqlshow ${MYSQL_HOST_CMD} -u ${MYSQL_USERNAME} -p${MYSQL_PASSWORD} ${BITBUCKET_DB}
    if [ $? = 0 ]; then
        bail "Cannot restore over existing database ${BITBUCKET_DB}. Try renaming or droping ${BITBUCKET_DB} first."
    fi
}

function bitbucket_restore_db {
    mysql ${MYSQL_HOST_CMD} -u ${MYSQL_USERNAME} -p${MYSQL_PASSWORD} ${BITBUCKET_DB} < ${BITBUCKET_RESTORE_DB}
    if [ $? != 0 ]; then
        bail "Unable to restore ${BITBUCKET_RESTORE_DB} to ${BITBUCKET_DB}"
    fi
    info "Performed restore of ${BITBUCKET_RESTORE_DB} to DB ${BITBUCKET_DB}"
}
