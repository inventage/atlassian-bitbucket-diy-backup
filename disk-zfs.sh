# -------------------------------------------------------------------------------------
# A backup and restore strategy using ZFS
#
# Please consult the following documentation about administering ZFS:
#           http://open-zfs.org/wiki/System_Administration
#
# -------------------------------------------------------------------------------------

check_command "zfs"
check_config_var "ZFS_FILESYSTEM_NAMES"

function prepare_backup_disk {
    debug "Validating ZFS_FILESYSTEM_NAMES:"
    for fs in "${ZFS_FILESYSTEM_NAMES[@]}"; do
        debug "${fs}"
        run sudo zfs list -H -o name "${fs}" > /dev/null
    done
}

function backup_disk {
    for fs in "${ZFS_FILESYSTEM_NAMES[@]}"; do
        local new_snapshot="${fs}@${SNAPSHOT_TAG_VALUE}"
        debug "Creating snapshot with name '${new_snapshot}' for ZFS filesystem '${fs}'"
        run sudo zfs snapshot "${new_snapshot}"
    done
}

function prepare_restore_disk {
    local snapshot_tag="$1"

    if [ -z "${snapshot_tag}" ]; then
        debug "Getting snapshot list for ZFS filesystem '${ZFS_FILESYSTEM_NAMES[0]}'"
        list_available_zfs_snapshots
        bail "Please select a snapshot to restore"
    fi

    unset RESTORE_ZFS_SNAPSHOTS
    debug "Validating ZFS snapshots with tag '${snapshot_tag}':"
    for fs in "${ZFS_FILESYSTEM_NAMES[@]}"; do
        debug "${fs}@${snapshot_tag}"
        run sudo zfs list -t snapshot -o name "${fs}@${snapshot_tag}" > /dev/null
        RESTORE_ZFS_SNAPSHOTS+=("${fs}@${snapshot_tag}")
    done
}

function restore_disk {
    for snapshot in "${RESTORE_ZFS_SNAPSHOTS[@]}"; do
        debug "Rolling back to ZFS snapshot '${snapshot}'"
        run sudo zfs rollback "${snapshot}"
    done
}

function cleanup_disk_backups {
    for fs in "${ZFS_FILESYSTEM_NAMES[@]}"; do
        cleanup_zfs_backups "${fs}"
    done
}

# ----------------------------------------------------------------------------------------------------------------------
# Disaster recovery functions
# ----------------------------------------------------------------------------------------------------------------------

function setup_disk_replication {
    check_config_var "STANDBY_SSH_USER"
    check_config_var "STANDBY_SSH_HOST"

    info "Checking primary instance's ZFS configuration"

    for fs in "${ZFS_FILESYSTEM_NAMES[@]}"; do
        debug "Checking if filesystem with name '${fs}' exists on the primary file server"
        print_filesystem_information "${fs}"
    done

    debug "Checking that we can ssh onto ${STANDBY_SSH_HOST}"
    if ! run ssh ${STANDBY_SSH_OPTIONS} ${STANDBY_SSH_USER}@${STANDBY_SSH_HOST} echo '' > /dev/null 2>&1; then
        bail "Unable to SSH to '${STANDBY_SSH_HOST}'"
    fi

    for fs in "${ZFS_FILESYSTEM_NAMES[@]}"; do
        debug "Checking that ZFS filesystem with name '${fs}' doesn't already exist on the standby file server '${STANDBY_SSH_HOST}'"
        if run ssh ${STANDBY_SSH_OPTIONS} ${STANDBY_SSH_USER}@${STANDBY_SSH_HOST} "sudo zfs list -H -o name -t filesystem \
                ${fs} > /dev/null 2>&1"; then
            error "A ZFS filesystem with name '${fs}' exists on the standby"
            bail "Destroy ZFS filesystem on standby and re-run setup"
        fi
    done

    for fs in "${ZFS_FILESYSTEM_NAMES[@]}"; do
        send_initial_snapshot_to_standby "${fs}"
        mount_zfs_filesystem_on_standby "${fs}"
    done

    success "Disk replication has been set up successfully."
    print
    print "To continuously replicate from the primary to the standby you can configure a"
    print "crontab entry to run 'replicate-disk.sh' every minute. For example:"
    print "    MAILTO=\"administrator@company.com\""
    print "    * * * * * BITBUCKET_VERBOSE_BACKUP=false ${SCRIPT_DIR}/replicate-disk.sh"
    print "To test the replication manually, just run"
    print "    ${SCRIPT_DIR}/replicate-disk.sh"
}

function replicate_disk {
    debug "Getting the latest ZFS snapshots on the standby instance '${STANDBY_SSH_HOST}'"

    for filesystem in "${ZFS_FILESYSTEM_NAMES[@]}"; do
        local standby_last_snapshot=$(run ssh ${STANDBY_SSH_OPTIONS} "${STANDBY_SSH_USER}@${STANDBY_SSH_HOST}" \
            "sudo zfs list -H -t snapshot -o name -S creation | grep -m1 '${filesystem}'")
        check_var "standby_last_snapshot" \
            "No ZFS snapshot of '${filesystem}' found on standby instance '${STANDBY_SSH_HOST}'" \
            "Please run setup-disk-replication.sh to configure the standby correctly"
    done

    debug "Taking snapshots of ZFS filesystems before replicating to ${STANDBY_SSH_HOST}"
    backup_disk

    for filesystem in "${ZFS_FILESYSTEM_NAMES[@]}"; do
        local standby_last_snapshot=$(run ssh ${STANDBY_SSH_OPTIONS} "${STANDBY_SSH_USER}@${STANDBY_SSH_HOST}" \
            "sudo zfs list -H -t snapshot -o name -S creation | grep -m1 '${filesystem}'")
        local primary_last_snapshot=$(get_latest_snapshot "${filesystem}")
        debug "Sending incremental ZFS snapshot of '${filesystem}' before replicating to ${STANDBY_SSH_HOST}"
        run sudo zfs send -R -i "${standby_last_snapshot}" "${primary_last_snapshot}" \
            | run ssh ${STANDBY_SSH_OPTIONS} "${STANDBY_SSH_USER}@${STANDBY_SSH_HOST}" sudo zfs receive "${filesystem}"

        debug "Snapshot '${primary_last_snapshot}' was successfully transferred and applied on '${STANDBY_SSH_HOST}'"

        if [ "${KEEP_BACKUPS}" -gt 0 ]; then
            cleanup_standby_snapshots "${filesystem}"
        fi
    done
}

function promote_home {
    check_config_var "STANDBY_JDBC_URL"
    check_config_var "ZFS_HOME_FILESYSTEM"
    local latest_snapshot="$(get_latest_snapshot "${ZFS_HOME_FILESYSTEM}")"

    if [ -n "$(run sudo zfs diff "${latest_snapshot}" "${ZFS_HOME_FILESYSTEM}")" ]; then
        error "ZFS filesystem '${ZFS_HOME_FILESYSTEM}' appears to have already diverged from the latest snapshot '${latest_snapshot}'."
        bail "No promotion necessary."
    fi

    local mount_point=$(run sudo zfs get mountpoint -H -o value "${ZFS_HOME_FILESYSTEM}")
    debug "ZFS filesystem '${ZFS_HOME_FILESYSTEM}' has a configured mount point of '${mount_point}'"

    local settings=$(cat << EOF

# The following properties were appended during the promote-home.sh script.
#
jdbc.url=${STANDBY_JDBC_URL}
disaster.recovery=true
EOF
)
    info "Modifying '${mount_point}/bitbucket.properties'. This also prevents ZFS disk replication from the primary."
    sudo bash -c "echo '${settings}' >> '${mount_point}/bitbucket.properties'"
    print
    print "The following has been appended to your '${mount_point}/bitbucket.properties' file:"
    print
    print "${settings}"
    print

    info "Validating that ZFS filesystem '${ZFS_HOME_FILESYSTEM}' has diverged"
    if [ -z "$(run sudo zfs diff "${latest_snapshot}" "${ZFS_HOME_FILESYSTEM}")" ]; then
        error "ZFS filesystem '${ZFS_HOME_FILESYSTEM}' appears not to have diverged from the latest snapshot '${latest_snapshot}'."
        bail "Disk replication from primary may still be happening."
    fi

    success "Successfully promoted standby home"
}

# ----------------------------------------------------------------------------------------------------------------------
# Private functions
# ----------------------------------------------------------------------------------------------------------------------

function send_initial_snapshot_to_standby {
    local filesystem="$1"
    debug "Getting latest snapshot of filesystem '${filesystem}'"
    local primary_last_snapshot=$(get_latest_snapshot "${filesystem}")
    if [ -z "${primary_last_snapshot}" ]; then
        debug "No snapshot exists of '${filesystem}', creating one now"
        backup_disk
        primary_last_snapshot=$(get_latest_snapshot "${filesystem}")
    fi

    # This will send the latest primary snapshot to the standby filesystem without mounting it
    debug "Sending snapshot '${primary_last_snapshot}' of filesystem '${filesystem}' to standby file server '${STANDBY_SSH_HOST}'"
    run sudo zfs send -v "${primary_last_snapshot}" \
        | run ssh ${STANDBY_SSH_OPTIONS} "${STANDBY_SSH_USER}@${STANDBY_SSH_HOST}" sudo zfs receive -vu "${filesystem}"
}

function print_filesystem_information {
    local fs="$1"

    local fs_info="$(run sudo zfs list -H -o avail,used,mountpoint -t filesystem "${fs}")"
    local available=$(echo "${fs_info}" | awk '{print $1}')
    local used=$(echo "${fs_info}" | awk '{print $2}')
    local mount=$(echo "${fs_info}" | awk '{print $3}')
    info "ZFS filesystem '${fs}' exists."
    if [ -z "${mount}" -o -z "${used}" -o -z "${available}" ]; then
        error "The ZFS filesystem '${fs}' has no mount point defined."
        bail "Please ensure that a mount point is configured, by using 'zfs set mountpoint'"
    else
        info "ZFS filesystem is mounted at '${mount}'"
    fi
    info "ZFS filesystem has ${available} of space available"
    info "ZFS filesystem has ${used} of space used"
    info "ZFS configuration seems to be correct"
}

function get_latest_snapshot {
    local fs="$1"
    run sudo zfs list -H -t snapshot -o name -S creation | grep -m1 "${fs}"
}

function list_available_zfs_snapshots {
    local snapshot_list=$(run sudo zfs list -H -t snapshot -o name | cut -d "@" -f2 | sort -u)
    info "Available Snapshots:"
    info "${snapshot_list}"
}

function cleanup_zfs_backups {
    local fs="$1"

    if [ "${KEEP_BACKUPS}" -gt 0 ]; then
        # Cleanup all ZFS snapshots except latest ${KEEP_BACKUPS}
        debug "Getting a list of ZFS snapshots to delete"
        local old_snapshots=$(run sudo zfs list -H -r -t snapshot -o name -S creation ${fs} | grep ${fs} | tail -n +$(( ${KEEP_BACKUPS} + 1)))
        if [ -n "${old_snapshots}" ]; then
            debug "Destroying snapshots: ${old_snapshots}"
            echo "${old_snapshots}" | xargs -n 1 sudo zfs destroy
        else
            debug "No ZFS snapshots to clean"
        fi
    fi
}

function mount_zfs_filesystem_on_standby {
    local fs="$1"

    debug "Getting mount point of '${fs}' on the primary file server"
    local mount_point=$(run sudo zfs get mountpoint -H -o value "${fs}")
    debug "Resetting mount point of '${fs}' on the standby file server"
    # Working around an issue with ZFS which results in the remote filesystem being mounted
    run ssh ${STANDBY_SSH_OPTIONS} "${STANDBY_SSH_USER}@${STANDBY_SSH_HOST}" sudo zfs set mountpoint=none "${fs}"
    run ssh ${STANDBY_SSH_OPTIONS} "${STANDBY_SSH_USER}@${STANDBY_SSH_HOST}" sudo zfs set mountpoint="${mount_point}" "${fs}"
}

function cleanup_standby_snapshots {
    local fs="$1"

    # Cleanup all ZFS snapshots except latest ${KEEP_BACKUPS}
    local script="OLD_SNAPSHOTS=\$(sudo zfs list -H -t snapshot -o name -S creation ${fs} | grep ${fs} | tail -n +${KEEP_BACKUPS})
if [ -n \"\${OLD_SNAPSHOTS}\" ]; then
    echo \"Destroying standby snapshots: \${OLD_SNAPSHOTS}\"
    echo \"\${OLD_SNAPSHOTS}\" | xargs -n 1 sudo zfs destroy
fi"
    debug "Cleaning up old snapshots in standby file server '${STANDBY_SSH_HOST}'"
    debug $(run ssh ${STANDBY_SSH_OPTIONS} "${STANDBY_SSH_USER}@${STANDBY_SSH_HOST}" "${script}")
}