# -------------------------------------------------------------------------------------
# A backup and restore strategy for Amazon RDS database
# -------------------------------------------------------------------------------------

SCRIPT_DIR=$(dirname "$0")
source "${SCRIPT_DIR}/aws-common.sh"

# Validate that the RDS_INSTANCE_ID variable has been set to a valid Amazon RDS instance
function prepare_backup_db {
    if [ -z "${RDS_INSTANCE_ID}" ]; then
        error "The RDS instance id must be set in '${BACKUP_VARS_FILE}'"
        bail "See 'bitbucket.diy-aws-backup.vars.sh.example' for the defaults."
    fi

    validate_rds_instance_id "${RDS_INSTANCE_ID}"
}

# Backup the Bitbucket database
function backup_db {
    info "Performing backup of RDS instance '${RDS_INSTANCE_ID}'"
    snapshot_rds_instance "${RDS_INSTANCE_ID}"
}

function prepare_restore_db {
    local snapshot_tag="$1"

    if [ -z "${RESTORE_RDS_INSTANCE_CLASS}" ]; then
        info "No restore instance class has been set in '${BACKUP_VARS_FILE}'"
    fi

    if [ -z "${RESTORE_RDS_SUBNET_GROUP_NAME}" ]; then
        info "No restore subnet group has been set in '${BACKUP_VARS_FILE}'"
    fi

    if [ -z "${RESTORE_RDS_SECURITY_GROUP}" ]; then
        info "No restore security group has been set in '${BACKUP_VARS_FILE}'"
    fi

    RESTORE_RDS_SNAPSHOT_ID="$(retrieve_rds_snapshot_id "${snapshot_tag}")"
}

function restore_db {
    local optional_args=
    if [ -n "${RESTORE_RDS_INSTANCE_CLASS}" ]; then
        optional_args="--db-instance-class ${RESTORE_RDS_INSTANCE_CLASS}"
    fi

    if [ -n "${RESTORE_RDS_SUBNET_GROUP_NAME}" ]; then
        optional_args="${optional_args} --db-subnet-group-name ${RESTORE_RDS_SUBNET_GROUP_NAME}"
    fi

    local date_postfix=$(date +"%Y%m%d-%H%M%S")
    local renamed_rds_instance="${RDS_INSTANCE_ID}-${date_postfix}"
    $(rename_rds_instance "${RDS_INSTANCE_ID}" "${renamed_rds_instance}")

    FINAL_MESSAGE+=$'RDS Instance '${RDS_INSTANCE_ID}$' has been renamed to '${renamed_rds_instance}$'\n'

    info "Attempting to restore RDS snapshot '${RESTORE_RDS_SNAPSHOT_ID}' as RDS instance '${RDS_INSTANCE_ID}'"

    # Bail after 10 Minutes
    local max_wait_time=600
    local end_time=$((SECONDS+max_wait_time))

    set +e
    while [ $SECONDS -lt ${end_time} ]; do
        restore_result=$(aws rds restore-db-instance-from-db-snapshot \
            --db-instance-identifier "${RDS_INSTANCE_ID}" \
            --db-snapshot-identifier "${RESTORE_RDS_SNAPSHOT_ID}" ${optional_args})

        case $? in
            0)
                # Restore successful
                info "Restored RDS snapshot '${RESTORE_RDS_SNAPSHOT_ID}' as RDS instance '${RDS_INSTANCE_ID}'"
                break
                ;;
            *)
                # Non-zero indicates the AWS command failed
                sleep 30
                ;;
        esac
    done
    set -e

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

    info "Renaming RDS instance '${source_rds_instance}' to '${dest_rds_instance}'"

    # Rename existing rds instance
    run aws rds modify-db-instance --db-instance-identifier "${source_rds_instance}" \
        --new-db-instance-identifier "${dest_rds_instance}" --apply-immediately > /dev/null
}


function promote_standby_db {
    info "Promoting RDS read replica '${DR_RDS_READ_REPLICA}'"

    run aws --region=${AWS_REGION} rds promote-read-replica --db-instance-identifier "${DR_RDS_READ_REPLICA}" > /dev/null
    run aws --region=${AWS_REGION} rds wait db-instance-available --db-instance-identifier "${DR_RDS_READ_REPLICA}"

    success "Promoted RDS read replica '${DR_RDS_READ_REPLICA}'"
}
