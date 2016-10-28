# -------------------------------------------------------------------------------------
# A backup and restore strategy for Amazon RDS database
# -------------------------------------------------------------------------------------

source "${SCRIPT_DIR}/aws-common.sh"

# Validate that the RDS_INSTANCE_ID variable has been set to a valid Amazon RDS instance
function prepare_backup_db {
    check_config_var "RDS_INSTANCE_ID"
    run aws rds describe-db-instances --db-instance-identifier "${RDS_INSTANCE_ID}" > /dev/null
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
    local optional_args=
    if [ -n "${RESTORE_RDS_INSTANCE_CLASS}" ]; then
        optional_args="--db-instance-class ${RESTORE_RDS_INSTANCE_CLASS}"
    fi

    if [ -n "${RESTORE_RDS_SUBNET_GROUP_NAME}" ]; then
        optional_args="${optional_args} --db-subnet-group-name ${RESTORE_RDS_SUBNET_GROUP_NAME}"
    fi

    if [ "${RESTORE_RDS_MULTI_AZ}" = "true" ]; then
        optional_args="${optional_args} --multi-az"
    fi

    local renamed_rds_instance="${RDS_INSTANCE_ID}-${TIMESTAMP}"
    rename_rds_instance "${RDS_INSTANCE_ID}" "${renamed_rds_instance}"

    info "Attempting to restore RDS snapshot '${RESTORE_RDS_SNAPSHOT_ID}' as RDS instance '${RDS_INSTANCE_ID}'"

    # Bail after 10 Minutes
    local max_wait_time=600
    local end_time=$(($SECONDS + max_wait_time))

    while [ $SECONDS -lt ${end_time} ]; do
        local restore_result=$(aws rds restore-db-instance-from-db-snapshot \
            --db-instance-identifier "${RDS_INSTANCE_ID}" \
            --db-snapshot-identifier "${RESTORE_RDS_SNAPSHOT_ID}" ${optional_args} 2>&1)

        case ${restore_result} in
        *"\"DBInstanceStatus\": \"creating\""*)
            info "Restored RDS snapshot '${RESTORE_RDS_SNAPSHOT_ID}' as RDS instance '${RDS_INSTANCE_ID}'"
            break
            ;;
        *DBInstanceAlreadyExists*)
            debug "Returned: ${restore_result}, retrying..."
            sleep 10
            ;;
        *)
            bail "Returned: ${restore_result}"
            break
            ;;
        esac
    done

    if [ $? != 0 ]; then
        bail "Failed to restore snapshot '${RESTORE_RDS_SNAPSHOT_ID}' as '${RDS_INSTANCE_ID}'"
    fi

    info "Waiting until the RDS instance is available. This could take some time"
    run aws rds wait db-instance-available --db-instance-identifier "${RDS_INSTANCE_ID}"  > /dev/null

    if [ -n "${RESTORE_RDS_SECURITY_GROUP}" ]; then
        # When restoring a DB instance outside of a VPC this command will need to be modified to use --db-security-groups instead of --vpc-security-group-ids
        # For more information see http://docs.aws.amazon.com/cli/latest/reference/rds/modify-db-instance.html
        run aws rds modify-db-instance --apply-immediately --db-instance-identifier "${RDS_INSTANCE_ID}" \
            --vpc-security-group-ids "${RESTORE_RDS_SECURITY_GROUP}" > /dev/null
    fi

    info "Performed restore of '${RESTORE_RDS_SNAPSHOT_ID}' to RDS instance '${RDS_INSTANCE_ID}'"
}

function rename_rds_instance {
    local source_rds_instance="$1"
    local dest_rds_instance="$2"

    info "Attempting to rename any existing RDS instance '${source_rds_instance}' to '${dest_rds_instance}'"

    # Rename existing rds instance
    if run aws rds modify-db-instance --db-instance-identifier "${source_rds_instance}" \
        --new-db-instance-identifier "${dest_rds_instance}" --apply-immediately > /dev/null; then
        debug "RDS Instance ${source_rds_instance} has been renamed to '${dest_rds_instance}"
        FINAL_MESSAGE+=$'RDS Instance '${source_rds_instance}$' has been renamed to '${dest_rds_instance}$'\n'
        FINAL_MESSAGE+=$'Note that if this DB has any read replica(s), you probably want to delete them and re-create as read replica(s) of '${source_rds_instance}$'\n'
    fi
}

function cleanup_db_backups {
    if [ "${KEEP_BACKUPS}" -gt 0 ]; then
        info "Cleaning up any old RDS snapshots and retaining only the most recent ${KEEP_BACKUPS}"
        for snapshot_id in $(list_old_rds_snapshot_ids "${AWS_REGION}"); do
            run aws rds delete-db-snapshot --db-snapshot-identifier "${snapshot_id}" > /dev/null
        done
    fi
}

# ----------------------------------------------------------------------------------------------------------------------
# Disaster recovery functions
# ----------------------------------------------------------------------------------------------------------------------

function promote_db {
    check_config_var "DR_RDS_READ_REPLICA"
    check_config_var "AWS_REGION"

    info "Promoting RDS read replica '${DR_RDS_READ_REPLICA}'"

    run aws --region="${AWS_REGION}" rds promote-read-replica --db-instance-identifier "${DR_RDS_READ_REPLICA}" > /dev/null
    run aws --region="${AWS_REGION}" rds wait db-instance-available --db-instance-identifier "${DR_RDS_READ_REPLICA}"

    success "Promoted RDS read replica '${DR_RDS_READ_REPLICA}'"
}

function setup_db_replication {
    info "RDS replication is automatically configured when the standby DB has been launched as an Amazon RDS read replica of the primary"
    no_op
}

