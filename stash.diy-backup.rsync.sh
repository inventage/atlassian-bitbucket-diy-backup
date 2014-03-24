#!/bin/bash

function stash_perform_rsync {
    mkdir -p ${STASH_BACKUP_HOME}
    rsync -avh --delete --delete-excluded --exclude=/caches/ --exclude=/data/db.* --exclude=/export/ --exclude=/log/ --exclude=/plugins/.*/ --exclude=/tmp --exclude=/.lock ${STASH_HOME} ${STASH_BACKUP_HOME}
    if [ $? != 0 ]; then
        bail "Unable to rsynch from ${STASH_HOME} to ${STASH_BACKUP_HOME}"
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
    cp -rf ${STASH_RESTORE_HOME}/`basename ${STASH_HOME}` `dirname ${STASH_HOME}`
    info "Performed restore of ${STASH_RESTORE_ROOT} to ${STASH_HOME}"
}
