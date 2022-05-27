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

if [ "${INSTANCE_TYPE}" = "bitbucket-mesh" ]; then
    # Mesh nodes don't run with an external database, so it doesn't need to be backed up
    BACKUP_DATABASE_TYPE="none"
    # Mesh nodes don't run with an external Elasticsearch instance configured, so it doesn't need to be backed up
    BACKUP_ELASTICSEARCH_TYPE="none"
fi

source_archive_strategy
source_database_strategy
source_disk_strategy
source_elasticsearch_strategy

# Ensure compatibility if BACKUP_ZERO_DOWNTIME is set
if [ "${BACKUP_ZERO_DOWNTIME}" = "true" ]; then
    if [ "${BACKUP_DISK_TYPE}" = "rsync" ]; then
        error "BACKUP_DISK_TYPE=rsync cannot be used with BACKUP_ZERO_DOWNTIME=true"
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

check_command "jq"

##########################################################

readonly DB_BACKUP_JOB_NAME="Database backup"
readonly DISK_BACKUP_JOB_NAME="Disk backup"
readonly ES_BACKUP_JOB_NAME="Elasticsearch backup"

# Started background jobs
declare -A BG_JOBS
# Successfully completed background jobs
declare -a COMPLETED_BG_JOBS
# Failed background jobs
declare -A FAILED_BG_JOBS

# Run a command in the background and record its PID so we can wait for its completion
function run_in_bg {
    ($1) &
    local PID=$!
    BG_JOBS["$2"]=${PID}
    debug "Started $2 (PID=${PID})"
}

# Wait for all tracked background jobs (i.e. jobs recorded in 'BG_JOBS') to finish. If one or more jobs return a
# non-zero exit code, we log an error for each and return a non-zero value to fail the backup.
function wait_for_bg_jobs {
    for bg_job_name in "${!BG_JOBS[@]}"; do
        local PID=${BG_JOBS[${bg_job_name}]}
        debug "Waiting for ${bg_job_name} (PID=${PID})"
        {
            wait ${PID}
        } &&  {
            debug "${bg_job_name} finished successfully (PID=${PID})"
            COMPLETED_BG_JOBS+=("${bg_job_name}")
            update_backup_progress 50
        } || {
            FAILED_BG_JOBS["${bg_job_name}"]=$?
        }
    done

    if (( ${#FAILED_BG_JOBS[@]} )); then
        for bg_job_name in "${!FAILED_BG_JOBS[@]}"; do
            error "${bg_job_name} failed with status ${FAILED_BG_JOBS[${bg_job_name}]} (PID=${PID})"
        done
        return 1
    fi
}

# Clean up after a failed backup
function cleanup_incomplete_backup {
    debug "Cleaning up after failed backup"
    for bg_job_name in "${COMPLETED_BG_JOBS[@]}"; do
        case "$bg_job_name" in
            "$ES_BACKUP_JOB_NAME")
                cleanup_incomplete_elasticsearch_backup ;;
            "$DB_BACKUP_JOB_NAME")
                cleanup_incomplete_db_backup ;;
            "$DISK_BACKUP_JOB_NAME")
                cleanup_incomplete_disk_backup ;;
            *)
                error "No cleanup task defined for backup type: $bg_job_name" ;;
        esac
    done
}

##########################################################

info "Preparing for backup"
prepare_backup_db
prepare_backup_disk

# If necessary, lock Bitbucket, start an external backup and wait for instance readiness
lock_bitbucket
backup_start

# Run Elasticsearch backup in the background (if not configured, this will be a No-Operation)
run_in_bg backup_elasticsearch "$ES_BACKUP_JOB_NAME"

backup_wait

info "Backing up the database and filesystem in parallel"
run_in_bg backup_db "$DB_BACKUP_JOB_NAME"
run_in_bg backup_disk "$DISK_BACKUP_JOB_NAME"

{
    wait_for_bg_jobs
} || {
    unlock_bitbucket
    cleanup_incomplete_backup || error "Failed to cleanup incomplete backup"
    error "Backing up ${PRODUCT} failed"
    exit 1
}

# If necessary, report 100% progress back to the application, and unlock Bitbucket
update_backup_progress 100
unlock_bitbucket

success "Successfully completed the backup of your ${PRODUCT} instance"

# Cleanup backups retaining the latest $KEEP_BACKUPS
cleanup_old_db_backups
cleanup_old_disk_backups
cleanup_old_elasticsearch_backups

if [ -n "${BACKUP_ARCHIVE_TYPE}" ]; then
    info "Archiving backups and cleaning up old archives"
    archive_backup
    cleanup_old_archives
fi
