# -------------------------------------------------------------------------------------
# Common functionality related to Bitbucket (e.g.: lock/unlock instance,
# clean up lock files in repositories, etc)
# -------------------------------------------------------------------------------------

# The name of the product
PRODUCT=Bitbucket
BACKUP_VARS_FILE=${BACKUP_VARS_FILE:-"${SCRIPT_DIR}"/bitbucket.diy-backup.vars.sh}
PATH=$PATH:/sbin:/usr/sbin:/usr/local/bin
TIMESTAMP=$(date +"%Y%m%d-%H%M%S")

# If "psql" is installed, get its version number
if which psql > /dev/null 2>&1; then
    psql_version="$(psql --version | awk '{print $3}')"
    psql_majorminor="$(printf "%d%03d" $(echo "${psql_version}" | tr "." "\n" | sed 2q))"
    psql_major="$(echo ${psql_version} | tr -d '.' | cut -c 1-2)"
fi

if [ -f "${BACKUP_VARS_FILE}" ]; then
    source "${BACKUP_VARS_FILE}"
    debug "Using vars file: '${BACKUP_VARS_FILE}'"
else
    error "'${BACKUP_VARS_FILE}' not found"
    bail "You should create it using '${SCRIPT_DIR}/bitbucket.diy-backup.vars.sh.example' as a template"
fi

# Note that this prefix is used to delete old backups and if set improperly will delete incorrect backups on cleanup.
SNAPSHOT_TAG_PREFIX=${SNAPSHOT_TAG_PREFIX:-${INSTANCE_NAME}-}
SNAPSHOT_TAG_VALUE=${SNAPSHOT_TAG_VALUE:-${SNAPSHOT_TAG_PREFIX}${TIMESTAMP}}

# Lock a Bitbucket instance for maintenance
function lock_bitbucket {
    if [ "${BACKUP_ZERO_DOWNTIME}" = "true" ]; then
        return
    fi

    check_config_var "BITBUCKET_BACKUP_USER"
    check_config_var "BITBUCKET_BACKUP_PASS"
    check_config_var "BITBUCKET_URL"

    local lock_response=$(run curl ${CURL_OPTIONS} -u "${BITBUCKET_BACKUP_USER}:${BITBUCKET_BACKUP_PASS}" -X POST -H "Content-type: application/json" \
        "${BITBUCKET_URL}/mvc/maintenance/lock")
    if [ -z "${lock_response}" ]; then
        bail "Unable to lock Bitbucket for maintenance. POST to '${BITBUCKET_URL}/mvc/maintenance/lock' returned '${lock_response}'"
    fi

    BITBUCKET_LOCK_TOKEN=$(echo "${lock_response}" | jq -r ".unlockToken" | tr -d '\r')
    if [ -z "${BITBUCKET_LOCK_TOKEN}" ]; then
        bail "Unable to get Bitbucket unlock token from maintenance mode response. \
            Could not find 'unlockToken' in response '${lock_response}'"
    fi

    add_cleanup_routine bitbucket_unlock

    info "Bitbucket has been locked for maintenance.  It can be unlocked with:"
    info "    curl -u ... -X DELETE -H 'Content-type:application/json' '${BITBUCKET_URL}/mvc/maintenance/lock?token=${BITBUCKET_LOCK_TOKEN}'"
}

# Instruct Bitbucket to begin a backup
function backup_start {
    if [ "${BACKUP_ZERO_DOWNTIME}" = "true" ]; then
        return
    fi

    local backup_response=$(run curl ${CURL_OPTIONS} -u "${BITBUCKET_BACKUP_USER}:${BITBUCKET_BACKUP_PASS}" -X POST -H \
        "X-Atlassian-Maintenance-Token: ${BITBUCKET_LOCK_TOKEN}" -H "Accept: application/json" \
        -H "Content-type: application/json" "${BITBUCKET_URL}/mvc/admin/backups?external=true")
    if [ -z "${backup_response}" ]; then
        bail "Unable to enter backup mode. POST to '${BITBUCKET_URL}/mvc/admin/backups?external=true' \
            returned '${backup_response}'"
    fi

    BITBUCKET_BACKUP_TOKEN=$(echo "${backup_response}" | jq -r ".cancelToken" | tr -d '\r')
    if [ -z "${BITBUCKET_BACKUP_TOKEN}" ]; then
        bail "Unable to enter backup mode. Could not find 'cancelToken' in response '${backup_response}'"
    fi

    info "Bitbucket server is now preparing for backup. If the backup task is cancelled, Bitbucket Server should be notified that backup was terminated by executing the following command:"
    info "    curl -u ... -X POST -H 'Content-type:application/json' '${BITBUCKET_URL}/mvc/maintenance?token=${BITBUCKET_BACKUP_TOKEN}'"
    info "This will also terminate the backup process in Bitbucket Server. Note that this will not unlock Bitbucket Server from maintenance mode."
}

# Wait for database and SCM to drain to ensure a consistent backup
function backup_wait {
    if [ "${BACKUP_ZERO_DOWNTIME}" = "true" ]; then
        return
    fi

    local db_state="AVAILABLE"
    local scm_state="AVAILABLE"

    info "Waiting for Bitbucket to become ready to be backed up"

    while [ "${db_state}_${scm_state}" != "DRAINED_DRAINED" ]; do
        # The following curl command is not executed with run to suppress the polling spam of messages
        local progress_response=$(curl ${CURL_OPTIONS} -u "${BITBUCKET_BACKUP_USER}:${BITBUCKET_BACKUP_PASS}" -X GET \
            -H "X-Atlassian-Maintenance-Token: ${BITBUCKET_LOCK_TOKEN}" -H "Accept: application/json" \
            -H "Content-type: application/json" "${BITBUCKET_URL}/mvc/maintenance")
        if [ -z "${progress_response}" ]; then
            bail "Unable to check for backup progress. \
                GET to '${BITBUCKET_URL}/mvc/maintenance' did not return any content"
        fi

        db_state=$(echo "${progress_response}" | jq -r '.["db-state"]' | tr -d '\r')
        scm_state=$(echo "${progress_response}" | jq -r '.["scm-state"]' | tr -d '\r')
        local drained_state=$(echo "${progress_response}" | jq -r '.task.state' | tr -d '\r')

        if [ "${drained_state}" != "RUNNING" ]; then
            unlock_bitbucket
            bail "Unable to start Bitbucket backup, because it could not enter DRAINED state"
        fi
    done
}

function source_archive_strategy {
    if [[ -e "${SCRIPT_DIR}/archive-${BACKUP_ARCHIVE_TYPE}.sh" ]]; then
        source "${SCRIPT_DIR}/archive-${BACKUP_ARCHIVE_TYPE}.sh"
    else
        # If no archiver was specified, any file system level restore cannot unpack any archives to be restored.
        # Only the "latest snapshot" (i.e., the working folder used by the backup process) is available.
        BITBUCKET_RESTORE_DB="${BITBUCKET_BACKUP_DB}"
        BITBUCKET_RESTORE_HOME="${BITBUCKET_BACKUP_HOME}"
        BITBUCKET_RESTORE_DATA_STORES="${BITBUCKET_BACKUP_DATA_STORES}"
    fi
}

function source_database_strategy {
    if [ -e "${SCRIPT_DIR}/database-${BACKUP_DATABASE_TYPE}.sh" ]; then
        source "${SCRIPT_DIR}/database-${BACKUP_DATABASE_TYPE}.sh"
    else
        error "BACKUP_DATABASE_TYPE=${BACKUP_DATABASE_TYPE} is not implemented, '${SCRIPT_DIR}/database-${BACKUP_DATABASE_TYPE}.sh' does not exist"
        bail "Please update BACKUP_DATABASE_TYPE in '${BACKUP_VARS_FILE}'"
    fi
}

function source_elasticsearch_strategy {
    if [ -e "${SCRIPT_DIR}/elasticsearch-${BACKUP_ELASTICSEARCH_TYPE:-none}.sh" ]; then
        source "${SCRIPT_DIR}/elasticsearch-${BACKUP_ELASTICSEARCH_TYPE:-none}.sh"
    else
        error "BACKUP_ELASTICSEARCH_TYPE=${BACKUP_ELASTICSEARCH_TYPE} is not implemented, '${SCRIPT_DIR}/elasticsearch-${BACKUP_ELASTICSEARCH_TYPE:-none}.sh' does not exist"
        bail "Please update BACKUP_DATABASE_TYPE in '${BACKUP_VARS_FILE}'"
    fi
}

function source_disk_strategy {
    # Fail if it looks like the scripts are being run with an old backup vars file.
    if [ -n "${BACKUP_HOME_TYPE}" ]; then
        error "Configuration is out of date."
        bail "Please update the configuration in '${BACKUP_VARS_FILE}'"
    fi

    if [ -e "${SCRIPT_DIR}/home-${BACKUP_DISK_TYPE}.sh" ]; then
        source "${SCRIPT_DIR}/home-${BACKUP_DISK_TYPE}.sh"
    else
        error "BACKUP_DISK_TYPE=${BACKUP_DISK_TYPE} is not implemented, '${SCRIPT_DIR}/home-${BACKUP_DISK_TYPE}.sh' does not exist"
        bail "Please update BACKUP_DISK_TYPE in '${BACKUP_VARS_FILE}'"
    fi
}

function source_disaster_recovery_disk_strategy {
    if [ -e "${SCRIPT_DIR}/disk-${STANDBY_DISK_TYPE}.sh" ]; then
        source "${SCRIPT_DIR}/disk-${STANDBY_DISK_TYPE}.sh"
    else
        error "STANDBY_DISK_TYPE=${STANDBY_DISK_TYPE} is not implemented, '${SCRIPT_DIR}/disk-${STANDBY_DISK_TYPE}.sh' does not exist"
        bail "Please update STANDBY_DISK_TYPE in '${BACKUP_VARS_FILE}'"
    fi
}

function source_disaster_recovery_database_strategy {
    if [ -e "${SCRIPT_DIR}/database-${STANDBY_DATABASE_TYPE}.sh" ]; then
        source "${SCRIPT_DIR}/database-${STANDBY_DATABASE_TYPE}.sh"
    else
        error "STANDBY_DATABASE_TYPE=${STANDBY_DATABASE_TYPE} is not implemented, '${SCRIPT_DIR}/database-${STANDBY_DATABASE_TYPE}.sh' does not exist"
        bail "Please update STANDBY_DATABASE_TYPE in '${BACKUP_VARS_FILE}'"
    fi
}

# Instruct Bitbucket to update the progress of a backup
#
# backup_progress = The percentage completion
#
function update_backup_progress {
    local backup_progress=$1

    if [ "${BACKUP_ZERO_DOWNTIME}" = "true" ]; then
        return
    fi

    run curl ${CURL_OPTIONS} -u "${BITBUCKET_BACKUP_USER}:${BITBUCKET_BACKUP_PASS}" -X POST -H "Accept: application/json" -H "Content-type: application/json" \
        "${BITBUCKET_URL}/mvc/admin/backups/progress/client?token=${BITBUCKET_LOCK_TOKEN}&percentage=${backup_progress}"
}

# Unlock a previously locked Bitbucket instance
function unlock_bitbucket {
    if [ "${BACKUP_ZERO_DOWNTIME}" = "true" ]; then
        return
    fi

    remove_cleanup_routine bitbucket_unlock

    run curl ${CURL_OPTIONS} -u "${BITBUCKET_BACKUP_USER}:${BITBUCKET_BACKUP_PASS}" -X DELETE -H "Accept: application/json" \
        -H "Content-type: application/json" "${BITBUCKET_URL}/mvc/maintenance/lock?token=${BITBUCKET_LOCK_TOKEN}"
}

# Get the version of Bitbucket running on the Bitbucket instance
function bitbucket_version {
    run curl ${CURL_OPTIONS} -k "${BITBUCKET_URL}/rest/api/1.0/application-properties" | jq -r '.version' | \
        sed -e 's/\./ /' -e 's/\..*//'
}

# Freeze the filesystem mounted under the provided directory.
# Note that this function requires password-less SUDO access.
#
# $1 = mount point
#
function freeze_mount_point {
    case ${FILESYSTEM_TYPE} in
    zfs)
        # A ZFS filesystem doesn't require a fsfreeze
        ;;
    *)
        if [ "${FSFREEZE}" = "true" ]; then
            run sudo fsfreeze -f "${1}"
        fi
        ;;
    esac
}

# Unfreeze the filesystem mounted under the provided mount point.
# Note that this function requires password-less SUDO access.
#
# $1 = mount point
#
function unfreeze_mount_point {
    if [ "${FSFREEZE}" = "true" ]; then
        run sudo fsfreeze -u "${1}"
    fi
}

# Remount the previously mounted ebs volumes
function remount_ebs_volumes {
    remove_cleanup_routine remount_ebs_volumes

    case ${FILESYSTEM_TYPE} in
    zfs)
        run sudo zpool import tank
        run sudo zfs mount -a
        run sudo zfs share -a
        ;;
    *)
        local mount_point=
        local device_name=
        for volume in "${EBS_VOLUME_MOUNT_POINT_AND_DEVICE_NAMES[@]}"; do
            mount_point="$(echo "${store}" | cut -d ":" -f1)"
            device_name="$(echo "${store}" | cut -d ":" -f2)"
            run sudo mount "${device_name}" "${mount_point}"
        done
        ;;
    esac
}

# Unmount the currently mounted ebs volumes
function unmount_ebs_volumes {
    case ${FILESYSTEM_TYPE} in
    zfs)
        local shared=
        for fs_name in "${ZFS_FILESYSTEM_NAMES[@]}"; do
            shared=$(run sudo zfs get -o value -H sharenfs "${fs_name}")
            if [ "${shared}" = "on" ]; then
                run sudo zfs unshare "${fs_name}"
            fi
            run sudo zfs unmount "${fs_name}"
        done
        run sudo zpool export tank
        ;;
    *)
        local mount_point=
        for volume in "${EBS_VOLUME_MOUNT_POINT_AND_DEVICE_NAMES[@]}"; do
            mount_point="$(echo "${store}" | cut -d ":" -f1)"
            run sudo umount "${mount_point}"
        done
        ;;
    esac

    add_cleanup_routine remount_ebs_volumes
}

# Add a argument-less callback to the list of cleanup routines.
#
# $1 = a argument-less function
#
function add_cleanup_routine {
    local var="cleanup_queue_${BASH_SUBSHELL}"
    eval ${var}=\"$1 ${!var}\"
    trap run_cleanup EXIT INT ABRT PIPE
}

# Remove a previously registered cleanup callback.
#
# $1 = a argument-less function
#
function remove_cleanup_routine {
    local var="cleanup_queue_${BASH_SUBSHELL}"
    eval ${var}=\"${!var/$1}\"
}

# Execute the callbacks previously registered via "add_cleanup_routine"
function run_cleanup {
    debug "Running cleanup jobs..."
    local var="cleanup_queue_${BASH_SUBSHELL}"
    for cleanup in ${!var}; do
        ${cleanup}
    done
}

# Remove files like config.lock, index.lock, gc.pid, and refs/heads/*.lock from the provided home directory
#
# $1 = the home directory to clean
#
function cleanup_home_locks {
    local home_directory="$1"

    # From the shopt man page:
    # globstar
    #           If set, the pattern ‘**’ used in a filename expansion context will match all files and zero or
    #           more directories and subdirectories. If the pattern is followed by a ‘/’, only directories and subdirectories match.
    shopt -s globstar

    # Remove lock files in the repositories
    run sudo -u "${BITBUCKET_UID}" rm -f "${home_directory}/shared/data/repositories/*/{HEAD,config,index,gc,packed-refs,stash-packed-refs}.{pid,lock}"
    run sudo -u "${BITBUCKET_UID}" rm -f "${home_directory}/shared/data/repositories/*/refs/**/*.lock"
    run sudo -u "${BITBUCKET_UID}" rm -f "${home_directory}/shared/data/repositories/*/stash-refs/**/*.lock"
    run sudo -u "${BITBUCKET_UID}" rm -f "${home_directory}/shared/data/repositories/*/logs/**/*.lock"
}

# Remove files like config.lock, index.lock, gc.pid, and refs/heads/*.lock from the provided data store directory
#
# $1 = the data store directory to clean
#
function cleanup_data_store_locks {
    local data_store="$1"

    # From the shopt man page:
    # globstar
    #           If set, the pattern ‘**’ used in a filename expansion context will match all files and zero or
    #           more directories and subdirectories. If the pattern is followed by a ‘/’, only directories and subdirectories match.
    shopt -s globstar

    # Remove lock files in the repositories
    run sudo -u "${BITBUCKET_UID}" rm -f "${data_store}/repositories/*/*/*/{HEAD,config,index,gc,packed-refs,stash-packed-refs}.{pid,lock}"
    run sudo -u "${BITBUCKET_UID}" rm -f "${data_store}/repositories/*/*/*/refs/**/*.lock"
    run sudo -u "${BITBUCKET_UID}" rm -f "${data_store}/repositories/*/*/*/stash-refs/**/*.lock"
    run sudo -u "${BITBUCKET_UID}" rm -f "${data_store}/repositories/*/*/*/logs/**/*.lock"
}