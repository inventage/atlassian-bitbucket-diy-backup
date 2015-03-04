#!/bin/bash

function stash_prepare_home {
    info "Preparing backup of home directory"

    snapshot_home "Prepare backup: ${PRODUCT} home directory snapshot"
}

function stash_backup_home {
    info "Performing backup of home directory"

    snapshot_home "Perform backup: ${PRODUCT} home directory snapshot"
}

function snapshot_home {
    if [ -z "${BACKUP_HOME_DIRECTORY_VOLUME_ID}" ]; then
        error "The home directory volume must be set in stash.diy-backup.vars.sh"
        bail "See stash.diy-backup.vars.sh.example for the defaults."
    fi

    snapshot_ebs_volume "${BACKUP_HOME_DIRECTORY_VOLUME_ID}" "$1"
}

function stash_restore_home {
    if [ -z "${RESTORE_HOME_DIRECTORY_SNAPSHOT_ID}" ]; then
        error "The id for the snapshot to use when restoring the home directory must be set in stash.diy-backup.vars.sh"
        bail "See stash.diy-backup.vars.sh.example for the defaults."
    fi

    if [ -z "${RESTORE_HOME_DIRECTORY_VOLUME_TYPE}" ]; then
        error "The type of volume to create when restoring the home directory must be set in stash.diy-backup.vars.sh"
        bail "See stash.diy-backup.vars.sh.example for the defaults."
    elif [ "io1" == "${RESTORE_HOME_DIRECTORY_VOLUME_TYPE}" ] && [ -z "${RESTORE_HOME_DIRECTORY_IOPS}" ]; then
        error "The provisioned iops must be set in stash.diy-backup.vars.sh when choosing 'io1' volume type for the home directory EBS volume"
        bail "See stash.diy-backup.vars.sh.example for the defaults."
    fi

    if [ -z "${AWS_AVAILABILITY_ZONE}" ]
    then
        error "The availability zone for new volumes must be set in stash.diy-backup.vars.sh"
        bail "See stash.diy-backup.vars.sh.example for the defaults."
    fi

    info "Restoring home directory from snapshot ${RESTORE_HOME_DIRECTORY_SNAPSHOT_ID} into a ${RESTORE_HOME_DIRECTORY_VOLUME_TYPE} volume"

    restore_from_snapshot "${RESTORE_HOME_DIRECTORY_SNAPSHOT_ID}" "${RESTORE_HOME_DIRECTORY_VOLUME_TYPE}" "${RESTORE_HOME_DIRECTORY_IOPS}"

    info "Performed restore of home directory snapshot"
}
