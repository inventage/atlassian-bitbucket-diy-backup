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
    local renamed_rds_instance="${BACKUP_RDS_INSTANCE_ID}-${date_postfix}"
    $(rename_rds_instance "${BACKUP_RDS_INSTANCE_ID}" "${renamed_rds_instance}")

    # Restore RDS instance from backup snapshot
    run aws rds restore-db-instance-from-db-snapshot --db-instance-identifier "${BACKUP_RDS_INSTANCE_ID}" \
        --db-snapshot-identifier "${RESTORE_RDS_SNAPSHOT_ID}" ${optional_args} > /dev/null

    info "Waiting until the RDS instance is available. This could take some time"
    run aws rds wait db-instance-available --db-instance-identifier "${BACKUP_RDS_INSTANCE_ID}"  > /dev/null

    if [ -n "${RESTORE_RDS_SECURITY_GROUP}" ]; then
        # When restoring a DB instance outside of a VPC this command will need to be modified to use --db-security-groups instead of --vpc-security-group-ids
        # For more information see http://docs.aws.amazon.com/cli/latest/reference/rds/modify-db-instance.html
        run aws rds modify-db-instance --apply-immediately --db-instance-identifier "${BACKUP_RDS_INSTANCE_ID}" \
            --vpc-security-group-ids "${RESTORE_RDS_SECURITY_GROUP}" > /dev/null
    fi

    info "Performed restore of '${RESTORE_RDS_SNAPSHOT_ID}' to RDS instance '${BACKUP_RDS_INSTANCE_ID}'"
}

function rename_rds_instance {
    local source_rds_instance="$1"
    local dest_rds_instance="$2"

    # Rename existing rds instance
    run aws rds modify-db-instance --db-instance-identifier "${source_rds_instance}" \
        --new-db-instance-identifier "${dest_rds_instance}" --apply-immediately > /dev/null

    info "Waiting for RDS instance '${dest_rds_instance}' to become available. This could take some time"

    # 10 Minutes
    local max_wait_time=600
    local end_time=$((SECONDS+max_wait_time))

    set +e
    while [ $SECONDS -lt ${end_time} ]; do
        rds_instance_status=$(aws rds describe-db-instances --db-instance-identifier "${dest_rds_instance}" \
            | jq -r '.DBInstances[0]|.DBInstanceStatus')

        case "${rds_instance_status}" in
            "")
                # Empty string indicates the AWS command failed which indicates that the RDS instance hasn't been found
                sleep 30
                ;;
            "rebooting")
                sleep 10
                ;;
            "available")
                break
                ;;
            *)
                echo "Error while waiting for RDS instance '${current_rds_id}' to become available"
                exit 99
                ;;
        esac
    done
    set -e
}
