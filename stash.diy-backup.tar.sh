#!/bin/bash

function stash_backup_archive {
    mkdir -p ${STASH_BACKUP_ARCHIVE_ROOT}
    STASH_BACKUP_ARCHIVE_NAME=`perl -we 'use Time::Piece; my $sydTime = localtime; print "stash-", $sydTime->strftime("%Y%m%d-%H%M%S-"), substr($sydTime->epoch, -3), ".tar.gz"'`
    tar -czf ${STASH_BACKUP_ARCHIVE_ROOT}/${STASH_BACKUP_ARCHIVE_NAME} -C ${STASH_BACKUP_ROOT} .

    info "Archived ${STASH_BACKUP_ROOT} into ${STASH_BACKUP_ARCHIVE_ROOT}/${STASH_BACKUP_ARCHIVE_NAME}"
}

function stash_restore_archive {
    if [ -f ${STASH_BACKUP_ARCHIVE_NAME} ]; then
        STASH_BACKUP_ARCHIVE_NAME=${STASH_BACKUP_ARCHIVE_NAME}
    else
        STASH_BACKUP_ARCHIVE_NAME=${STASH_BACKUP_ARCHIVE_ROOT}/${STASH_BACKUP_ARCHIVE_NAME}
    fi
    tar -xzf ${STASH_BACKUP_ARCHIVE_NAME} -C ${STASH_RESTORE_ROOT}

    info "Extracted ${STASH_BACKUP_ARCHIVE_ROOT}/${STASH_BACKUP_ARCHIVE_NAME} into ${STASH_RESTORE_ROOT}"
}
