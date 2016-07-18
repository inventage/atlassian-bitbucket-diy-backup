#!/bin/bash

check_command "mysqldump"
check_command "mysqlshow"
check_command "mysql"

# Contains util functions (bail, info, print)
SCRIPT_DIR=$(dirname "$0")
source "${SCRIPT_DIR}/utils.sh"

# Use -h option if MYSQL_HOST is set
if [[ -n ${MYSQL_HOST} ]]; then
    MYSQL_HOST_CMD="-h ${MYSQL_HOST}"
fi

function prepare_backup_db {
    info "Prepared backup of DB ${BITBUCKET_DB} in ${BITBUCKET_BACKUP_DB}"
}

function backup_db {
    rm -r "${BITBUCKET_BACKUP_DB}"
    run mysqldump "${MYSQL_HOST_CMD}" "${MYSQL_BACKUP_OPTIONS}" -u "${MYSQL_USERNAME}" -p"${MYSQL_PASSWORD}" \
        --databases "${BITBUCKET_DB}" > "${BITBUCKET_BACKUP_DB}"
}

function prepare_restore_db {
    run mysqlshow "${MYSQL_HOST_CMD}" -u "${MYSQL_USERNAME}" -p"${MYSQL_PASSWORD}" "${BITBUCKET_DB}"
}

function restore_db {
    run mysql "${MYSQL_HOST_CMD}" -u "${MYSQL_USERNAME}" -p"${MYSQL_PASSWORD}" < "${BITBUCKET_RESTORE_DB}"
}
