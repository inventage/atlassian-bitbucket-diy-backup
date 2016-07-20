#!/bin/bash

# -------------------------------------------------------------------------------------
# A backup and restore strategy using RSync
# -------------------------------------------------------------------------------------

check_command "rsync"

SCRIPT_DIR=$(dirname "$0")
source "${SCRIPT_DIR}/utils.sh"

function prepare_backup_home {
    perform_rsync
}

function backup_home {
    perform_rsync
}

function prepare_restore_home {
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
        --exclude=/shared/data/db.* \
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