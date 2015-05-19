#!/bin/bash

check_command "rsync"

function stash_perform_rsync {
    for repo_id in ${STASH_BACKUP_EXCLUDE_REPOS[@]}; do
      RSYNC_EXCLUDE_REPOS="${RSYNC_EXCLUDE_REPOS} --exclude=/shared/data/repositories/${repo_id}"
    done

    RSYNC_QUIET=-q
    if [ "${STASH_VERBOSE_BACKUP}" == "TRUE" ]; then
        RSYNC_QUIET=
    fi

    mkdir -p ${STASH_BACKUP_HOME}
    rsync -avh ${RSYNC_QUIET} --delete --delete-excluded --exclude=/caches/ --exclude=/data/db.* --exclude=/export/ --exclude=/log/ --exclude=/plugins/.*/ --exclude=/tmp --exclude=/.lock ${RSYNC_EXCLUDE_REPOS} ${STASH_HOME} ${STASH_BACKUP_HOME}
    if [ $? != 0 ]; then
        bail "Unable to rsync from ${STASH_HOME} to ${STASH_BACKUP_HOME}"
    fi
}

function stash_prepare_home {
    stash_perform_rsync
    info "Prepared backup of ${STASH_HOME} to ${STASH_BACKUP_HOME}"
}

function stash_backup_home {
    stash_perform_rsync
    info "Performed backup of ${STASH_HOME} to ${STASH_BACKUP_HOME}"
}

function stash_restore_home {
    RSYNC_QUIET=-q
    if [ "${STASH_VERBOSE_BACKUP}" == "TRUE" ]; then
        RSYNC_QUIET=
    fi

    rsync -av ${RSYNC_QUIET} ${STASH_RESTORE_HOME}/ ${STASH_HOME}/
    info "Performed restore of ${STASH_RESTORE_HOME} to ${STASH_HOME}"
}
