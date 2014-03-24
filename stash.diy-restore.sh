#!/bin/bash

SCRIPT_DIR=$(dirname $0)
# Contains all variables used by the other scripts
source ${SCRIPT_DIR}/stash.diy-backup.vars.sh
# Contains util functions (bail, info, print)
source ${SCRIPT_DIR}/stash.diy-backup.utils.sh

# The following scripts contain functions which are dependant on the configuration of this stash instance.
# Generally every each of them exports certain functions, which can be implemented in different ways

# Exports the following functions
#     stash_restore_db     - for restoring the stash DB
source ${SCRIPT_DIR}/stash.diy-backup.postgresql.sh

# Exports the following functions
#     stash_restore_home   -  for restoring the filesystem backup
source ${SCRIPT_DIR}/stash.diy-backup.rsync.sh

# Exports the following functions
#     stash_restore_archive - for un-archiving the archive folder
source ${SCRIPT_DIR}/stash.diy-backup.tar.sh

##########################################################
# The actual restore process. It has the following steps

function available_backups {
	echo "Available backups:"
	ls ${STASH_BACKUP_ARCHIVE_ROOT}
}

if [ $# -lt 1 ]; then
    echo "Usage: $0 <backup-file-name>.tar.gz"
    if [ ! -d ${STASH_BACKUP_ARCHIVE_ROOT} ]; then
        error "${STASH_BACKUP_ARCHIVE_ROOT} does not exist!"
    else
        available_backups
    fi
    exit 99
fi
STASH_BACKUP_ARCHIVE_NAME=$1
if [ ! -f ${STASH_BACKUP_ARCHIVE_ROOT}/${STASH_BACKUP_ARCHIVE_NAME} ]; then
	error "${STASH_BACKUP_ARCHIVE_ROOT}/${STASH_BACKUP_ARCHIVE_NAME} does not exist!"
	available_backups
	exit 99
fi
stash_bail_if_db_exists
if [ -e ${STASH_HOME} ]; then
	bail "Cannot restore over existing contents of ${STASH_HOME}. Please rename or delete this first."
fi
STASH_RESTORE_ROOT=`mktemp -d /tmp/stash.diy-restore.XXXXXX`
STASH_RESTORE_DB=${STASH_RESTORE_ROOT}/stash-db
STASH_RESTORE_HOME=${STASH_RESTORE_ROOT}/stash-home

# Extract the archive for this backup
stash_restore_archive

# Restore the database
stash_restore_db

# Restore the filesystem
stash_restore_home

##########################################################
