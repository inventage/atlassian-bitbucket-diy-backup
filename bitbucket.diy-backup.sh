#!/bin/bash

# Ensure the script terminates whenever a required operation encounters an error
set -e

SCRIPT_DIR=$(dirname $0)
source ${SCRIPT_DIR}/bitbucket.diy-backup.utils.sh
source ${SCRIPT_DIR}/bitbucket.diy-backup.common.sh

BACKUP_VARS_FILE=${BACKUP_VARS_FILE:-"${SCRIPT_DIR}"/bitbucket.diy-backup.vars.sh}

if [ -f ${BACKUP_VARS_FILE} ]; then
    source ${BACKUP_VARS_FILE}
    info "Using vars file: ${BACKUP_VARS_FILE}"
else
    error "${BACKUP_VARS_FILE} not found"
    bail "You should create it using ${SCRIPT_DIR}/bitbucket.diy-backup.vars.sh.example as a template"
fi

# The following scripts contain functions which are dependent on the configuration of this bitbucket instance.
# Generally each of them exports certain functions, which can be implemented in different ways

if [ -e "${SCRIPT_DIR}/bitbucket.diy-backup.${BACKUP_HOME_TYPE}.sh" ]; then
    source ${SCRIPT_DIR}/bitbucket.diy-backup.${BACKUP_HOME_TYPE}.sh
else
    error "BACKUP_HOME_TYPE=${BACKUP_HOME_TYPE} is not implemented, ${SCRIPT_DIR}/bitbucket.diy-backup.${BACKUP_HOME_TYPE}.sh does not exist"
    bail "Please update BACKUP_HOME_TYPE in ${BACKUP_VARS_FILE}"
fi

if [ -e "${SCRIPT_DIR}/bitbucket.diy-backup.${BACKUP_DATABASE_TYPE}.sh" ]; then
    source ${SCRIPT_DIR}/bitbucket.diy-backup.${BACKUP_DATABASE_TYPE}.sh
else
    error "BACKUP_DATABASE_TYPE=${BACKUP_DATABASE_TYPE} is not implemented, ${SCRIPT_DIR}/bitbucket.diy-backup.${BACKUP_DATABASE_TYPE}.sh does not exist"
    bail "Please update BACKUP_DATABASE_TYPE in ${BACKUP_VARS_FILE}"
fi

if [ -e "${SCRIPT_DIR}/bitbucket.diy-backup.${BACKUP_ARCHIVE_TYPE}.sh" ]; then
    source ${SCRIPT_DIR}/bitbucket.diy-backup.${BACKUP_ARCHIVE_TYPE}.sh
fi

##########################################################

# Prepare the database and the filesystem for taking a backup
bitbucket_prepare_db
bitbucket_prepare_home

# If necessary, lock Bitbucket, start an external backup and wait for instance readiness
bitbucket_lock
bitbucket_backup_start
bitbucket_backup_wait

# Back up the database and filesystem in parallel, reporting progress
(bitbucket_backup_db && bitbucket_backup_progress 50) &
(bitbucket_backup_home && bitbucket_backup_progress 50) &

# Wait until home and database backups are complete
wait $(jobs -p)

# If necessary, report 100% progress back to the application, and unlock Bitbucket
bitbucket_backup_progress 100
bitbucket_unlock

success "Successfully completed the backup of your ${PRODUCT} instance"

if [ -n "${BACKUP_ARCHIVE_TYPE}" ]; then
    bitbucket_backup_archive
    bitbucket_cleanup
fi