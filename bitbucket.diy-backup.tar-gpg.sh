#!/bin/bash

check_command "tar"
check_command "gpg-zip"

function bitbucket_backup_archive {
    if [[ -z ${BITBUCKET_BACKUP_GPG_RECIPIENT} ]]; then
        bail "In order to encrypt the backup you must set the 'BITBUCKET_BACKUP_GPG_RECIPIENT' configuration variable. Exiting..."
    fi
    mkdir -p ${BITBUCKET_BACKUP_ARCHIVE_ROOT}
    BITBUCKET_BACKUP_ARCHIVE_NAME=`perl -we 'use Time::Piece; my $sydTime = localtime; print "bitbucket-", $sydTime->strftime("%Y%m%d-%H%M%S-"), substr($sydTime->epoch, -3), ".tar.gz.gpg"'`

    info "Archiving ${BITBUCKET_BACKUP_ROOT} into ${BITBUCKET_BACKUP_ARCHIVE_ROOT}/${BITBUCKET_BACKUP_ARCHIVE_NAME}"
    info "Encrypting for ${BITBUCKET_BACKUP_GPG_RECIPIENT}"
    (
        # in a subshell to avoid changing working dir on the caller
        cd ${BITBUCKET_BACKUP_ROOT}
        gpg-zip --encrypt --recipient ${BITBUCKET_BACKUP_GPG_RECIPIENT} \
            --output ${BITBUCKET_BACKUP_ARCHIVE_ROOT}/${BITBUCKET_BACKUP_ARCHIVE_NAME} .
    )
    info "Archived ${BITBUCKET_BACKUP_ROOT} into ${BITBUCKET_BACKUP_ARCHIVE_ROOT}/${BITBUCKET_BACKUP_ARCHIVE_NAME}"
}

function bitbucket_restore_archive {
    if [ -f ${BITBUCKET_BACKUP_ARCHIVE_NAME} ]; then
        BITBUCKET_BACKUP_ARCHIVE_NAME=${BITBUCKET_BACKUP_ARCHIVE_NAME}
    else
        BITBUCKET_BACKUP_ARCHIVE_NAME=${BITBUCKET_BACKUP_ARCHIVE_ROOT}/${BITBUCKET_BACKUP_ARCHIVE_NAME}
    fi
    gpg-zip --tar-args "-C ${BITBUCKET_RESTORE_ROOT}" --decrypt ${BITBUCKET_BACKUP_ARCHIVE_NAME}

    info "Extracted ${BITBUCKET_BACKUP_ARCHIVE_NAME} into ${BITBUCKET_RESTORE_ROOT}"
}

function bitbucket_cleanup {
    # Cleanup of old backups is not currently implemented
    no_op
}