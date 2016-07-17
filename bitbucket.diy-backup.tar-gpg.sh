#!/bin/bash

check_command "tar"
check_command "gpg-zip"

SCRIPT_DIR=$(dirname $0)
source ${SCRIPT_DIR}/bitbucket.diy-backup.utils.sh

function archive_backup {
    if [[ -z ${BITBUCKET_BACKUP_GPG_RECIPIENT} ]]; then
        bail "In order to encrypt the backup you must set the 'BITBUCKET_BACKUP_GPG_RECIPIENT' configuration variable. Exiting..."
    fi
    mkdir -p ${BITBUCKET_BACKUP_ARCHIVE_ROOT}
    BITBUCKET_BACKUP_ARCHIVE_NAME=`perl -we 'use Time::Piece; my $sydTime = localtime; print "bitbucket-", $sydTime->strftime("%Y%m%d-%H%M%S-"), substr($sydTime->epoch, -3), ".tar.gz.gpg"'`
    (
        # in a subshell to avoid changing working dir on the caller
        cd ${BITBUCKET_BACKUP_ROOT}
        run gpg-zip --encrypt --recipient ${BITBUCKET_BACKUP_GPG_RECIPIENT} \
            --output ${BITBUCKET_BACKUP_ARCHIVE_ROOT}/${BITBUCKET_BACKUP_ARCHIVE_NAME} .
    )
}

function prepare_restore_archive {
    BITBUCKET_BACKUP_ARCHIVE_NAME=$1

    if [ -z ${BITBUCKET_BACKUP_ARCHIVE_NAME} ]; then
        echo "Usage: $0 <backup-file-name>.tar.gz"  > /dev/stderr
        if [ ! -d ${BITBUCKET_BACKUP_ARCHIVE_ROOT} ]; then
            error "${BITBUCKET_BACKUP_ARCHIVE_ROOT} does not exist!"
        else
            print_available_backups
        fi
        exit 99
    fi

    if [ ! -f ${BITBUCKET_BACKUP_ARCHIVE_ROOT}/${BITBUCKET_BACKUP_ARCHIVE_NAME} ]; then
        error "${BITBUCKET_BACKUP_ARCHIVE_ROOT}/${BITBUCKET_BACKUP_ARCHIVE_NAME} does not exist!"
        print_available_backups
        exit 99
    fi

    # Check BITBUCKET_HOME
    if [ -e ${BITBUCKET_HOME} ]; then
        bail "Cannot restore over existing contents of ${BITBUCKET_HOME}. Please rename or delete this first."
    fi
}

function restore_archive {
    # Create BITBUCKET_HOME
    mkdir -p ${BITBUCKET_HOME}
    chown ${BITBUCKET_UID}:${BITBUCKET_GID} ${BITBUCKET_HOME}

    # Setup restore paths
    BITBUCKET_RESTORE_ROOT=$(mktemp -d /tmp/bitbucket.diy-restore.XXXXXX)
    BITBUCKET_RESTORE_DB=${BITBUCKET_RESTORE_ROOT}/bitbucket-db
    BITBUCKET_RESTORE_HOME=${BITBUCKET_RESTORE_ROOT}/bitbucket-home

    if [ -f ${BITBUCKET_BACKUP_ARCHIVE_NAME} ]; then
        BITBUCKET_BACKUP_ARCHIVE_NAME=${BITBUCKET_BACKUP_ARCHIVE_NAME}
    else
        BITBUCKET_BACKUP_ARCHIVE_NAME=${BITBUCKET_BACKUP_ARCHIVE_ROOT}/${BITBUCKET_BACKUP_ARCHIVE_NAME}
    fi
    run gpg-zip --tar-args "-C ${BITBUCKET_RESTORE_ROOT}" --decrypt ${BITBUCKET_BACKUP_ARCHIVE_NAME}
}

function cleanup_old_archives {
    # Cleanup of old backups is not currently implemented
    no_op
}

function print_available_backups {
    echo "Available backups:"  > /dev/stderr
    ls ${BITBUCKET_BACKUP_ARCHIVE_ROOT}
}