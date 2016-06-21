#!/bin/bash

function bitbucket_prepare_db {
    # Validate that all the configuration parameters have been provided to avoid bailing out and leaving Bitbucket locked
    if [ -z "${BACKUP_RDS_INSTANCE_ID}" ]; then
        error "The RDS instance id must be set in ${BACKUP_VARS_FILE}"
        bail "See bitbucket.diy-aws-backup.vars.sh.example for the defaults."
    fi

    validate_rds_instance_id "${BACKUP_RDS_INSTANCE_ID}"
}

function bitbucket_backup_db {
    info "Performing backup of RDS instance ${BACKUP_RDS_INSTANCE_ID}"

    local SOURCE_RDS_SNAPSHOT_NAME=$(snapshot_rds_instance "${BACKUP_RDS_INSTANCE_ID}")

    if [ -n "${BACKUP_RDS_DEST_REGION}" ]; then
        local SOURCE_RDS_SNAPSHOT_ID=arn:aws:rds:${AWS_REGION}:${BACKUP_AWS_ACCOUNT_ID}:snapshot:${SOURCE_RDS_SNAPSHOT_NAME}
        copy_rds_snapshot_to_another_region ${SOURCE_RDS_SNAPSHOT_ID} ${BACKUP_RDS_DEST_REGION} ${SOURCE_RDS_SNAPSHOT_NAME}-copy
    fi
}

function bitbucket_prepare_db_restore {
    local SNAPSHOT_TAG="${1}"

    if [ -z "${RESTORE_RDS_INSTANCE_ID}" ]; then
        error "The RDS instance id must be set in ${BACKUP_VARS_FILE}"
        bail "See bitbucket.diy-aws-backup.vars.sh.example for the defaults."
    fi

    if [ -z "${RESTORE_RDS_INSTANCE_CLASS}" ]; then
        info "No restore instance class has been set in ${BACKUP_VARS_FILE}"
    fi

    if [ -z "${RESTORE_RDS_SUBNET_GROUP_NAME}" ]; then
        info "No restore subnet group has been set in ${BACKUP_VARS_FILE}"
    fi

    if [ -z "${RESTORE_RDS_SECURITY_GROUP}" ]; then
        info "No restore security group has been set in ${BACKUP_VARS_FILE}"
    fi

    validate_rds_snapshot "${SNAPSHOT_TAG}"

    RESTORE_RDS_SNAPSHOT_ID="${SNAPSHOT_TAG}"
}

function bitbucket_restore_db {
    restore_rds_instance "${RESTORE_RDS_INSTANCE_ID}" "${RESTORE_RDS_SNAPSHOT_ID}"

    info "Performed restore of ${RESTORE_RDS_SNAPSHOT_ID} to RDS instance ${RESTORE_RDS_INSTANCE_ID}"
}

function cleanup_old_db_snapshots {
    for snapshot_id in $(list_old_rds_snapshot_ids); do
        info "Deleting old snapshot ${snapshot_id}"
        delete_rds_snapshot "${snapshot_id}"
    done
}
