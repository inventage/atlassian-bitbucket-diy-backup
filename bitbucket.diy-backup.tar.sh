#!/bin/bash

check_command "tar"

SCRIPT_DIR=$(dirname $0)
source ${SCRIPT_DIR}/bitbucket.diy-backup.utils.sh

function bitbucket_backup_archive {
    mkdir -p ${BITBUCKET_BACKUP_ARCHIVE_ROOT}
    BITBUCKET_BACKUP_ARCHIVE_NAME=`perl -we 'use Time::Piece; my $sydTime = localtime; print "bitbucket-", $sydTime->strftime("%Y%m%d-%H%M%S-"), substr($sydTime->epoch, -3), ".tar.gz"'`
    run tar -czf ${BITBUCKET_BACKUP_ARCHIVE_ROOT}/${BITBUCKET_BACKUP_ARCHIVE_NAME} -C ${BITBUCKET_BACKUP_ROOT} .
}

function bitbucket_restore_archive {
    if [ -f ${BITBUCKET_BACKUP_ARCHIVE_NAME} ]; then
        BITBUCKET_BACKUP_ARCHIVE_NAME=${BITBUCKET_BACKUP_ARCHIVE_NAME}
    else
        BITBUCKET_BACKUP_ARCHIVE_NAME=${BITBUCKET_BACKUP_ARCHIVE_ROOT}/${BITBUCKET_BACKUP_ARCHIVE_NAME}
    fi
    run tar -xzf ${BITBUCKET_BACKUP_ARCHIVE_NAME} -C ${BITBUCKET_RESTORE_ROOT}
}

function bitbucket_cleanup {
    # Cleanup of old backups is not currently implemented
    no_op
}