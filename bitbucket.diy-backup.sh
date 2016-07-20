#!/bin/bash

# -------------------------------------------------------------------------------------
# The DIY backup script.
#
# This script is invoked to perform the backup of a Bitbucket Server,
# or Bitbucket Data Center instance. It requires a properly configured
# bitbucket.diy-backup.vars.sh file, which can be copied from
# bitbucket.diy-backup.vars.sh.example and customized.
# -------------------------------------------------------------------------------------

# Ensure the script terminates whenever a required operation encounters an error
set -e

SCRIPT_DIR=$(dirname "$0")
source "${SCRIPT_DIR}/utils.sh"
source "${SCRIPT_DIR}/common.sh"

BACKUP_VARS_FILE=${BACKUP_VARS_FILE:-"${SCRIPT_DIR}"/bitbucket.diy-backup.vars.sh}

if [ -f "${BACKUP_VARS_FILE}" ]; then
    source "${BACKUP_VARS_FILE}"
    info "Using vars file: '${BACKUP_VARS_FILE}'"
else
    error "'${BACKUP_VARS_FILE}' not found"
    bail "You should create it using '${SCRIPT_DIR}/bitbucket.diy-backup.vars.sh.example' as a template"
fi

if [ "${BACKUP_ZERO_DOWNTIME}" = "true" ]; then
    if [ "${BACKUP_HOME_TYPE}" = "rsync" ]; then
        error "BACKUP_HOME_TYPE=rsync cannot be used with BACKUP_ZERO_DOWNTIME=true"
        bail "Please update ${BACKUP_VARS_FILE}"
    fi
    version=($(bitbucket_version))
    if [ "${#version[@]}" -lt 2 ]; then
        error "Unable to determine the version of Bitbucket at '${BITBUCKET_URL}'"
        error "You need a minimum of Bitbucket 4.8 to restore a backup taken with BACKUP_ZERO_DOWNTIME=true"
        error "See https://confluence.atlassian.com/display/BitbucketServer/Using+Bitbucket+Zero+Downtime+Backup."
        bail "Please update ${BACKUP_VARS_FILE}"
    elif [ "${version[0]}" -lt 4 -o "${version[0]}" -eq 4 -a "${version[1]}" -lt 8 ]; then
        error "Bitbucket version ${version[0]}.${version[1]} does not support BACKUP_ZERO_DOWNTIME=true"
        error "You need a minimum of Bitbucket 4.8 to restore a backup taken with BACKUP_ZERO_DOWNTIME=true"
        error "See https://confluence.atlassian.com/display/BitbucketServer/Using+Bitbucket+Zero+Downtime+Backup."
        bail "Please update ${BACKUP_VARS_FILE}"
    fi
fi

if [ -e "${SCRIPT_DIR}/home-${BACKUP_HOME_TYPE}.sh" ]; then
    source "${SCRIPT_DIR}/home-${BACKUP_HOME_TYPE}.sh"
else
    error "BACKUP_HOME_TYPE=${BACKUP_HOME_TYPE} is not implemented, '${SCRIPT_DIR}/home-${BACKUP_HOME_TYPE}.sh' does not exist"
    bail "Please update BACKUP_HOME_TYPE in '${BACKUP_VARS_FILE}'"
fi

if [ -e "${SCRIPT_DIR}/database-${BACKUP_DATABASE_TYPE}.sh" ]; then
    source "${SCRIPT_DIR}/database-${BACKUP_DATABASE_TYPE}.sh"
else
    error "BACKUP_DATABASE_TYPE=${BACKUP_DATABASE_TYPE} is not implemented, '${SCRIPT_DIR}/database-${BACKUP_DATABASE_TYPE}.sh' does not exist"
    bail "Please update BACKUP_DATABASE_TYPE in '${BACKUP_VARS_FILE}'"
fi

if [ -e "${SCRIPT_DIR}/archive-${BACKUP_ARCHIVE_TYPE}.sh" ]; then
    source "${SCRIPT_DIR}/archive-${BACKUP_ARCHIVE_TYPE}.sh"
fi

##########################################################

info "Preparing the database and the filesystem for backup"
prepare_backup_db
prepare_backup_home

# If necessary, lock Bitbucket, start an external backup and wait for instance readiness
lock_bitbucket
backup_start
backup_wait

info "Backing up the database and filesystem in parallel"
(backup_db && update_backup_progress 50) &
(backup_home && update_backup_progress 50) &

# Wait until home and database backups are complete
wait $(jobs -p)

# If necessary, report 100% progress back to the application, and unlock Bitbucket
update_backup_progress 100
unlock_bitbucket

success "Successfully completed the backup of your ${PRODUCT} instance"

if [ -n "${BACKUP_ARCHIVE_TYPE}" ]; then
    info "Archiving backups and cleaning up old archives"
    archive_backup
    cleanup_old_archives
fi
