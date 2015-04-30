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
    bail "You should create it using ${SCRIPT_DIR}/stash.diy-backup.vars.sh.example as a template"
fi

# Contains functions that perform lock/unlock and backup of a stash instance
source ${SCRIPT_DIR}/stash.diy-backup.common.sh

# The following scripts contain functions which are dependent on the configuration of this stash instance.
# Generally each of them exports certain functions, which can be implemented in different ways

if [ "rsync" == "${BACKUP_HOME_TYPE}" ]; then
    # Exports the following functions
    #     stash_prepare_home   - for preparing the filesystem for the backup
    #     stash_backup_home    - for making the actual filesystem backup
    source ${SCRIPT_DIR}/stash.diy-backup.${BACKUP_HOME_TYPE}.sh
else
    error "${BACKUP_HOME_TYPE} is not a supported home backup type"
    bail "Please update BACKUP_HOME_TYPE in ${BACKUP_VARS_FILE} or consider running stash.diy-aws-backup.sh instead"
fi

if [ "mssql" == "${BACKUP_DATABASE_TYPE}" ] || [ "postgresql" == "${BACKUP_DATABASE_TYPE}" ] || [ "mysql" == "${BACKUP_DATABASE_TYPE}" ]; then
    # Exports the following functions
    #     stash_prepare_db     - for making a backup of the DB if differential backups a possible. Can be empty
    #     stash_backup_db      - for making a backup of the stash DB
    source ${SCRIPT_DIR}/stash.diy-backup.${BACKUP_DATABASE_TYPE}.sh
else
    error "${BACKUP_DATABASE_TYPE} is not a supported database backup type"
    bail "Please update BACKUP_DATABASE_TYPE in ${BACKUP_VARS_FILE} or consider running stash.diy-aws-backup.sh instead"
fi

# Exports the following functions
#     stash_backup_archive - for archiving the backup folder and puting the archive in archive folder
source ${SCRIPT_DIR}/stash.diy-backup.${BACKUP_ARCHIVE_TYPE}.sh

##########################################################
# The actual proposed backup process. It has the following steps

# Prepare the database and the filesystem for taking a backup
stash_prepare_db
stash_prepare_home

# Locking the stash instance, starting an external backup and waiting for instance readiness
stash_lock
stash_backup_start
stash_backup_wait

# Backing up the database and reporting 50% progress
stash_backup_db
stash_backup_progress 50

# Backing up the filesystem and reporting 100% progress
stash_backup_home
stash_backup_progress 100

# Unlocking the stash instance
stash_unlock

# Making an archive for this backup
stash_backup_archive

##########################################################
