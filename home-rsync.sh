# -------------------------------------------------------------------------------------
# A backup and restore strategy using RSync
# -------------------------------------------------------------------------------------

check_command "rsync"

function prepare_backup_home {
    check_config_var "BITBUCKET_BACKUP_HOME"
    check_config_var "BITBUCKET_HOME"

    perform_rsync
}

function backup_home {
    perform_rsync
}

function prepare_restore_home {
    check_var "BITBUCKET_RESTORE_HOME"
    check_config_var "BITBUCKET_HOME"

    no_op
}

function restore_home {
    local rsync_quiet=-q
    if [ "${BITBUCKET_VERBOSE_BACKUP}" = "true" ]; then
        rsync_quiet=
    fi

    run rsync -av ${rsync_quiet} "${BITBUCKET_RESTORE_HOME}/" "${BITBUCKET_HOME}/"
}

function perform_rsync {
    local rsync_exclude_repos=
    for repo_id in ${BITBUCKET_BACKUP_EXCLUDE_REPOS[@]}; do
        rsync_exclude_repos="${rsync_exclude_repos} --exclude=/shared/data/repositories/${repo_id}"
    done

    local rsync_quiet=-q
    if [ "${BITBUCKET_VERBOSE_BACKUP}" = true ]; then
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
        --exclude=/log/ \
        --exclude=/plugins/.*/ \
        --exclude=/tmp \
        --exclude=/.lock \
        --exclude=/shared/.lock \
        ${rsync_exclude_repos} \
        "${BITBUCKET_HOME}" "${BITBUCKET_BACKUP_HOME}"
}

function cleanup_home_backups {
     # Not required as old backups with this strategy are typically cleaned up in the archiving strategy.
    no_op
}

# ----------------------------------------------------------------------------------------------------------------------
# Disaster recovery functions
# ----------------------------------------------------------------------------------------------------------------------

function promote_home {
    bail "Disaster recovery is not available with this home strategy"
}

function replicate_home {
    bail "Disaster recovery is not available with this home strategy"
}

function setup_home_replication {
    bail "Disaster recovery is not available with this home strategy"
}
