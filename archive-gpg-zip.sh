# -------------------------------------------------------------------------------------
# An archive strategy for encrypting files using GNU GPG's gpg-zip command
# -------------------------------------------------------------------------------------

check_command "gpg-zip"

function archive_backup {
    mkdir -p "${BITBUCKET_BACKUP_ARCHIVE_ROOT}"
    BITBUCKET_BACKUP_ARCHIVE_NAME="${INSTANCE_NAME}-${TIMESTAMP}.tar.gz.gpg"
    ( cd "${BITBUCKET_BACKUP_ROOT}" || bail "Unable to change directory to '${BITBUCKET_BACKUP_ROOT}'"; \
        run gpg-zip --encrypt --recipient "${BITBUCKET_BACKUP_GPG_RECIPIENT}" \
            --output "${BITBUCKET_BACKUP_ARCHIVE_ROOT}/${BITBUCKET_BACKUP_ARCHIVE_NAME}" . )
}

function prepare_restore_archive {
    BITBUCKET_BACKUP_ARCHIVE_NAME=$1

    if [ -z "${BITBUCKET_BACKUP_ARCHIVE_NAME}" ]; then
        print "Usage: $0 <backup-snapshot>"
        if [ ! -d "${BITBUCKET_BACKUP_ARCHIVE_ROOT}" ]; then
            error "'${BITBUCKET_BACKUP_ARCHIVE_ROOT}' does not exist!"
        else
            print_available_backups
        fi
        exit 99
    fi

    if [ ! -f "${BITBUCKET_BACKUP_ARCHIVE_ROOT}/${BITBUCKET_BACKUP_ARCHIVE_NAME}.tar.gz.gpg" ]; then
        error "'${BITBUCKET_BACKUP_ARCHIVE_ROOT}/${BITBUCKET_BACKUP_ARCHIVE_NAME}.tar.gz.gpg' does not exist!"
        print_available_backups
        exit 99
    fi

    # Check BITBUCKET_HOME and BITBUCKET_DATA_STORES
    if [ -e "${BITBUCKET_HOME}" ]; then
        bail "Cannot restore over existing contents of '${BITBUCKET_HOME}'. Please rename or delete this first."
    fi

    for data_store in "${BITBUCKET_DATA_STORES[@]}"; do
        if [ -e "${data_store}" ]; then
            bail "Cannot restore over existing contents of '${data_store}'. Please rename or delete this first."
        fi
    done

    # Create BITBUCKET_HOME and BITBUCKET_DATA_STORES
    mkdir -p "${BITBUCKET_HOME}"
    chown "${BITBUCKET_UID}":"${BITBUCKET_GID}" "${BITBUCKET_HOME}"

    for data_store in "${BITBUCKET_DATA_STORES[@]}"; do
        mkdir -p "${data_store}"
        chown "${BITBUCKET_UID}":"${BITBUCKET_GID}" "${data_store}"
    done

    # Setup restore paths
    BITBUCKET_RESTORE_ROOT=$(mktemp -d /tmp/bitbucket.diy-restore.XXXXXX)
    BITBUCKET_RESTORE_DB="${BITBUCKET_RESTORE_ROOT}/bitbucket-db"
    BITBUCKET_RESTORE_HOME="${BITBUCKET_RESTORE_ROOT}/bitbucket-home"
    BITBUCKET_RESTORE_DATA_STORES="${BITBUCKET_RESTORE_ROOT}/bitbucket-data-stores"
}

function restore_archive {
    check_config_var "BITBUCKET_BACKUP_ARCHIVE_ROOT"
    check_var "BITBUCKET_BACKUP_ARCHIVE_NAME"
    check_var "BITBUCKET_RESTORE_ROOT"
    run gpg-zip --tar-args "-C ${BITBUCKET_RESTORE_ROOT}" --decrypt "${BITBUCKET_BACKUP_ARCHIVE_ROOT}/${BITBUCKET_BACKUP_ARCHIVE_NAME}.tar.gz.gpg"
}

function cleanup_old_archives {
    # Cleanup of old backups is not currently implemented
    no_op
}

function print_available_backups {
    print "Available backups:"
    # Drop the .tar.gz.gpg extension, to make it a backup identifier
    ls "${BITBUCKET_BACKUP_ARCHIVE_ROOT}" | sed -e 's/\.tar\.gz\.gpg$//g'
}
