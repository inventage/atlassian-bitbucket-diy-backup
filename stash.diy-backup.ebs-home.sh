#!/bin/bash


function stash_prepare_home {
    # Validate that all the configuration parameters have been provided to avoid bailing out and leaving Stash locked
    if [ -z "${BACKUP_HOME_DIRECTORY_VOLUME_ID}" ]; then
        error "The home directory volume must be set as BACKUP_DB_DATA_DIRECTORY_VOLUME_ID in ${BACKUP_VARS_FILE}"
        bail "See stash.diy-backup.vars.sh.example for the defaults."
    fi

    if [ -z "${BACKUP_HOME_DIRECTORY_MOUNT_POINT}" ]; then
        error "The home directory mount point must be set as BACKUP_HOME_DIRECTORY_MOUNT_POINT in ${BACKUP_VARS_FILE}"
        bail "See stash.diy-backup.vars.sh.example for the defaults."
    fi
}

function stash_backup_home {
    # Freeze the home directory filesystem to ensure consistency
    freeze_home_directory
    # Add a clean up routine to ensure we unfreeze the home directory filesystem
    add_cleanup_routine unfreeze_home_directory

    info "Performing backup of home directory"

    snapshot_ebs_volume "${BACKUP_HOME_DIRECTORY_VOLUME_ID}" "Perform backup: ${PRODUCT} home directory snapshot"

    unfreeze_home_directory
}

function stash_restore_home {
    if [ -z "${RESTORE_HOME_DIRECTORY_SNAPSHOT_ID}" ]; then
        error "The id for the snapshot to use when restoring the home directory must be set as RESTORE_HOME_DIRECTORY_SNAPSHOT_ID in ${BACKUP_VARS_FILE}"
        bail "See stash.diy-backup.vars.sh.example for the defaults."
    fi

    if [ -z "${RESTORE_HOME_DIRECTORY_VOLUME_TYPE}" ]; then
        error "The type of volume to create when restoring the home directory must be set as RESTORE_HOME_DIRECTORY_VOLUME_TYPE in ${BACKUP_VARS_FILE}"
        bail "See stash.diy-backup.vars.sh.example for the defaults."
    elif [ "io1" == "${RESTORE_HOME_DIRECTORY_VOLUME_TYPE}" ] && [ -z "${RESTORE_HOME_DIRECTORY_IOPS}" ]; then
        error "The provisioned iops must be set as RESTORE_HOME_DIRECTORY_IOPS in ${BACKUP_VARS_FILE} when choosing 'io1' volume type for the home directory EBS volume"
        bail "See stash.diy-backup.vars.sh.example for the defaults."
    fi

    if [ -z "${AWS_AVAILABILITY_ZONE}" ]; then
        error "The availability zone for new volumes must be set as AWS_AVAILABILITY_ZONE in ${BACKUP_VARS_FILE}"
        bail "See stash.diy-backup.vars.sh.example for the defaults."
    fi

    info "Restoring home directory from snapshot ${RESTORE_HOME_DIRECTORY_SNAPSHOT_ID} into a ${RESTORE_HOME_DIRECTORY_VOLUME_TYPE} volume"

    restore_from_snapshot "${RESTORE_HOME_DIRECTORY_SNAPSHOT_ID}" "${RESTORE_HOME_DIRECTORY_VOLUME_TYPE}" "${RESTORE_HOME_DIRECTORY_IOPS}"

    info "Performed restore of home directory snapshot"
}

function freeze_home_directory {
    freeze_mount_point ${BACKUP_HOME_DIRECTORY_MOUNT_POINT}
}

function unfreeze_home_directory {
    unfreeze_mount_point ${BACKUP_HOME_DIRECTORY_MOUNT_POINT}
}