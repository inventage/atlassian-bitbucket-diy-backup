#!/bin/bash

# -------------------------------------------------------------------------------------
# An archive strategy for encrypting files using GNU GPG's gpg-zip command
# -------------------------------------------------------------------------------------

check_command "gpg-zip"

SCRIPT_DIR=$(dirname "$0")
source "${SCRIPT_DIR}/utils.sh"

function archive_backup {
    mkdir -p "${BITBUCKET_BACKUP_ARCHIVE_ROOT}"
    BITBUCKET_BACKUP_ARCHIVE_NAME="$(date "+${INSTANCE_NAME}-%Y%m%d-%H%M%S.tar.gz.gpg")"
    ( cd "${BITBUCKET_BACKUP_ROOT}" || bail "Unable to change directory to '${BITBUCKET_BACKUP_ROOT}'"; \
        run gpg-zip --encrypt --recipient "${BITBUCKET_BACKUP_GPG_RECIPIENT}" \
            --output "${BITBUCKET_BACKUP_ARCHIVE_ROOT}/${BITBUCKET_BACKUP_ARCHIVE_NAME}" . )
}

function prepare_restore_archive {
    BITBUCKET_BACKUP_ARCHIVE_NAME=$1

    if [ -z "${BITBUCKET_BACKUP_ARCHIVE_NAME}" ]; then
        print "Usage: $0 <backup-file-name>.tar.gz.gpg"
        if [ ! -d "${BITBUCKET_BACKUP_ARCHIVE_ROOT}" ]; then
            error "'${BITBUCKET_BACKUP_ARCHIVE_ROOT}' does not exist!"
        else
            print_available_backups
        fi
        exit 99
    fi

    if [ ! -f "${BITBUCKET_BACKUP_ARCHIVE_ROOT}/${BITBUCKET_BACKUP_ARCHIVE_NAME}" ]; then
        error "'${BITBUCKET_BACKUP_ARCHIVE_ROOT}/${BITBUCKET_BACKUP_ARCHIVE_NAME}' does not exist!"
        print_available_backups
        exit 99
    fi

    # Check and create BITBUCKET_HOME
    if [ -e "${BITBUCKET_HOME}" ]; then
        bail "Cannot restore over existing contents of '${BITBUCKET_HOME}'. Please rename or delete this first."
    fi
    mkdir -p "${BITBUCKET_HOME}"
    chown "${BITBUCKET_UID}":"${BITBUCKET_GID}" "${BITBUCKET_HOME}"

    # Setup restore paths
    BITBUCKET_RESTORE_ROOT=$(mktemp -d /tmp/bitbucket.diy-restore.XXXXXX)
    BITBUCKET_RESTORE_DB="${BITBUCKET_RESTORE_ROOT}/bitbucket-db"
    BITBUCKET_RESTORE_HOME="${BITBUCKET_RESTORE_ROOT}/bitbucket-home"
}

function restore_archive {
    if [ ! -f "${BITBUCKET_BACKUP_ARCHIVE_NAME}" ]; then
        BITBUCKET_BACKUP_ARCHIVE_NAME="${BITBUCKET_BACKUP_ARCHIVE_ROOT}/${BITBUCKET_BACKUP_ARCHIVE_NAME}"
    fi
    run gpg-zip --tar-args "-C ${BITBUCKET_RESTORE_ROOT}" --decrypt "${BITBUCKET_BACKUP_ARCHIVE_NAME}"
}

function bitbucket_cleanup {
    # Cleanup of old backups is not currently implemented
    no_op
}

function print_available_backups {
    print "Available backups:"
    ls "${BITBUCKET_BACKUP_ARCHIVE_ROOT}"
}
