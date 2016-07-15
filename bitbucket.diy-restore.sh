#!/bin/bash

SCRIPT_DIR=$(dirname $0)

# Contains util functions (bail, info, print)
source ${SCRIPT_DIR}/bitbucket.diy-backup.utils.sh

# BACKUP_VARS_FILE - allows override for bitbucket.diy-backup.vars.sh
if [ -z "${BACKUP_VARS_FILE}" ]; then
    BACKUP_VARS_FILE=${SCRIPT_DIR}/bitbucket.diy-backup.vars.sh
fi

# Declares other scripts which provide required backup/archive functionality
# Contains all variables used by the other scripts
if [[ -f ${BACKUP_VARS_FILE} ]]; then
    source ${BACKUP_VARS_FILE}
else
    error "${BACKUP_VARS_FILE} not found"
    bail "You should create it using ${SCRIPT_DIR}/bitbucket.diy-backup.vars.sh.example as a template."
fi

# Ensure we know which user:group things should be owned as
if [[ -z ${BITBUCKET_UID} || -z ${BITBUCKET_GID} ]]; then
    error "Both BITBUCKET_UID and BITBUCKET_GID must be set in bitbucket.diy-backup.vars.sh"
    bail "See bitbucket.diy-backup.vars.sh.example for the defaults."
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
else
    error "BACKUP_DATABASE_TYPE=${BACKUP_ARCHIVE_TYPE} is not implemented, ${SCRIPT_DIR}/bitbucket.diy-backup.${BACKUP_DATABASE_TYPE}.sh does not exist"
    bail "Please update BACKUP_DATABASE_TYPE in ${BACKUP_VARS_FILE}"
fi

##########################################################

# Prepare for restore process
prepare_restore_home "${1}"
prepare_restore_db "${1}"

if [ -n "${BACKUP_ARCHIVE_TYPE}" ]; then
    prepare_restore_archive "${1}"
    restore_archive "${1}"
fi

# Restore the filesystem
restore_home

# Restore the database
restore_db

success "Successfully completed the restore of your ${PRODUCT} instance"