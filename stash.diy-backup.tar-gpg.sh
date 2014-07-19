#!/bin/bash

check_command "tar"
check_command "gpg-zip"

function stash_backup_archive {
    mkdir -p ${STASH_BACKUP_ARCHIVE_ROOT}
    STASH_BACKUP_ARCHIVE_NAME=`perl -we 'use Time::Piece; my $sydTime = localtime; print "stash-", $sydTime->strftime("%Y%m%d-%H%M%S-"), substr($sydTime->epoch, -3), ".tar.gz.gpg"'`

    info "Archiving ${STASH_BACKUP_ROOT} into ${STASH_BACKUP_ARCHIVE_ROOT}/${STASH_BACKUP_ARCHIVE_NAME}"
    info "Encrypting for ${STASH_BACKUP_GPG_RECIPIENT}"
    (
        # in a subshell to avoid changing working dir on the caller
        cd ${STASH_BACKUP_ROOT}
        gpg-zip --tar-args "-z -C ${STASH_BACKUP_ROOT}" --encrypt --recipient ${STASH_BACKUP_GPG_RECIPIENT} \
            --output ${STASH_BACKUP_ARCHIVE_ROOT}/${STASH_BACKUP_ARCHIVE_NAME} .
    )
    info "Archived ${STASH_BACKUP_ROOT} into ${STASH_BACKUP_ARCHIVE_ROOT}/${STASH_BACKUP_ARCHIVE_NAME}"
}

function stash_restore_archive {
    if [ -f ${STASH_BACKUP_ARCHIVE_NAME} ]; then
        STASH_BACKUP_ARCHIVE_NAME=${STASH_BACKUP_ARCHIVE_NAME}
    else
        STASH_BACKUP_ARCHIVE_NAME=${STASH_BACKUP_ARCHIVE_ROOT}/${STASH_BACKUP_ARCHIVE_NAME}
    fi
    gpg-zip --tar-args "-z -C ${STASH_RESTORE_ROOT}" --decrypt ${STASH_BACKUP_ARCHIVE_ROOT}/${STASH_BACKUP_ARCHIVE_NAME}

    info "Extracted ${STASH_BACKUP_ARCHIVE_ROOT}/${STASH_BACKUP_ARCHIVE_NAME} into ${STASH_RESTORE_ROOT}"
}
