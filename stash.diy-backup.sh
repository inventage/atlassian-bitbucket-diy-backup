#!/bin/bash

SCRIPT_DIR=$(dirname $0)
# Contains all variables used by the other scripts
source ${SCRIPT_DIR}/stash.diy-backup.vars.sh
# Contains util functions (bail, info, print)
source ${SCRIPT_DIR}/stash.diy-backup.utils.sh
# Contains functions that perform lock/unlock and backup of a stash instance
source ${SCRIPT_DIR}/stash.diy-backup.common.sh

# The following scripts contain functions which are dependant on the configuration of this stash instance.
# Generally every each of them exports certain functions, which can be implemented in different ways

# Exports the following functions
#     stash_prepare_db     - for making a backup of the DB if differential backups a possible. Can be empty
#     stash_backup_db      - for making a backup of the stash DB
source ${SCRIPT_DIR}/stash.diy-backup.postgresql.sh

# Exports the following functions
#     stash_prepare_home   - for preparing the filesystem for the backup
#     stash_backup_home    - for making the actual filesystem backup
source ${SCRIPT_DIR}/stash.diy-backup.rsync.sh

# Exports the following functions
#     stash_backup_archive - for archiving the backup folder and puting the archive in archive folder
source ${SCRIPT_DIR}/stash.diy-backup.tar.sh

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
