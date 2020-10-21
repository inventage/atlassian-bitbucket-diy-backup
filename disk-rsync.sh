# -------------------------------------------------------------------------------------
# A backup and restore strategy using RSync
# -------------------------------------------------------------------------------------

check_command "rsync"

function prepare_backup_disk {
    check_config_var "BITBUCKET_BACKUP_HOME"
    check_config_var "BITBUCKET_HOME"

    # BITBUCKET_RESTORE_DATA_STORES needs to be set if any data stores are configured
    if [ -n "${BITBUCKET_DATA_STORES}" ]; then
        check_var "BITBUCKET_BACKUP_DATA_STORES"
    fi

    # Perform an initial rsync whilst the application is live to limit time the application needs to be locked for
    perform_rsync_home_directory
    perform_rsync_data_stores
}

function backup_disk {
    # Now the application is locked, rsync again to ensure we have a consistent view of the filesystem
    perform_rsync_home_directory
    perform_rsync_data_stores
}

function prepare_restore_disk {
    check_var "BITBUCKET_RESTORE_HOME"
    check_config_var "BITBUCKET_HOME"

    # BITBUCKET_RESTORE_DATA_STORES needs to be set if any data stores are configured
    if [ -n "${BITBUCKET_DATA_STORES}" ]; then
        check_var "BITBUCKET_RESTORE_DATA_STORES"
    fi

    # Check BITBUCKET_HOME and BITBUCKET_DATA_STORES are empty
    ensure_empty_directory "${BITBUCKET_HOME}"
    for data_store in "${BITBUCKET_DATA_STORES[@]}"; do
        ensure_empty_directory "${data_store}"
    done

    # Create BITBUCKET_HOME and BITBUCKET_DATA_STORES
    check_config_var "BITBUCKET_UID"
    check_config_var "BITBUCKET_GID"
    run mkdir -p "${BITBUCKET_HOME}"
    run chown "${BITBUCKET_UID}":"${BITBUCKET_GID}" "${BITBUCKET_HOME}"

    for data_store in "${BITBUCKET_DATA_STORES[@]}"; do
        run mkdir -p "${data_store}"
        run chown "${BITBUCKET_UID}":"${BITBUCKET_GID}" "${data_store}"
    done
}

function restore_disk {
    local rsync_quiet=-q
    if [ "${BITBUCKET_VERBOSE_BACKUP}" = "true" ]; then
        rsync_quiet=
    fi

    run rsync -av ${rsync_quiet} "${BITBUCKET_RESTORE_HOME}/" "${BITBUCKET_HOME}/"

    for data_store in "${BITBUCKET_DATA_STORES[@]}"; do
        run rsync -av ${rsync_quiet} "${BITBUCKET_RESTORE_DATA_STORES}/${data_store}" "${data_store}/"
    done
}

function perform_rsync_data_stores {
    local rsync_exclude_repos=
    for repo_id in ${BITBUCKET_BACKUP_EXCLUDE_REPOS[@]}; do
        rsync_exclude_repos="${rsync_exclude_repos} --exclude=/repositories/*/*/${repo_id}"
    done

    local rsync_quiet=-q
    if [ "${BITBUCKET_VERBOSE_BACKUP}" = "true" ]; then
        rsync_quiet=
    fi

    for data_store in "${BITBUCKET_DATA_STORES[@]}"; do
        mkdir -p "${BITBUCKET_BACKUP_DATA_STORES}/${data_store}"
        run rsync -avh ${rsync_quiet} --delete --delete-excluded \
            ${rsync_exclude_repos} \
            "${data_store}" "${BITBUCKET_BACKUP_DATA_STORES}/${data_store}"
    done
}

function perform_rsync_home_directory {
    local rsync_exclude_repos=
    for repo_id in ${BITBUCKET_BACKUP_EXCLUDE_REPOS[@]}; do
        rsync_exclude_repos="${rsync_exclude_repos} --exclude=/shared/data/repositories/${repo_id}"
    done

    local rsync_quiet=-q
    if [ "${BITBUCKET_VERBOSE_BACKUP}" = "true" ]; then
        rsync_quiet=
    fi

    mkdir -p "${BITBUCKET_BACKUP_HOME}"
    run rsync -avh ${rsync_quiet} --delete --delete-excluded \
        --exclude=/caches/ \
        --exclude=/data/db.* \
        --exclude=/shared/data/db.* \
        --exclude=/search/data/ \
        --exclude=/shared/search/data/ \
        --exclude=/export/ \
        --exclude=/shared/export/ \
        --exclude=/log/ \
        --exclude=/plugins/.*/ \
        --exclude=/tmp \
        --exclude=/.lock \
        --exclude=/shared/.lock \
        ${rsync_exclude_repos} \
        "${BITBUCKET_HOME}" "${BITBUCKET_BACKUP_HOME}"
}

function cleanup_incomplete_disk_backup {
    # Not required because rsync backup is an incremental and idempotent process.
    no_op
}

function cleanup_old_disk_backups {
     # Not required as old backups with this strategy are typically cleaned up in the archiving strategy.
    no_op
}

# ----------------------------------------------------------------------------------------------------------------------
# Disaster recovery functions
# ----------------------------------------------------------------------------------------------------------------------

function promote_home {
    bail "Disaster recovery is not available with this disk strategy"
}

function replicate_disk {
    bail "Disaster recovery is not available with this disk strategy"
}

function setup_disk_replication {
    bail "Disaster recovery is not available with this disk strategy"
}
