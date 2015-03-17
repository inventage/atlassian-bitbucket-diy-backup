#!/bin/bash

check_command "aws"

# The database data directory may be located in the same volume as the home directory
# in which case there's no need to take a new snapshot
if [ -z "${BACKUP_DB_DATA_DIRECTORY_VOLUME_ID}" ]; then
    function stash_prepare_db {
        info "No database volume id has been provided as BACKUP_DB_DATA_DIRECTORY_VOLUME_ID in ${BACKUP_VARS_FILE}. Skipping database data directory snapshot"
    }

    function stash_backup_db {
        info "No database volume id has been provided as BACKUP_DB_DATA_DIRECTORY_VOLUME_ID in ${BACKUP_VARS_FILE}. Skipping database data directory snapshot"
    }
else
    function stash_prepare_db {
        if [ -z "${BACKUP_DB_DIRECTORY_MOUNT_POINT}" ]; then
            error "The database data directory mount point must be set as BACKUP_DB_DIRECTORY_MOUNT_POINT in ${BACKUP_VARS_FILE}"
            bail "See stash.diy-backup.vars.sh.example for the defaults."
        fi

        info "Preparing backup of database data directory"

        snapshot_db "Prepare backup: ${PRODUCT} database data directory snapshot"
    }

    function stash_backup_db {
        # Freeze the db data directory filesystem to ensure consistency
        freeze_db_directory
        # Add a clean up routine to ensure we unfreeze the db data directory filesystem
        add_cleanup_routine unfreeze_db_directory

        info "Performing backup of database data directory"

        snapshot_db "Perform backup: ${PRODUCT} database data directory snapshot"

        unfreeze_db_directory
    }
fi

function snapshot_db {
    snapshot_ebs_volume "${BACKUP_DB_DATA_DIRECTORY_VOLUME_ID}" "${1}"
}

function stash_restore_db {
    # The database data directory may be located in the same volume as the home directory
    # in which case there's no need to restore it into a new volume
    if [ -z "${RESTORE_DB_DATA_DIRECTORY_SNAPSHOT_ID}" ]; then
        info "No database snapshot id has been provided as RESTORE_DB_DATA_DIRECTORY_SNAPSHOT_ID in ${BACKUP_VARS_FILE}. Skipping database data directory restore"
    else
        if [ -z "${RESTORE_DB_DATA_DIRECTORY_VOLUME_TYPE}" ]; then
            error "The database volume type must be set as RESTORE_DB_DATA_DIRECTORY_VOLUME_TYPE in ${BACKUP_VARS_FILE}"
            bail "See stash.diy-backup.vars.sh.example for the defaults."
        elif [ "io1" == "${RESTORE_DB_DATA_DIRECTORY_VOLUME_TYPE}" ] && [ -z "${RESTORE_DB_DATA_DIRECTORY_IOPS}" ]; then
            error "The provisioned iops must be set as RESTORE_DB_DATA_DIRECTORY_IOPS in ${BACKUP_VARS_FILE} when choosing 'io1' volume type for the database data directory EBS volume"
            bail "See stash.diy-backup.vars.sh.example for the defaults."
        fi

        if [ -z "${AWS_AVAILABILITY_ZONE}" ]
        then
            error "The availability zone for new volumes must be set as AWS_AVAILABILITY_ZONE in ${BACKUP_VARS_FILE}"
            bail "See stash.diy-backup.vars.sh.example for the defaults."
        fi

        info "Restoring database data directory from snapshot ${RESTORE_DB_DATA_DIRECTORY_SNAPSHOT_ID} into a ${RESTORE_DB_DATA_DIRECTORY_VOLUME_TYPE} volume"

        restore_from_snapshot "${RESTORE_DB_DATA_DIRECTORY_SNAPSHOT_ID}" "${RESTORE_DB_DATA_DIRECTORY_VOLUME_TYPE}" "${RESTORE_DB_DATA_DIRECTORY_IOPS}"

        info "Performed restore of database data directory snapshot"
    fi
}

function freeze_db_directory {
    freeze_mount_point ${BACKUP_DB_DIRECTORY_MOUNT_POINT}
}

function unfreeze_db_directory {
    unfreeze_mount_point ${BACKUP_DB_DIRECTORY_MOUNT_POINT}
}