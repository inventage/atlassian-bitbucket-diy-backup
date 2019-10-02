#! /bin/bash
# -------------------------------------------------------------------------------------
# A backup and restore strategy for Amazon RDS databases
# -------------------------------------------------------------------------------------

source "${SCRIPT_DIR}/aws-common.sh"

if [ "$(is_aurora)" = "true" ]; then
    source "${SCRIPT_DIR}/aws-rds-aurora-helper.sh"
else
    source "${SCRIPT_DIR}/aws-rds-non-aurora-helper.sh"
fi

# Validate that the RDS_INSTANCE_ID variable has been set to a valid Amazon RDS instance
function prepare_backup_db {
    check_config_var "RDS_INSTANCE_ID"
    is_valid_rds "${RDS_INSTANCE_ID}"
}

# Backup the Bitbucket database
function backup_db {
    info "Performing backup of RDS instance '${RDS_INSTANCE_ID}'"
    snapshot_rds_instance "${RDS_INSTANCE_ID}"
}

function prepare_restore_db {
    check_config_var "RDS_INSTANCE_ID"
    RESTORE_RDS_SNAPSHOT_ID="$(retrieve_rds_snapshot_id "$1")"
}

function restore_db {
    restore_rds_snapshot
    info "Performed restore of '${RESTORE_RDS_SNAPSHOT_ID}' to RDS instance '${RDS_INSTANCE_ID}'"
}

function cleanup_incomplete_db_backup {
    # SNAPSHOT_TAG_VALUE is used as the unique identifier when creating the snapshot
    if [ -n "${SNAPSHOT_TAG_VALUE}" ]; then
        info "Cleaning up RDS snapshot '${SNAPSHOT_TAG_VALUE}' created as part of failed/incomplete backup"
        delete_rds_snapshot "${SNAPSHOT_TAG_VALUE}"
    else
        debug "No RDS snapshot to clean up"
    fi
}

function cleanup_old_db_backups {
    if [ "${KEEP_BACKUPS}" -gt 0 ]; then
        info "Cleaning up any old RDS snapshots and retaining only the most recent ${KEEP_BACKUPS}"
        for snapshot_id in $(list_old_rds_snapshots "${AWS_REGION}"); do
            delete_rds_snapshot "${snapshot_id}"
        done
    fi
}

# ----------------------------------------------------------------------------------------------------------------------
# Disaster recovery functions
# ----------------------------------------------------------------------------------------------------------------------

function promote_db {
    if [ "$(is_aurora)" = "false" ]; then
        check_config_var "DR_RDS_READ_REPLICA"
        check_config_var "AWS_REGION"

        info "Promoting RDS read replica '${DR_RDS_READ_REPLICA}'"

        run aws --region="${AWS_REGION}" rds promote-read-replica --db-instance-identifier "${DR_RDS_READ_REPLICA}" > /dev/null
        run aws --region="${AWS_REGION}" rds wait db-instance-available --db-instance-identifier "${DR_RDS_READ_REPLICA}"
        success "Promoted RDS read replica '${DR_RDS_READ_REPLICA}'"
    fi
}

function setup_db_replication {
    info "RDS replication is automatically configured when the standby DB has been launched as an Amazon RDS read replica of the primary"
    no_op
}
