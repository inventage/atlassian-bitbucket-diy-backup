# -------------------------------------------------------------------------------------
# A backup and restore strategy for Amazon RDS database
# -------------------------------------------------------------------------------------

SCRIPT_DIR=$(dirname "$0")
source "${SCRIPT_DIR}/aws-common.sh"

# Validate that the BACKUP_RDS_INSTANCE_ID variable has been set to a valid Amazon RDS instance
function prepare_backup_db {
    check_config_var "BACKUP_RDS_INSTANCE_ID"
    validate_rds_instance_id "${BACKUP_RDS_INSTANCE_ID}"
}

# Backup the Bitbucket database
function backup_db {
    info "Performing backup of RDS instance '${BACKUP_RDS_INSTANCE_ID}'"
    snapshot_rds_instance "${BACKUP_RDS_INSTANCE_ID}"
}

function prepare_restore_db {
    check_config_var "RESTORE_RDS_INSTANCE_ID"
    check_config_var "RESTORE_RDS_INSTANCE_CLASS"
    check_config_var "RESTORE_RDS_SUBNET_GROUP_NAME"
    check_config_var "RESTORE_RDS_SECURITY_GROUP"
}

function restore_db {
    restore_rds_instance "${RESTORE_RDS_INSTANCE_ID}" "${RESTORE_RDS_SNAPSHOT_ID}"

    info "Performed restore of '${RESTORE_RDS_SNAPSHOT_ID}' to RDS instance '${RESTORE_RDS_INSTANCE_ID}'"
}

# ----------------------------------------------------------------------------------------------------------------------
# Disaster recovery functions
# ----------------------------------------------------------------------------------------------------------------------

function promote_db {
    info "Promoting RDS read replica '${DR_RDS_READ_REPLICA}'"

    run aws --region ${AWS_REGION} rds promote-read-replica --db-instance-identifier "${DR_RDS_READ_REPLICA}" > /dev/null
    run aws --region ${AWS_REGION} rds wait db-instance-available --db-instance-identifier "${DR_RDS_READ_REPLICA}"

    success "Promoted RDS read replica '${DR_RDS_READ_REPLICA}'"
}

function setup_db_replication {
    # Automatically configured when the standby DB has been launched as an Amazon RDS read replica of a primary
    no_op
}

