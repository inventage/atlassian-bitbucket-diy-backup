#!/bin/bash

check_command "curl"
check_command "jq"

STASH_HTTP_AUTH="-u ${STASH_BACKUP_USER}:${STASH_BACKUP_PASS}"

function stash_lock {
    STASH_LOCK_RESULT=`curl -s -f ${STASH_HTTP_AUTH} -X POST -H "Content-type: application/json" "${STASH_URL}/mvc/maintenance/lock"`
    if [ -z "${STASH_LOCK_RESULT}" ]; then
        bail "Locking this Stash instance failed"
    fi

    STASH_LOCK_TOKEN=`echo ${STASH_LOCK_RESULT} | jq -r ".unlockToken"`
    if [ -z "${STASH_LOCK_TOKEN}" ]; then
        bail "Unable to find lock token. Result was '$STASH_LOCK_RESULT'"
    fi

    info "locked with '$STASH_LOCK_TOKEN'"
}

function stash_backup_start {
    STASH_BACKUP_RESULT=`curl -s -f ${STASH_HTTP_AUTH} -X POST -H "X-Atlassian-Maintenance-Token: ${STASH_LOCK_TOKEN}" -H "Accept: application/json" -H "Content-type: application/json" "${STASH_URL}/mvc/admin/backups?external=true"`
    if [ -z "${STASH_BACKUP_RESULT}" ]; then
        bail "Entering backup mode failed"
    fi

    STASH_BACKUP_TOKEN=`echo ${STASH_BACKUP_RESULT} | jq -r ".cancelToken"`
    if [ -z "${STASH_BACKUP_TOKEN}" ]; then
        bail "Unable to find backup token. Result was '${STASH_BACKUP_RESULT}'"
    fi

    info "backup started with '${STASH_BACKUP_TOKEN}'"
}

function stash_backup_wait {
    STASH_PROGRESS_DB_STATE="AVAILABLE"
    STASH_PROGRESS_SCM_STATE="AVAILABLE"

    print -n "[${STASH_URL}]  INFO: Waiting for DRAINED state"
    while [ "${STASH_PROGRESS_DB_STATE}_${STASH_PROGRESS_SCM_STATE}" != "DRAINED_DRAINED" ]; do
        print -n "."

        STASH_PROGRESS_RESULT=`curl -s -f ${STASH_HTTP_AUTH} -X GET -H "X-Atlassian-Maintenance-Token: ${STASH_LOCK_TOKEN}" -H "Accept: application/json" -H "Content-type: application/json" "${STASH_URL}/mvc/maintenance"`
        if [ -z "${STASH_PROGRESS_RESULT}" ]; then
            bail "[${STASH_URL}] ERROR: Unable to check for backup progress"
        fi

        STASH_PROGRESS_DB_STATE=`echo ${STASH_PROGRESS_RESULT} | jq -r '.["db-state"]'`
        STASH_PROGRESS_SCM_STATE=`echo ${STASH_PROGRESS_RESULT} | jq -r '.["scm-state"]'`
        STASH_PROGRESS_STATE=`echo ${STASH_PROGRESS_RESULT} | jq -r '.task.state'`

        if [ "${STASH_PROGRESS_STATE}" != "RUNNING" ]; then
            error "Unable to start backup, try unlocking"
            stash_unlock
            bail "Failed to start backup"
        fi
    done

    print " done"
    info "db state '${STASH_PROGRESS_DB_STATE}'"
    info "scm state '${STASH_PROGRESS_SCM_STATE}'"
}

function stash_backup_progress {
    STASH_REPORT_RESULT=`curl -s -f ${STASH_HTTP_AUTH} -X POST -H "Accept: application/json" -H "Content-type: application/json" "${STASH_URL}/mvc/admin/backups/progress/client?token=${STASH_LOCK_TOKEN}&percentage=$1"`
    if [ $? != 0 ]; then
        bail "Unable to update backup progress"
    fi

    info "Backup progress updated to $1"
}

function stash_unlock {
    STASH_UNLOCK_RESULT=`curl -s -f ${STASH_HTTP_AUTH} -X DELETE -H "Accept: application/json" -H "Content-type: application/json" "${STASH_URL}/mvc/maintenance/lock?token=${STASH_LOCK_TOKEN}"`
    if [ $? != 0 ]; then
        bail "Unable to unlock instance with lock ${STASH_LOCK_TOKEN}"
    fi

    info "Stash instance unlocked"
}

function freeze_mount_point {
    info "Freezing filesystem at mount point ${1}"

    sudo fsfreeze -f ${1} 2>&1 > /dev/null
}

function unfreeze_mount_point {
    info "Unreezing filesystem at mount point ${1}"

    sudo fsfreeze -u ${1} 2>&1 > /dev/null
}

function add_cleanup_routine() {
    cleanup_queue+=($1)
    trap run_cleanup EXIT
}

function run_cleanup() {
    announce "Cleaning up..."
    for cleanup in ${cleanup_queue[@]}
    do
        ${cleanup}
    done
}