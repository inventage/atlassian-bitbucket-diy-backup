# -------------------------------------------------------------------------------------
# A backup and restore strategy using ZFS
# -------------------------------------------------------------------------------------

check_command "zfs"

function prepare_backup_home {
    check_config_var "ZFS_HOME_TANK_NAME"
    debug "Validating ZFS_HOME_TANK_NAME=${ZFS_HOME_TANK_NAME}"
    run sudo zfs list -H -o name "${ZFS_HOME_TANK_NAME}"
}

function backup_home {
    local new_snapshot="${ZFS_HOME_TANK_NAME}@${SNAPSHOT_TAG_VALUE}"
    debug "Creating snapshot with name '${new_snapshot}' in ZFS filesystem '${ZFS_HOME_TANK_NAME}'"
    run sudo zfs snapshot "${new_snapshot}"
}

function prepare_restore_home {
    local snapshot_tag="$1"

    if [ -z "${snapshot}" ]; then
        debug "Getting snapshot list for ZFS filesystem '${ZFS_HOME_TANK_NAME}'"
        snapshot_list=$(run sudo zfs list -H -t snapshot -o name | cut -d "@" -f2)
        info "Available Snapshots:"
        info "${snapshot_list}"
        bail "Please select a snapshot to restore"
    fi

    debug "Validating ZFS snapshot '${snapshot_tag}'"
    run sudo zfs list -t snapshot -o name "${ZFS_HOME_TANK_NAME}@${snapshot_tag}" > /dev/null

    RESTORE_ZFS_SNAPSHOT="${ZFS_HOME_TANK_NAME}@${snapshot_tag}"
}

function restore_home {
    debug "Rolling back to ZFS snapshot '${RESTORE_ZFS_SNAPSHOT}'"
    run sudo zfs rollback "${RESTORE_ZFS_SNAPSHOT}"
}

# ----------------------------------------------------------------------------------------------------------------------
# Disaster recovery functions
# ----------------------------------------------------------------------------------------------------------------------

function replicate_home {
    check_config_var "ZFS_HOME_TANK_NAME"

    debug "Getting the latest ZFS snapshot on the standby instance '${STANDBY_SSH_HOST}'"
    local standby_last_snapshot=$(run ssh ${STANDBY_SSH_OPTIONS} "${STANDBY_SSH_USER}@${STANDBY_SSH_HOST}" \
        "sudo zfs list -H -t snapshot -o name -S creation | grep -m1 '${ZFS_HOME_TANK_NAME}'")
    check_var "standby_last_snapshot" \
        "No ZFS snapshot found on standby instance '${STANDBY_SSH_HOST}'" \
        "Please run setup-home-replication.sh to configure the standby correctly"

    debug "Taking ZFS snapshot before replicating to ${STANDBY_SSH_HOST}"
    backup_home

    local primary_last_snapshot=$(get_latest_snapshot)
    debug "Sending incremental ZFS snapshot before replicating to ${STANDBY_SSH_HOST}"
    run sudo zfs send -R -i "${standby_last_snapshot}" "${primary_last_snapshot}" \
        | run ssh ${STANDBY_SSH_OPTIONS} "${STANDBY_SSH_USER}@${STANDBY_SSH_HOST}" sudo zfs receive "${ZFS_HOME_TANK_NAME}"

    debug "Snapshot '${primary_last_snapshot}' was successfully transferred and applied on '${STANDBY_SSH_HOST}'"

    if [ "${KEEP_BACKUPS}" -gt 0 ]; then
        cleanup_standby_snapshots
    fi
}

function promote_home {
    check_config_var "STANDBY_JDBC_URL"
    local latest_snapshot="$(get_latest_snapshot)"

    if [ -n "$(run sudo zfs diff "${latest_snapshot}" "${ZFS_HOME_TANK_NAME}")" ]; then
        error "ZFS filesystem '${ZFS_HOME_TANK_NAME}' appears to have already diverged from the latest snapshot '${latest_snapshot}'."
        bail "No promotion necessary."
    fi

    local mount_point=$(run sudo zfs get mountpoint -H -o value "${ZFS_HOME_TANK_NAME}")
    debug "ZFS filesystem '${ZFS_HOME_TANK_NAME}' has a configured mount point of '${mount_point}'"

    local settings=$(cat << EOF

# The following properties were appended during the promote-standby-home.sh script.
#
jdbc.url=${STANDBY_JDBC_URL}
disaster.recovery=true
EOF
)
    info "Modifying '${mount_point}/bitbucket/shared/bitbucket.properties'. This also prevents ZFS home replication from the primary."
    sudo bash -c "echo '${settings}' >> '${mount_point}/bitbucket/shared/bitbucket.properties'"
    print
    print "The following has been appended to your '${mount_point}/bitbucket/shared/bitbucket.properties' file:"
    print
    print "${settings}"
    print

    info "Validating that ZFS filesystem '${ZFS_HOME_TANK_NAME}' has diverged"
    if [ -z "$(run sudo zfs diff "${latest_snapshot}" "${ZFS_HOME_TANK_NAME}")" ]; then
        error "ZFS filesystem '${ZFS_HOME_TANK_NAME}' appears not to have diverged from the latest snapshot '${latest_snapshot}'."
        bail "Home directory replication from primary may still be happening."
    fi

    success "Successfully promoted standby home"
}

function setup_home_replication {
    info "Checking primary instance's ZFS configuration"

    debug "Checking if filesystem with name '${ZFS_HOME_TANK_NAME}' exists on the primary file server"
    print_filesystem_information "$(run sudo zfs list -H -o avail,used,mountpoint -t filesystem "${ZFS_HOME_TANK_NAME}")"

    debug "Checking that ZFS filesystem with name '${ZFS_HOME_TANK_NAME}' doesn't already exist on the standby file server '${STANDBY_SSH_HOST}'"
    if run ssh ${STANDBY_SSH_OPTIONS} ${STANDBY_SSH_USER}@${STANDBY_SSH_HOST} \
            "sudo zfs list -H -o name -t filesystem ${ZFS_HOME_TANK_NAME} > /dev/null 2>&1"; then
        error "A ZFS filesystem with name '${ZFS_HOME_TANK_NAME}' exists on the standby"
        bail "Destroy ZFS filesystem on standby and re-run setup"
    fi

    send_initial_snapshot_to_standby
    mount_zfs_filesystem

    success "Home replication has been set up successfully."
    echo -e "$(cat << EOF
\n
To continuously replicate from the primary to the standby you can configure a cron entry execute 'replicate-home.sh' every minute.\n
An example of what the cron tab cload look like:\n
MAILTO="administrator@company.com" # Sets the destination email, provided you have set up mail delivery correctly
* * * * * BITBUCKET_VERBOSE_BACKUP=false ${SCRIPT_DIR}/replicate-home.sh\n
To test the replication, simply execute 'replicate-home.sh' from the command line.\n
${SCRIPT_DIR}/replicate-home.sh\n
EOF
)"
}

# ----------------------------------------------------------------------------------------------------------------------
# Private functions
# ----------------------------------------------------------------------------------------------------------------------

function print_filesystem_information {
    local fs_info="$1"

    local available=$(echo "${fs_info}" | awk '{print $1}')
    local used=$(echo "${fs_info}" | awk '{print $2}')
    local mount=$(echo "${fs_info}" | awk '{print $3}')
    info "ZFS filesystem '${ZFS_HOME_TANK_NAME}' exists."
    if [ -z "${mount}" -o -z "${used}" -o -z "${available}" ]; then
        error "The ZFS filesystem '${ZFS_HOME_TANK_NAME}' has no mount point defined."
        bail "Please ensure that a mount point is configured, by using 'zfs set mountpoint'"
    else
        info "ZFS filesystem is mounted at '${mount}'"
    fi
    info "ZFS filesystem has ${available} of space available"
    info "ZFS filesystem has ${used} of space used"
    info "ZFS configuration seems to be correct"
}

function send_initial_snapshot_to_standby {
    debug "Getting latest snapshot of filesystem '${ZFS_HOME_TANK_NAME}'"
    local primary_last_snapshot=$(get_latest_snapshot)
    if [ -z "${primary_last_snapshot}" ]; then
        debug "No snapshot exists of '${ZFS_HOME_TANK_NAME}', creating one now"
        backup_home
        primary_last_snapshot=$(get_latest_snapshot)
    fi

    # This will send the latest primary snapshot to the standby filesystem without mounting it
    debug "Sending snapshot '${primary_last_snapshot}' of filesystem '${ZFS_HOME_TANK_NAME}' to standby file server '${STANDBY_SSH_HOST}'"
    run sudo zfs send -v "${primary_last_snapshot}" \
        | run ssh ${STANDBY_SSH_OPTIONS} "${STANDBY_SSH_USER}@${STANDBY_SSH_HOST}" sudo zfs receive -vu "${ZFS_HOME_TANK_NAME}"
}

function cleanup_standby_snapshots {
    # Cleanup all ZFS snapshots except latest ${KEEP_BACKUPS}
    local script="OLD_SNAPSHOTS=\$(sudo zfs list -H -t snapshot -o name -S creation | grep ${ZFS_HOME_TANK_NAME} | tail -n +${KEEP_BACKUPS})
if [ -n "\${OLD_SNAPSHOTS}" ]; then
    echo "Destroying standby snapshots: \${OLD_SNAPSHOTS}"
    echo "\${OLD_SNAPSHOTS}" | xargs -n 1 sudo zfs destroy
fi"
    debug "Cleaning up old snapshots in standby file server '${STANDBY_SSH_HOST}'"
    debug $(run ssh ${STANDBY_SSH_OPTIONS} "${STANDBY_SSH_USER}@${STANDBY_SSH_HOST}" "${script}")
}


function get_latest_snapshot {
    run sudo zfs list -H -t snapshot -o name -S creation | grep -m1 "${ZFS_HOME_TANK_NAME}"
}

function mount_zfs_filesystem {
    debug "Getting mount point of '${ZFS_HOME_TANK_NAME}' on the primary file server"
    local mount_point=$(run sudo zfs get mountpoint -H -o value "${ZFS_HOME_TANK_NAME}")
    debug "Resetting mount point of '${ZFS_HOME_TANK_NAME}' on the standby file server"
    # Working around an issue with ZFS which results in the remote filesystem being mount
    run ssh ${STANDBY_SSH_OPTIONS} "${STANDBY_SSH_USER}@${STANDBY_SSH_HOST}" sudo zfs set mountpoint=none "${ZFS_HOME_TANK_NAME}"
    run ssh ${STANDBY_SSH_OPTIONS} "${STANDBY_SSH_USER}@${STANDBY_SSH_HOST}" sudo zfs set mountpoint="${mount_point}" "${ZFS_HOME_TANK_NAME}"
}

function cleanup_home_backups {
    if [ "${KEEP_BACKUPS}" -gt 0 ]; then
        # Cleanup all ZFS snapshots except latest ${KEEP_BACKUPS}
        debug "Getting a list of snapshots to delete"
        local old_snapshots=$(run sudo zfs list -H -t snapshot -o name -S creation | grep ${ZFS_HOME_TANK_NAME} | tail -n +${KEEP_BACKUPS})
        if [ -n "${old_snapshots}" ]; then
            debug "Destroying snapshots: ${old_snapshots}"
            echo "${old_snapshots}" | xargs -n 1 sudo zfs destroy
        else
            debug "No snapshots to clean"
        fi
    fi
}