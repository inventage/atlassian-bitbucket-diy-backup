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
source_archive_strategy
source_database_strategy
source_home_strategy
source_elasticsearch_strategy

# Ensure compatibility if BACKUP_ZERO_DOWNTIME is set
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

##########################################################

info "Preparing for backup"
prepare_backup_db
prepare_backup_home
prepare_backup_elasticsearch

# If necessary, lock Bitbucket, start an external backup and wait for instance readiness
lock_bitbucket
backup_start

# Run Elasticsearch backup in the background (if not configured, this will be a No-Operation)
backup_elasticsearch &

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

# Cleanup backups retaining the latest $KEEP_BACKUPS
cleanup_db_backups
cleanup_home_backups
cleanup_elasticsearch_backups

if [ -n "${BACKUP_ARCHIVE_TYPE}" ]; then
    info "Archiving backups and cleaning up old archives"
    archive_backup
    cleanup_old_archives
fi

