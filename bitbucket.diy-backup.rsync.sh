#!/bin/bash

check_command "rsync"

function bitbucket_perform_rsync {
    for repo_id in ${BITBUCKET_BACKUP_EXCLUDE_REPOS[@]}; do
      RSYNC_EXCLUDE_REPOS="${RSYNC_EXCLUDE_REPOS} --exclude=/shared/data/repositories/${repo_id}"
    done

    RSYNC_QUIET=-q
    if [ "${BITBUCKET_VERBOSE_BACKUP}" == "TRUE" ]; then
        RSYNC_QUIET=
    fi

    mkdir -p ${BITBUCKET_BACKUP_HOME}
    rsync -avh ${RSYNC_QUIET} --delete --delete-excluded --exclude=/caches/ --exclude=/shared/data/db.* --exclude=/export/ --exclude=/log/ --exclude=/plugins/.*/ --exclude=/tmp --exclude=/.lock --exclude=/shared/.lock ${RSYNC_EXCLUDE_REPOS} ${BITBUCKET_HOME} ${BITBUCKET_BACKUP_HOME}
    if [ $? != 0 ]; then
        bail "Unable to rsync from ${BITBUCKET_HOME} to ${BITBUCKET_BACKUP_HOME}"
    fi
}

function bitbucket_prepare_home {
    bitbucket_perform_rsync
    info "Prepared backup of ${BITBUCKET_HOME} to ${BITBUCKET_BACKUP_HOME}"
}

function bitbucket_backup_home {
    bitbucket_perform_rsync
    info "Performed backup of ${BITBUCKET_HOME} to ${BITBUCKET_BACKUP_HOME}"
}

function bitbucket_restore_home {
    RSYNC_QUIET=-q
    if [ "${BITBUCKET_VERBOSE_BACKUP}" == "TRUE" ]; then
        RSYNC_QUIET=
    fi

    rsync -av ${RSYNC_QUIET} ${BITBUCKET_RESTORE_HOME}/ ${BITBUCKET_HOME}/
    info "Performed restore of ${BITBUCKET_RESTORE_HOME} to ${BITBUCKET_HOME}"
}
