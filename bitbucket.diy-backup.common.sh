#!/bin/bash

# Contains common functionality related to Bitbucket (e.g.: lock/unlock instance, clean up lock files in repositories, etc)

check_command "curl"
check_command "jq"

BITBUCKET_HTTP_AUTH="-u ${BITBUCKET_BACKUP_USER}:${BITBUCKET_BACKUP_PASS}"

# The name of the product
PRODUCT=Bitbucket


function lock_application {
    if [ "${BACKUP_ZERO_DOWNTIME}" = "true" ]; then
        return
    fi

    local lock_response=$(run curl ${CURL_OPTIONS} ${BITBUCKET_HTTP_AUTH} -X POST -H "Content-type: application/json" \
        "${BITBUCKET_URL}/mvc/maintenance/lock")
    if [ -z "${lock_response}" ]; then
        bail "Unable to lock Bitbucket for maintenance. POST to '${BITBUCKET_URL}/mvc/maintenance/lock' \
            returned '${lock_response}'"
    fi

    BITBUCKET_LOCK_TOKEN=$(echo ${lock_response} | jq -r ".unlockToken" | tr -d '\r')
    if [ -z "${BITBUCKET_LOCK_TOKEN}" ]; then
        bail "Unable to get Bitbucket unlock token from maintenance mode response. \
            Could not find 'unlockToken' in response '${lock_response}'"
    fi

    add_cleanup_routine bitbucket_unlock

    info "Bitbucket has been locked for maintenance.  It can be unlocked with:"
    info "    curl -u ... -X DELETE -H 'Content-type:application/json' '${BITBUCKET_URL}/mvc/maintenance/lock?token=${BITBUCKET_LOCK_TOKEN}'"
}

function backup_start {
    if [ "${BACKUP_ZERO_DOWNTIME}" = "true" ]; then
        return
    fi

    local backup_response=$(run curl ${CURL_OPTIONS} ${BITBUCKET_HTTP_AUTH} -X POST -H \
        "X-Atlassian-Maintenance-Token: ${BITBUCKET_LOCK_TOKEN}" -H "Accept: application/json" \
        -H "Content-type: application/json" "${BITBUCKET_URL}/mvc/admin/backups?external=true")
    if [ -z "${backup_response}" ]; then
        bail "Unable to enter backup mode. POST to '${BITBUCKET_URL}/mvc/admin/backups?external=true' \
            returned '${backup_response}'"
    fi

    BITBUCKET_BACKUP_TOKEN=$(echo ${backup_response} | jq -r ".cancelToken" | tr -d '\r')
    if [ -z "${BITBUCKET_BACKUP_TOKEN}" ]; then
        bail "Unable to enter backup mode. Could not find 'cancelToken' in response '${backup_response}'"
    fi

    info "Backup started. It can be cancelled with:"
    info "    curl -u ... -X DELETE -H 'Content-type:application/json' '${BITBUCKET_URL}/mvc/admin/backups/${BITBUCKET_BACKUP_TOKEN}'"
}

function backup_wait {
    if [ "${BACKUP_ZERO_DOWNTIME}" = "true" ]; then
        return
    fi

    local db_state="AVAILABLE"
    local scm_state="AVAILABLE"

    print "Waiting for Bitbucket to be in DRAINED state"
    while [ "${db_state}_${scm_state}" != "DRAINED_DRAINED" ]; do
        local progress_response=$(run curl ${CURL_OPTIONS} ${BITBUCKET_HTTP_AUTH} -X GET \
            -H "X-Atlassian-Maintenance-Token: ${BITBUCKET_LOCK_TOKEN}" -H "Accept: application/json" \
            -H "Content-type: application/json" "${BITBUCKET_URL}/mvc/maintenance")
        if [ -z "${progress_response}" ]; then
            bail "Unable to check for backup progress. \
                GET to '${BITBUCKET_URL}/mvc/maintenance' did not return any content"
        fi

        db_state=$(echo ${progress_response} | jq -r '.["db-state"]' | tr -d '\r')
        scm_state=$(echo ${progress_response} | jq -r '.["scm-state"]' | tr -d '\r')
        local drained_state=$(echo ${progress_response} | jq -r '.task.state' | tr -d '\r')

        if [ "${drained_state}" != "RUNNING" ]; then
            unlock_application
            bail "Unable to start Bitbucket backup"
        fi
    done

    print "db state '${db_state}'"
    print "scm state '${scm_state}'"
}

function update_backup_progress {
    local backup_progress=$1

    if [ "${BACKUP_ZERO_DOWNTIME}" = "true" ]; then
        return
    fi

    run curl ${CURL_OPTIONS} ${BITBUCKET_HTTP_AUTH} -X POST -H "Accept: application/json" -H "Content-type: application/json" \
        "${BITBUCKET_URL}/mvc/admin/backups/progress/client?token=${BITBUCKET_LOCK_TOKEN}&percentage=${backup_progress}"
}

function unlock_application {
    if [ "${BACKUP_ZERO_DOWNTIME}" = "true" ]; then
        return
    fi

    remove_cleanup_routine bitbucket_unlock

    run curl ${CURL_OPTIONS} ${BITBUCKET_HTTP_AUTH} -X DELETE -H "Accept: application/json" \
        -H "Content-type: application/json" "${BITBUCKET_URL}/mvc/maintenance/lock?token=${BITBUCKET_LOCK_TOKEN}"
}

function freeze_mount_point {
    run sudo fsfreeze -f "${1}"
}

function unfreeze_mount_point {
    run sudo fsfreeze -u "${1}"
}

function remount_device {
    remove_cleanup_routine remount_device
    run sudo mount "${HOME_DIRECTORY_DEVICE_NAME}" "${HOME_DIRECTORY_MOUNT_POINT}"
}

function unmount_device {
    run sudo umount "${HOME_DIRECTORY_MOUNT_POINT}"
    add_cleanup_routine remount_device
}

function add_cleanup_routine() {
    cleanup_queue=($1 ${cleanup_queue[@]})
    trap run_cleanup EXIT INT ABRT PIPE
}

function remove_cleanup_routine() {
    cleanup_queue=("${cleanup_queue[@]/$1}")
}

function run_cleanup() {
    info "Cleaning up..."
    for cleanup in ${cleanup_queue[@]}
    do
        ${cleanup}
    done
}

# This removes config.lock, index.lock, gc.pid, and refs/heads/*.lock
function cleanup_locks {
    local home_directory="$1"

    # From the shopt man page:
    # globstar
    #           If set, the pattern ‘**’ used in a filename expansion context will match all files and zero or
    #           more directories and subdirectories. If the pattern is followed by a ‘/’, only directories and subdirectories match.
    shopt -s globstar

    # Remove lock files in the repositories
    run sudo -u ${BITBUCKET_UID} rm -f ${home_directory}/shared/data/repositories/*/{HEAD,config,index,gc,packed-refs,stash-packed-refs}.{pid,lock}
    run sudo -u ${BITBUCKET_UID} rm -f ${home_directory}/shared/data/repositories/*/refs/**/*.lock
    run sudo -u ${BITBUCKET_UID} rm -f ${home_directory}/shared/data/repositories/*/stash-refs/**/*.lock
    run sudo -u ${BITBUCKET_UID} rm -f ${home_directory}/shared/data/repositories/*/logs/**/*.lock
}
