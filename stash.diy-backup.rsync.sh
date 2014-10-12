#!/bin/bash

check_command "rsync"

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
    mkdir -p ${STASH_HOME}
    chown stash:stash ${STASH_HOME}
    cp -a ${STASH_RESTORE_HOME}/* ${STASH_HOME}
    info "Performed restore of ${STASH_RESTORE_HOME} to ${STASH_HOME}"
}
