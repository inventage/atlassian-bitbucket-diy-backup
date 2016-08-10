# -------------------------------------------------------------------------------------
# A backup and restore strategy using ZFS
# -------------------------------------------------------------------------------------

check_command "zfs"

function prepare_backup_home {
    if [ -z "${ZFS_HOME_TANK_NAME}" ]; then
        bail "Please set var 'ZFS_HOME_TANK_NAME' in '${BACKUP_VARS_FILE}"
    fi

    debug "Validating ZFS_HOME_TANK_NAME=${ZFS_HOME_TANK_NAME}"
    $(run sudo zfs list -H -o name "${ZFS_HOME_TANK_NAME}")
}

function backup_home {
    run sudo zfs snapshot "${ZFS_HOME_TANK_NAME}@$(date +"%Y%m%d-%H%M%S")"
}

function prepare_restore_home {
    local snapshot="$1"

    if [[ -z ${snapshot} ]]; then
        snapshot_list=$(run sudo zfs list -H -t snapshot -o name)
        info "Available Snapshots:"
        info "${snapshot_list}"
        bail "Please select a snapshot to restore"
    fi

    debug "Validating ZFS snapshot '${snapshot}'"
    run sudo zfs list -t snapshot -o name "${snapshot}"

    RESTORE_ZFS_SNAPSHOT="${snapshot}"
}

function restore_home {
    debug "Rolling back to ZFS snapshot '${RESTORE_ZFS_SNAPSHOT}'"
    run sudo zfs rollback "${RESTORE_ZFS_SNAPSHOT}"
}

function prepare_failover_home {
    no_op
}

function failover_home {
    no_op
}

function prepare_replicate_home {
    debug "Taking ZFS before replicating to ${STANDBY}"
    backup_home

    STANDBY_LAST_SNAPSHOT=$(ssh "${STANDBY_SSH_USER}@${STANDBY}" \
        sudo zfs list -H -t snapshot -o name -S creation | grep "${ZFS_HOME_TANK_NAME}" | head -n 1)
    LATEST_SNAPSHOT=$(sudo zfs list -H -t snapshot -o name -S creation | grep "${ZFS_HOME_TANK_NAME}" | head -n 1)
}

function replicate_home {
    if [[ -z "${STANDBY_LAST_SNAPSHOT}" ]]; then
        debug "No ZFS snapshot found on '${STANDBY}'"
        setup_home_replication
    else
        run sudo zfs send -R -i "${STANDBY_LAST_SNAPSHOT}" "${LATEST_SNAPSHOT}" \
            | ssh "${STANDBY_SSH_USER}@${STANDBY}" sudo zfs receive -F "${ZFS_HOME_TANK_NAME}"
    fi
}

function setup_home_replication {
    info "Setting up standby"
    run sudo zfs send -vR -i snapshot "${LATEST_SNAPSHOT}"\
        | ssh "${STANDBY_SSH_USER}@${STANDBY}" sudo zfs receive -vF "${ZFS_HOME_TANK_NAME}"
}
