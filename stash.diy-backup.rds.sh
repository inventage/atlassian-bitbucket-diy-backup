#!/bin/bash

check_command "aws"

function stash_prepare_db {
    info "Preparing backup of RDS instance ${BACKUP_RDS_INSTANCE_ID}"
}

function stash_backup_db {
    info "Performing backup of RDS instance ${BACKUP_RDS_INSTANCE_ID}"

    snapshot_db "${BACKUP_RDS_INSTANCE_ID}-${BACKUP_TIMESTAMP}"
}

function snapshot_db {
    if [ -z "${BACKUP_RDS_INSTANCE_ID}" ]; then
        error "The RDS instance id must be set in ${BACKUP_VARS_FILE}"
        bail "See stash.diy-backup.vars.sh.example for the defaults."
    fi

    snapshot_rds_instance "${BACKUP_RDS_INSTANCE_ID}" "${1}"
}

function stash_restore_db {
    if [ -z "${RESTORE_RDS_INSTANCE_ID}" ]; then
        error "The RDS instance id must be set in ${BACKUP_VARS_FILE}"
        bail "See stash.diy-backup.vars.sh.example for the defaults."
    fi

    if [ -z "${RESTORE_RDS_SNAPSHOT_ID}" ]; then
        error "The RDS snapshot id must be set in ${BACKUP_VARS_FILE}"
        bail "See stash.diy-backup.vars.sh.example for the defaults."
    fi

    if [ -z "${RESTORE_RDS_INSTANCE_CLASS}" ]; then
        info "No instance class was provided. The RDS snapshot will be restored into a default instance size"
    fi

    if [ -z "${RESTORE_RDS_SUBNET_GROUP_NAME}" ]; then
        info "No subnet group was provided. The RDS snapshot will be restored into default subnet group"
    fi

    if [ -z "${RESTORE_RDS_SECURITY_GROUP}" ]; then
        info "No security group was provided. The RDS snapshot will be restored into an instance with the default security group"
    fi

    restore_rds_instance "${RESTORE_RDS_INSTANCE_ID}" "${RESTORE_RDS_SNAPSHOT_ID}"

    info "Performed restore of ${RESTORE_RDS_SNAPSHOT_ID} to RDS instance ${RESTORE_RDS_INSTANCE_ID}"
}
