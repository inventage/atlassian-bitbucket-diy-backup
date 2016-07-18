#!/bin/bash

# Functions implementing backup and restore for Amazon RDS
#
# Exports the following functions
#     prepare_backup_db     - for making a backup of the DB if differential backups a possible. Can be empty
#     backup_db             - for making a backup of the bitbucket DB
#     prepare_restore_db
#     restore_db

SCRIPT_DIR=$(dirname $0)
source ${SCRIPT_DIR}/aws-common.sh
source ${SCRIPT_DIR}/utils.sh

function prepare_backup_db {
    # Validate that all the configuration parameters have been provided to avoid bailing out and leaving Bitbucket locked
    if [ -z "${BACKUP_RDS_INSTANCE_ID}" ]; then
        error "The RDS instance id must be set in '${BACKUP_VARS_FILE}'"
        bail "See 'bitbucket.diy-aws-backup.vars.sh.example' for the defaults."
    fi

    validate_rds_instance_id "${BACKUP_RDS_INSTANCE_ID}"
}

function backup_db {
    info "Performing backup of RDS instance '${BACKUP_RDS_INSTANCE_ID}'"
    snapshot_rds_instance "${BACKUP_RDS_INSTANCE_ID}"
}

function prepare_restore_db {
    if [ -z "${RESTORE_RDS_INSTANCE_ID}" ]; then
        error "The RDS instance id must be set in '${BACKUP_VARS_FILE}'"
        bail "See bitbucket.diy-aws-backup.vars.sh.example for the defaults."
    fi

    if [ -z "${RESTORE_RDS_INSTANCE_CLASS}" ]; then
        info "No restore instance class has been set in '${BACKUP_VARS_FILE}'"
    fi

    if [ -z "${RESTORE_RDS_SUBNET_GROUP_NAME}" ]; then
        info "No restore subnet group has been set in '${BACKUP_VARS_FILE}'"
    fi

    if [ -z "${RESTORE_RDS_SECURITY_GROUP}" ]; then
        info "No restore security group has been set in '${BACKUP_VARS_FILE}'"
    fi
}

function restore_db {
    restore_rds_instance "${RESTORE_RDS_INSTANCE_ID}" "${RESTORE_RDS_SNAPSHOT_ID}"

    info "Performed restore of '${RESTORE_RDS_SNAPSHOT_ID}' to RDS instance '${RESTORE_RDS_INSTANCE_ID}'"
}
