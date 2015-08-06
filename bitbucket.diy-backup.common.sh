#!/bin/bash

check_command "curl"
check_command "jq"

BITBUCKET_HTTP_AUTH="-u ${BITBUCKET_BACKUP_USER}:${BITBUCKET_BACKUP_PASS}"

# The name of the product
PRODUCT=Bitbucket

function bitbucket_lock {
    BITBUCKET_LOCK_RESULT=`curl ${CURL_OPTIONS} ${BITBUCKET_HTTP_AUTH} -X POST -H "Content-type: application/json" "${BITBUCKET_URL}/mvc/maintenance/lock"`
    if [ -z "${BITBUCKET_LOCK_RESULT}" ]; then
        bail "Locking this Bitbucket instance failed"
    fi

    BITBUCKET_LOCK_TOKEN=`echo ${BITBUCKET_LOCK_RESULT} | jq -r ".unlockToken"`
    if [ -z "${BITBUCKET_LOCK_TOKEN}" ]; then
        bail "Unable to find lock token. Result was '$BITBUCKET_LOCK_RESULT'"
    fi

    info "locked with '$BITBUCKET_LOCK_TOKEN'"
}

function bitbucket_backup_start {
    BITBUCKET_BACKUP_RESULT=`curl ${CURL_OPTIONS} ${BITBUCKET_HTTP_AUTH} -X POST -H "X-Atlassian-Maintenance-Token: ${BITBUCKET_LOCK_TOKEN}" -H "Accept: application/json" -H "Content-type: application/json" "${BITBUCKET_URL}/mvc/admin/backups?external=true"`
    if [ -z "${BITBUCKET_BACKUP_RESULT}" ]; then
        bail "Entering backup mode failed"
    fi

    BITBUCKET_BACKUP_TOKEN=`echo ${BITBUCKET_BACKUP_RESULT} | jq -r ".cancelToken"`
    if [ -z "${BITBUCKET_BACKUP_TOKEN}" ]; then
        bail "Unable to find backup token. Result was '${BITBUCKET_BACKUP_RESULT}'"
    fi

    info "backup started with '${BITBUCKET_BACKUP_TOKEN}'"
}

function bitbucket_backup_wait {
    BITBUCKET_PROGRESS_DB_STATE="AVAILABLE"
    BITBUCKET_PROGRESS_SCM_STATE="AVAILABLE"

    print -n "[${BITBUCKET_URL}]  INFO: Waiting for DRAINED state"
    while [ "${BITBUCKET_PROGRESS_DB_STATE}_${BITBUCKET_PROGRESS_SCM_STATE}" != "DRAINED_DRAINED" ]; do
        print -n "."

        BITBUCKET_PROGRESS_RESULT=`curl ${CURL_OPTIONS} ${BITBUCKET_HTTP_AUTH} -X GET -H "X-Atlassian-Maintenance-Token: ${BITBUCKET_LOCK_TOKEN}" -H "Accept: application/json" -H "Content-type: application/json" "${BITBUCKET_URL}/mvc/maintenance"`
        if [ -z "${BITBUCKET_PROGRESS_RESULT}" ]; then
            bail "[${BITBUCKET_URL}] ERROR: Unable to check for backup progress"
        fi

        BITBUCKET_PROGRESS_DB_STATE=`echo ${BITBUCKET_PROGRESS_RESULT} | jq -r '.["db-state"]'`
        BITBUCKET_PROGRESS_SCM_STATE=`echo ${BITBUCKET_PROGRESS_RESULT} | jq -r '.["scm-state"]'`
        BITBUCKET_PROGRESS_STATE=`echo ${BITBUCKET_PROGRESS_RESULT} | jq -r '.task.state'`

        if [ "${BITBUCKET_PROGRESS_STATE}" != "RUNNING" ]; then
            error "Unable to start backup, try unlocking"
            bitbucket_unlock
            bail "Failed to start backup"
        fi
    done

    print " done"
    info "db state '${BITBUCKET_PROGRESS_DB_STATE}'"
    info "scm state '${BITBUCKET_PROGRESS_SCM_STATE}'"
}

function bitbucket_backup_progress {
    BITBUCKET_REPORT_RESULT=`curl ${CURL_OPTIONS} ${BITBUCKET_HTTP_AUTH} -X POST -H "Accept: application/json" -H "Content-type: application/json" "${BITBUCKET_URL}/mvc/admin/backups/progress/client?token=${BITBUCKET_LOCK_TOKEN}&percentage=$1"`
    if [ $? != 0 ]; then
        bail "Unable to update backup progress"
    fi

    info "Backup progress updated to $1"
}

function bitbucket_unlock {
    BITBUCKET_UNLOCK_RESULT=`curl ${CURL_OPTIONS} ${BITBUCKET_HTTP_AUTH} -X DELETE -H "Accept: application/json" -H "Content-type: application/json" "${BITBUCKET_URL}/mvc/maintenance/lock?token=${BITBUCKET_LOCK_TOKEN}"`
    if [ $? != 0 ]; then
        bail "Unable to unlock instance with lock ${BITBUCKET_LOCK_TOKEN}"
    fi

    info "Bitbucket instance unlocked"
}

function freeze_mount_point {
    info "Freezing filesystem at mount point ${1}"

    sudo fsfreeze -f ${1} > /dev/null
}

function unfreeze_mount_point {
    info "Unfreezing filesystem at mount point ${1}"

    sudo fsfreeze -u ${1} > /dev/null 2>&1
}

function mount_device {
    local DEVICE_NAME="$1"
    local MOUNT_POINT="$2"

    sudo mount "${DEVICE_NAME}" "${MOUNT_POINT}" > /dev/null
    success "Mounted device ${DEVICE_NAME} to ${MOUNT_POINT}"
}

function add_cleanup_routine() {
    cleanup_queue+=($1)
    trap run_cleanup EXIT
}

function run_cleanup() {
    info "Cleaning up..."
    for cleanup in ${cleanup_queue[@]}
    do
        ${cleanup}
    done
}

function check_mount_point {
    local MOUNT_POINT="${1}"

    # mountpoint check will return a non-zero exit code when mount point is free
    mountpoint -q "${MOUNT_POINT}"
    if [ $? == 0 ]; then
        error "The directory mount point ${MOUNT_POINT} appears to be taken"
        bail "Please stop Bitbucket. Stop PostgreSQL if it is running. Unmount the device and detach the volume"
    fi
}

# This removes config.lock, index.lock, gc.pid, and refs/heads/*.lock
function cleanup_locks {
    local HOME_DIRECTORY="$1"

    # From the shopt man page:
    # globstar
    #           If set, the pattern ‘**’ used in a filename expansion context will match all files and zero or
    #           more directories and subdirectories. If the pattern is followed by a ‘/’, only directories and subdirectories match.
    shopt -s globstar

    # Remove lock files in the repositories
    sudo -u ${BITBUCKET_UID} rm -f ${HOME_DIRECTORY}/shared/data/repositories/*/{HEAD,config,index,gc,packed-refs,stash-packed-refs}.{pid,lock}
    sudo -u ${BITBUCKET_UID} rm -f ${HOME_DIRECTORY}/shared/data/repositories/*/refs/**/*.lock
    sudo -u ${BITBUCKET_UID} rm -f ${HOME_DIRECTORY}/shared/data/repositories/*/stash-refs/**/*.lock
    sudo -u ${BITBUCKET_UID} rm -f ${HOME_DIRECTORY}/shared/data/repositories/*/logs/**/*.lock
}
