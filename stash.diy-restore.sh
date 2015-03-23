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

# Ensure we know which user:group things should be owned as
if [[ -z ${STASH_UID} || -z ${STASH_GID} ]]; then
  error "Both STASH_UID and STASH_GID must be set in stash.diy-backup.vars.sh"
  bail "See stash.diy-backup.vars.sh.example for the defaults."
fi

# The following scripts contain functions which are dependant on the configuration of this stash instance.
# Generally each of them exports certain functions, which can be implemented in different ways

if [ "mssql" == "${BACKUP_DATABASE_TYPE}" ] || [ "postgresql" == "${BACKUP_DATABASE_TYPE}" ] || [ "mysql" == "${BACKUP_DATABASE_TYPE}" ]; then
    # Exports the following functions
    #     stash_restore_db     - for restoring the stash DB
    source ${SCRIPT_DIR}/stash.diy-backup.${BACKUP_DATABASE_TYPE}.sh
else
    error "${BACKUP_DATABASE_TYPE} is not a supported database backup type"
    bail "Please update BACKUP_DATABASE_TYPE in ${BACKUP_VARS_FILE} or consider running stash.diy-aws-restore.sh instead"
fi

if [ "rsync" == "${BACKUP_HOME_TYPE}" ]; then
    # Exports the following functions
    #     stash_restore_home   -  for restoring the filesystem backup
    source ${SCRIPT_DIR}/stash.diy-backup.${BACKUP_HOME_TYPE}.sh
else
    error "${BACKUP_HOME_TYPE} is not a supported home backup type"
    bail "Please update BACKUP_HOME_TYPE in ${BACKUP_VARS_FILE} or consider running stash.diy-aws-restore.sh instead"
fi

# Exports the following functions
#     stash_restore_archive - for un-archiving the archive folder
source ${SCRIPT_DIR}/stash.diy-backup.${BACKUP_ARCHIVE_TYPE}.sh

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

# Check and create STASH_HOME
if [ -e ${STASH_HOME} ]; then
	bail "Cannot restore over existing contents of ${STASH_HOME}. Please rename or delete this first."
fi
mkdir -p ${STASH_HOME}
chown ${STASH_UID}:${STASH_GID} ${STASH_HOME}

# Setup restore paths
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
