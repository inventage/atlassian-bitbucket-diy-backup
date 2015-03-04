#!/bin/bash

SCRIPT_DIR=$(dirname $0)

# Contains util functions (bail, info, print)
source ${SCRIPT_DIR}/stash.diy-backup.utils.sh

# BACKUP_VARS_FILE - allows override for stash.diy-backup.vars.sh
if [ -z "${BACKUP_VARS_FILE}" ]; then
    BACKUP_VARS_FILE=${SCRIPT_DIR}/stash.diy-backup.vars.sh
fi

# Declares other scripts which provide required backup/archive functionality
# Contains all variables used by the other scripts
if [[ -f ${BACKUP_VARS_FILE} ]]; then
    source ${BACKUP_VARS_FILE}
else
    error "${BACKUP_VARS_FILE} not found"
    bail "You should create it using ${SCRIPT_DIR}/stash.diy-backup.vars.sh.example as a template."
fi

# The following scripts contain functions which are dependant on the configuration of this stash instance.
# Generally every each of them exports certain functions, which can be implemented in different ways

# Exports aws specific function to be used during the restore
source ${SCRIPT_DIR}/stash.diy-backup.ec2-common.sh

# Exports the following functions
#     stash_restore_db     - for restoring the stash DB
source ${SCRIPT_DIR}/stash.diy-backup.${BACKUP_DATABASE_TYPE}.sh

# Exports the following functions
#     stash_restore_home   -  for restoring the filesystem backup
source ${SCRIPT_DIR}/stash.diy-backup.${BACKUP_HOME_TYPE}.sh

##########################################################
# The actual restore process. It has the following steps

# Restore the database
stash_restore_db

# Restore the filesystem
stash_restore_home

##########################################################
