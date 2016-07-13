#!/bin/bash

set -e

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

if [ "mssql" = "${BACKUP_DATABASE_TYPE}" -o "postgresql" = "${BACKUP_DATABASE_TYPE}" -o "mysql" = "${BACKUP_DATABASE_TYPE}" ]; then
    # Exports the following functions
    #     bitbucket_restore_db     - for restoring the bitbucket DB
    source ${SCRIPT_DIR}/bitbucket.diy-backup.${BACKUP_DATABASE_TYPE}.sh
else
    error "${BACKUP_DATABASE_TYPE} is not a supported database backup type"
    bail "Please update BACKUP_DATABASE_TYPE in ${BACKUP_VARS_FILE} or consider running bitbucket.diy-aws-restore.sh instead"
fi

if [ "rsync" = "${BACKUP_HOME_TYPE}" ]; then
    # Exports the following functions
    #     bitbucket_restore_home   -  for restoring the filesystem backup
    source ${SCRIPT_DIR}/bitbucket.diy-backup.${BACKUP_HOME_TYPE}.sh
else
    error "${BACKUP_HOME_TYPE} is not a supported home backup type"
    bail "Please update BACKUP_HOME_TYPE in ${BACKUP_VARS_FILE} or consider running bitbucket.diy-aws-restore.sh instead"
fi

# Exports the following functions
#     bitbucket_restore_archive - for un-archiving the archive folder
source ${SCRIPT_DIR}/bitbucket.diy-backup.${BACKUP_ARCHIVE_TYPE}.sh

##########################################################
# The actual restore process. It has the following steps

function available_backups {
	echo "Available backups:"  > /dev/stderr
	ls ${BITBUCKET_BACKUP_ARCHIVE_ROOT}
}

if [ $# -lt 1 ]; then
    echo "Usage: $0 <backup-file-name>.tar.gz"  > /dev/stderr
    if [ ! -d ${BITBUCKET_BACKUP_ARCHIVE_ROOT} ]; then
        error "${BITBUCKET_BACKUP_ARCHIVE_ROOT} does not exist!"
    else
        available_backups
    fi
    exit 99
fi
BITBUCKET_BACKUP_ARCHIVE_NAME=$1
if [ ! -f ${BITBUCKET_BACKUP_ARCHIVE_ROOT}/${BITBUCKET_BACKUP_ARCHIVE_NAME} ]; then
	error "${BITBUCKET_BACKUP_ARCHIVE_ROOT}/${BITBUCKET_BACKUP_ARCHIVE_NAME} does not exist!"
	available_backups
	exit 99
fi

bitbucket_bail_if_db_exists

# Check and create BITBUCKET_HOME
if [ -e ${BITBUCKET_HOME} ]; then
	bail "Cannot restore over existing contents of ${BITBUCKET_HOME}. Please rename or delete this first."
fi
mkdir -p ${BITBUCKET_HOME}
chown ${BITBUCKET_UID}:${BITBUCKET_GID} ${BITBUCKET_HOME}

# Setup restore paths
BITBUCKET_RESTORE_ROOT=`mktemp -d /tmp/bitbucket.diy-restore.XXXXXX`
BITBUCKET_RESTORE_DB=${BITBUCKET_RESTORE_ROOT}/bitbucket-db
BITBUCKET_RESTORE_HOME=${BITBUCKET_RESTORE_ROOT}/bitbucket-home

# Extract the archive for this backup
bitbucket_restore_archive

# Restore the database
bitbucket_restore_db

# Restore the filesystem
bitbucket_restore_home

##########################################################
