#!/bin/bash

# Functions implementing backup and restore for Amazon RDS
#
# Exports the following functions
#     bitbucket_prepare_backup_db     - for making a backup of the DB if differential backups a possible. Can be empty
#     bitbucket_backup_db             - for making a backup of the bitbucket DB
#     bitbucket_prepare_db_restore
#     bitbucket_restore

SCRIPT_DIR=$(dirname $0)
source ${SCRIPT_DIR}/bitbucket.diy-backup.ec2-common.sh

function bitbucket_prepare_backup_db {
    # Validate that all the configuration parameters have been provided to avoid bailing out and leaving Bitbucket locked
    if [ -z "${BACKUP_RDS_INSTANCE_ID}" ]; then
        error "The RDS instance id must be set in ${BACKUP_VARS_FILE}"
        bail "See bitbucket.diy-aws-backup.vars.sh.example for the defaults."
    fi

    validate_rds_instance_id "${BACKUP_RDS_INSTANCE_ID}"
}

function bitbucket_backup_db {
    info "Performing backup of RDS instance ${BACKUP_RDS_INSTANCE_ID}"
    snapshot_rds_instance "${BACKUP_RDS_INSTANCE_ID}"
}

function bitbucket_prepare_restore_db {
    local SNAPSHOT_TAG="${1}"

    if [ -z ${SNAPSHOT_TAG} ]; then
        info "Usage: $0 <snapshot-tag>"

        # TODO: Rework into snapshot tags?
        list_available_ebs_snapshot_tags

        exit 99
    fi

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

function bitbucket_cleanup_db {
    if [ ! "${KEEP_BACKUPS}" -gt 0 ]; then
        info "Skipping cleanup of RDS snapshots"
        return
    fi

    # Delete old snapshots in source AWS account
    for snapshot_id in $(list_old_rds_snapshot_ids ${AWS_REGION}); do
        info "Deleting old RDS snapshot ${snapshot_id}"
        aws rds delete-db-snapshot --db-snapshot-identifier "${snapshot_id}" > /dev/null
    done
}