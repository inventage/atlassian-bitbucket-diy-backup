#!/bin/bash

check_command "rsync"

SCRIPT_DIR=$(dirname $0)
source ${SCRIPT_DIR}/bitbucket.diy-backup.utils.sh

function bitbucket_perform_rsync {
    for repo_id in ${BITBUCKET_BACKUP_EXCLUDE_REPOS[@]}; do
        RSYNC_EXCLUDE_REPOS="${RSYNC_EXCLUDE_REPOS} --exclude=/shared/data/repositories/${repo_id}"
    done

    RSYNC_QUIET=-q
    if [ "${BITBUCKET_VERBOSE_BACKUP}" = "TRUE" ]; then
        RSYNC_QUIET=
    fi

    mkdir -p ${BITBUCKET_BACKUP_HOME}
    run rsync -avh ${RSYNC_QUIET} --delete --delete-excluded --exclude=/caches/ --exclude=/shared/data/db.* --exclude=/shared/search/data/ --exclude=/export/ --exclude=/log/ --exclude=/plugins/.*/ --exclude=/tmp --exclude=/.lock --exclude=/shared/.lock ${RSYNC_EXCLUDE_REPOS} ${BITBUCKET_HOME} ${BITBUCKET_BACKUP_HOME}
}

function bitbucket_prepare_home {
    bitbucket_perform_rsync
}

function bitbucket_backup_home {
    bitbucket_perform_rsync
}

function bitbucket_restore_home {
    RSYNC_QUIET=-q
    if [ "${BITBUCKET_VERBOSE_BACKUP}" = "TRUE" ]; then
        RSYNC_QUIET=
    fi

    run rsync -av ${RSYNC_QUIET} ${BITBUCKET_RESTORE_HOME}/ ${BITBUCKET_HOME}/
}

function bitbucket_cleanup_home_backups {
    no_op
}
