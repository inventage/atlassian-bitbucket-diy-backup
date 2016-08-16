# -------------------------------------------------------------------------------------
# A backup and restore strategy for Amazon RDS database
# -------------------------------------------------------------------------------------

SCRIPT_DIR=$(dirname "$0")
source "${SCRIPT_DIR}/aws-common.sh"

# Validate that the BACKUP_RDS_INSTANCE_ID variable has been set to a valid Amazon RDS instance
function prepare_backup_db {
    if [ -z "${BACKUP_RDS_INSTANCE_ID}" ]; then
        error "The RDS instance id must be set in '${BACKUP_VARS_FILE}'"
        bail "See 'bitbucket.diy-aws-backup.vars.sh.example' for the defaults."
    fi

    validate_rds_instance_id "${BACKUP_RDS_INSTANCE_ID}"
}

# Backup the Bitbucket database
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


function promote_standby_db {
    info "Promoting RDS read replica '${DR_RDS_READ_REPLICA}'"

    run aws --region ${AWS_REGION} rds promote-read-replica --db-instance-identifier "${DR_RDS_READ_REPLICA}" > /dev/null
    run aws rds wait db-instance-available --db-instance-identifier "${DR_RDS_READ_REPLICA}"

    success "Promoted RDS read replica '${DR_RDS_READ_REPLICA}'"
}
