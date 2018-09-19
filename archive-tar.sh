# -------------------------------------------------------------------------------------
# An archive strategy using Tar and Gzip
# -------------------------------------------------------------------------------------

check_command "tar"

function archive_backup {
    check_config_var "BITBUCKET_BACKUP_ARCHIVE_ROOT"
    check_config_var "INSTANCE_NAME"
    check_config_var "BITBUCKET_BACKUP_ROOT"

    mkdir -p "${BITBUCKET_BACKUP_ARCHIVE_ROOT}"
    BITBUCKET_BACKUP_ARCHIVE_NAME="${INSTANCE_NAME}-${TIMESTAMP}.tar.gz"
    run tar -czf "${BITBUCKET_BACKUP_ARCHIVE_ROOT}/${BITBUCKET_BACKUP_ARCHIVE_NAME}" -C "${BITBUCKET_BACKUP_ROOT}" .
}

function prepare_restore_archive {
    BITBUCKET_BACKUP_ARCHIVE_NAME=$1

    if [ -z "${BITBUCKET_BACKUP_ARCHIVE_NAME}" ]; then
        print "Usage: $0 <backup-snapshot>"
        if [ ! -d "${BITBUCKET_BACKUP_ARCHIVE_ROOT}" ]; then
            error "'${BITBUCKET_BACKUP_ARCHIVE_ROOT}' does not exist!"
        else
            available_backups
        fi
        exit 99
    fi

    if [ ! -f "${BITBUCKET_BACKUP_ARCHIVE_ROOT}/${BITBUCKET_BACKUP_ARCHIVE_NAME}.tar.gz" ]; then
        error "'${BITBUCKET_BACKUP_ARCHIVE_ROOT}/${BITBUCKET_BACKUP_ARCHIVE_NAME}.tar.gz' does not exist!"
        available_backups
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

    check_config_var "BITBUCKET_UID"
    check_config_var "BITBUCKET_GID"

    # Create BITBUCKET_HOME and BITBUCKET_DATA_STORES
    run mkdir -p "${BITBUCKET_HOME}"
    run chown "${BITBUCKET_UID}":"${BITBUCKET_GID}" "${BITBUCKET_HOME}"

    for store in "${BITBUCKET_DATA_STORES[@]}"; do
        run mkdir -p "${store}"
        run chown "${BITBUCKET_UID}":"${BITBUCKET_GID}" "${store}"
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
    run tar -xzf "${BITBUCKET_BACKUP_ARCHIVE_ROOT}/${BITBUCKET_BACKUP_ARCHIVE_NAME}.tar.gz" -C "${BITBUCKET_RESTORE_ROOT}"
}

function cleanup_old_archives {
    # Cleanup of old backups is not currently implemented
    no_op
}

function available_backups {
    check_config_var "BITBUCKET_BACKUP_ARCHIVE_ROOT"
    print "Available backups:"
    # Drop the .tar.gz extension, to make it a backup identifier
    ls "${BITBUCKET_BACKUP_ARCHIVE_ROOT}" | sed -e 's/\.tar\.gz$//g'
}
