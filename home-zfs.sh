# -------------------------------------------------------------------------------------
# A backup and restore strategy using ZFS
# -------------------------------------------------------------------------------------

check_command "zfs"

function prepare_backup_home {
    if [ -z "${ZFS_HOME_TANK_NAME}" ]; then
        bail "Please set var 'ZFS_HOME_TANK_NAME' in '${BACKUP_VARS_FILE}"
    fi

    debug "Validating ZFS_HOME_TANK_NAME=${ZFS_HOME_TANK_NAME}"
    run sudo zfs list -H -o name ${ZFS_HOME_TANK_NAME}
}

function backup_home {
    run sudo zfs snapshot "${ZFS_HOME_TANK_NAME}@${SNAPSHOT_TAG_VALUE}"
}

function prepare_restore_home {
    local snapshot_tag="$1"

    if [ -z "${snapshot_tag}" ]; then
        zfs_snapshots=$(run sudo zfs list -H -t snapshot -o name | cut -d "@" -f2)
        info "Available ZFS snapshots:"
        echo "${zfs_snapshots}"
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

function promote_standby_home {
    # Attempt to run the following commands but don't exit scripts if they fail.
    ! run echo "# The following properties were appended during the promote-standby script." \
        >> ${BITBUCKET_HOME}shared/bitbucket.properties
    ! run echo "jdbc.url=${STANDBY_JDBC_URL}" >> ${BITBUCKET_HOME}shared/bitbucket.properties
    ! run echo "disaster.recovery=true" >> ${BITBUCKET_HOME}shared/bitbucket.properties
    true
}

function replicate_home {
    if [ -z "${ZFS_HOME_TANK_NAME}" ]; then
        bail "Please set var 'ZFS_HOME_TANK_NAME' in '${BACKUP_VARS_FILE}"
    fi

    debug "Taking ZFS snapshot before replicating to ${STANDBY}"
    backup_home

    standby_last_snapshot=$(ssh ${SSH_FLAGS} "${STANDBY_SSH_USER}@${STANDBY}" \
        sudo zfs list -H -t snapshot -o name -S creation | grep "${ZFS_HOME_TANK_NAME}" | sed 1q)
    primary_last_snapshot=$(sudo zfs list -H -t snapshot -o name -S creation | grep "${ZFS_HOME_TANK_NAME}" | sed 1q)

    if [[ -z "${standby_last_snapshot}" ]]; then
        debug "No ZFS snapshot found on '${STANDBY}'"
        send_base_snapshot
    else
        # This will overwrite the standby filesystem with the latest primary snapshot
        run sudo zfs send -R -i "${standby_last_snapshot}" "${primary_last_snapshot}" \
            | ssh ${SSH_FLAGS} "${STANDBY_SSH_USER}@${STANDBY}" sudo zfs receive -F "${ZFS_HOME_TANK_NAME}"
    fi

    if [ "${KEEP_BACKUPS}" -gt 0 ]; then
        cleanup_standby_snapshots
        cleanup_primary_snapshots
    fi
}

function send_base_snapshot {
    info "Setting up standby"
    # This will overwrite the standby filesystem with the latest primary snapshot
    run sudo zfs send -vR -i snapshot "${primary_last_snapshot}"\
        | ssh ${SSH_FLAGS} "${STANDBY_SSH_USER}@${STANDBY}" sudo zfs receive -vF "${ZFS_HOME_TANK_NAME}"
}

function cleanup_standby_snapshots {
    # Cleanup all ZFS snapshots except latest ${KEEP_BACKUPS}
    run ssh ${SSH_FLAGS} ${STANDBY_SSH_USER}@${STANDBY} "sudo zfs list -H -t snapshot -o name -S creation \
        | grep ${ZFS_HOME_TANK_NAME} | tail -n +${KEEP_BACKUPS} | xargs -rn 1 sudo zfs destroy"
}

function cleanup_primary_snapshots {
    # Cleanup all ZFS snapshots except latest ${KEEP_BACKUPS}
    run sudo zfs list -H -t snapshot -o name -S creation | grep ${ZFS_HOME_TANK_NAME} | tail -n +${KEEP_BACKUPS} \
        | xargs -rn 1 sudo zfs destroy
}

function cleanup_home_backups {
    no_op
}