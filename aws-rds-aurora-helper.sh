# -------------------------------------------------------------------------------------
# Helper functions for performing operations on Amazon Aurora RDS clusters.
# -------------------------------------------------------------------------------------

check_command "aws"

# Ensure the AWS region has been provided
if [ -z "${AWS_REGION}" ] || [ "${AWS_REGION}" = "null" ]; then
    error "The AWS region must be set as AWS_REGION in '${BACKUP_VARS_FILE}'"
    bail "See bitbucket.diy-aws-backup.vars.sh.example for the defaults."
fi

if [ -z "${AWS_ACCESS_KEY_ID}" ] || [ -z "${AWS_SECRET_ACCESS_KEY}" ]; then
    ! AWS_INSTANCE_ROLE=$(curl ${CURL_OPTIONS} http://169.254.169.254/latest/meta-data/iam/security-credentials/)
    if [ -z "${AWS_INSTANCE_ROLE}" ]; then
        error "Could not find the necessary credentials to run backup"
        error "We recommend launching the instance with an appropriate IAM role"
        error "Alternatively AWS credentials can be set as AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY in '${BACKUP_VARS_FILE}'"
        bail "See 'bitbucket.diy-aws-backup.vars.sh.example' for the defaults."
    else
        info "Using IAM instance role '${AWS_INSTANCE_ROLE}'"
    fi
else
    export AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
    export AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}
fi

if [ -z "${INSTANCE_NAME}" ]; then
    error "The ${PRODUCT} instance name must be set as INSTANCE_NAME in '${BACKUP_VARS_FILE}'"

    bail "See 'bitbucket.diy-aws-backup.vars.sh.example' for the defaults."
elif [ ! "${INSTANCE_NAME}" = "${INSTANCE_NAME%[[:space:]]*}" ]; then
    error "Instance name cannot contain spaces"

    bail "See 'bitbucket.diy-aws-backup.vars.sh.example' for the defaults."
elif [ ${#INSTANCE_NAME} -ge 100 ]; then
    error "Instance name must be under 100 characters in length"

    bail "See 'bitbucket.diy-aws-backup.vars.sh.example' for the defaults."
fi

# Exported so that calls to the AWS command line tool can use them
export AWS_DEFAULT_REGION=${AWS_REGION}
export AWS_DEFAULT_OUTPUT=json

SNAPSHOT_TAG_KEY="Name"

# Validate RDS instance ID
# instance_id = The RDS instance whose validity is to be checked
#
function is_valid_rds {
    local instance_id="$1"
    run aws rds describe-db-clusters --db-cluster-identifier "${instance_id}" > /dev/null
}

# Restore RDS snapshot
#
function restore_rds_snapshot {
    local optional_args=
    check_var "RESTORE_RDS_INSTANCE_CLASS" "RESTORE_RDS_INSTANCE_CLASS is a required argument while restoring an Aurora cluster"

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
    local end_time=$((SECONDS + max_wait_time))

    while [ $SECONDS -lt ${end_time} ]; do
        local db_snapshot_description=$(run aws rds describe-db-cluster-snapshots --db-cluster-snapshot-identifier "${RESTORE_RDS_SNAPSHOT_ID}")
        local engine=$(echo "${db_snapshot_description}" | jq -r '.DBClusterSnapshots[0]?.Engine')
        local engine_version=$(echo "${db_snapshot_description}" | jq -r '.DBClusterSnapshots[0]?.EngineVersion')
        local restore_result=$(run aws rds restore-db-cluster-from-snapshot \
                --db-cluster-identifier "${RDS_INSTANCE_ID}" \
                --snapshot-identifier "${RESTORE_RDS_SNAPSHOT_ID}" \
                --engine "${engine}" \
                --engine-version "${engine_version}" "${optional_args}" 2>&1)

        case ${restore_result} in
        *"\"Status\": \"creating\""*)
            info "Restored RDS snapshot '${RESTORE_RDS_SNAPSHOT_ID}' as RDS instance '${RDS_INSTANCE_ID}'"
            break
            ;;
        *DBClusterAlreadyExists*)
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
    wait_for_available_rds_instance "${RDS_INSTANCE_ID}" 30

    # While restoring an Aurora cluster from a snapshot, DBInstances are not restored automatically. Unfortunately, we lose all information
    # about how many members there were in the cluster to start with. So we just create one and call it master.
    info "Restoring master node in the Aurora cluster ${RDS_INSTANCE_ID}. Make sure to set up replicas after the process finishes"

    # Bail after 10 Minutes
    local max_wait_time=600
    local end_time=$((SECONDS + max_wait_time))
    local db_instance_name=${RDS_INSTANCE_ID}-master
    while [ $SECONDS -lt ${end_time} ]; do
        local create_result=$(run aws rds create-db-instance --db-instance-identifier "${db_instance_name}" --db-instance-class "${RESTORE_RDS_INSTANCE_CLASS}"\
        --engine "${engine}" --db-cluster-identifier "${RDS_INSTANCE_ID}")

        case ${create_result} in
        *"\"DBInstanceStatus\": \"creating\""*)
            info "Created master node in '${RDS_INSTANCE_ID}' successfully"
            break;
            ;;
        *DBInstanceAlreadyExists*)
            debug "Returned: ${restore_result}, retrying..."
            sleep 10
        ;;
        *)
            bail "Returned: ${create_result}"
            ;;
        esac
    done

    info "Waiting until the master node is available. This could take some time"
    run aws rds wait db-instance-available --db-instance-identifier "${db_instance_name}"

    if [ -n "${RESTORE_RDS_SECURITY_GROUP}" ]; then
        run aws rds modify-db-cluster --apply-immediately --db-cluster-identifier "${RDS_INSTANCE_ID}" \
            --vpc-security-group-ids "${RESTORE_RDS_SECURITY_GROUP}" > /dev/null
    fi

    info "Performed restore of '${RESTORE_RDS_SNAPSHOT_ID}' to RDS instance '${RDS_INSTANCE_ID}'"
}

# Rename RDS instance
# source_rds_instance = The original RDS instance
# dest_rds_instance = The new RDS instance
#
function rename_rds_instance {
    local source_rds_instance="$1"
    local dest_rds_instance="$2"

    info "Attempting to rename any existing RDS instance '${source_rds_instance}' to '${dest_rds_instance}'"

    # Rename existing rds instance
    if run aws rds modify-db-cluster --db-cluster-identifier "${source_rds_instance}" \
            --new-db-cluster-identifier "${dest_rds_instance}" --apply-immediately > /dev/null; then
        debug "RDS Instance ${source_rds_instance} has been renamed to '${dest_rds_instance}"
        FINAL_MESSAGE+=$'RDS Instance '${source_rds_instance}$' has been renamed to '${dest_rds_instance}$'\n'
        FINAL_MESSAGE+=$'Note that if this DB has any read replica(s), you probably want to delete them and re-create as read replica(s) of '${source_rds_instance}$'\n'
    fi
}

# Create a snapshot of a RDS instance
#
# instance_id = The RDS instance to snapshot
#
function snapshot_rds_instance {
    local instance_id="$1"
    local comma=
    if [ -n "${AWS_ADDITIONAL_TAGS}" ]; then
        comma=', '
    fi

    local aws_tags="[{\"Key\":\"${SNAPSHOT_TAG_KEY}\",\"Value\":\"${SNAPSHOT_TAG_VALUE}\"}${comma}${AWS_ADDITIONAL_TAGS}]"

    # Ensure RDS instance is available before attempting to snapshot
    wait_for_available_rds_instance "${instance_id}" 10

    # We use SNAPSHOT_TAG_VALUE as the snapshot identifier because it is unique and allows pairing of an EBS snapshot to an RDS snapshot by tag
    run aws rds create-db-cluster-snapshot --db-cluster-identifier "${instance_id}" \
        --db-cluster-snapshot-identifier "${SNAPSHOT_TAG_VALUE}" --tags "${aws_tags}" > /dev/null

    # Give a chance for the cluster to transition state
    sleep 15

    # Wait until the database has completed the backup
    info "Waiting for instance '${instance_id}' to complete backup. This could take some time"
    wait_for_available_rds_instance "${instance_id}" 10
}

# Delete an RDS snapshot
#
# snapshot_id = Id of the snapshot to be deleted
# region = Region in which snapshot is present. Defaults to ${AWS_REGION} if not passed
# aws_access_key_id = Key ID to use for this operation
# aws_secret_access_key = Key to use for this operation
# aws_session_token = Session token to use for this operation
#
function delete_rds_snapshot {
    local snapshot_id=$1
    local region=$2
    local aws_access_key_id=$3
    local aws_secret_access_key=$4
    local aws_session_token=$5

    if [ -z "${region}" ]; then
      region="${AWS_REGION}"
    fi
    if [ -z "${aws_access_key_id}" ]; then
      aws_access_key_id="${AWS_ACCESS_KEY_ID}"
    fi
    if [ -z "${aws_secret_access_key}" ]; then
      aws_secret_access_key="${AWS_SECRET_ACCESS_KEY}"
    fi
    if [ -z "${aws_session_token}" ]; then
      aws_session_token="${AWS_SESSION_TOKEN}"
    fi

    AWS_ACCESS_KEY_ID="${aws_access_key_id}" AWS_SECRET_ACCESS_KEY="${aws_secret_access_key}"\
    AWS_SESSION_TOKEN="${aws_session_token}" run aws rds --region "${region}" delete-db-cluster-snapshot\
                                             --db-cluster-snapshot-identifier "${snapshot_id}" > /dev/null
}

# Get id of RDS snapshot having a given tag
#
# tag_id = tag used to identify the snapshot
#
function get_rds_snapshot_id_from_tag {
    local tag_id=$1
    local snapshot_id=$(run aws rds describe-db-cluster-snapshots --db-cluster-snapshot-identifier "${tag_id}" \
                --query 'DBClusterSnapshots[*].DBClusterSnapshotIdentifier' | jq -r '.[]')
    print "${snapshot_id}"
}

# Wait for an RDS instance to become available.
#
# instance_id = The RDS instance to query
# duration = How long to wait for before bailing out. This value is in minutes
#
function wait_for_available_rds_instance {
    local instance_id=$1
    local duration=$2

    info "Will wait for $duration min"

    # Bail after duration
    local max_wait_time=$((duration * 60))
    local end_time=$((SECONDS + max_wait_time))

    while [ $SECONDS -lt ${end_time} ]; do
        local instance_description=$(run aws rds describe-db-clusters --db-cluster-identifier "${instance_id}")
        local db_instance_status=$(echo "${instance_description}" | jq -r '.DBClusters[0].Status')

        case "${db_instance_status}" in
            "" | "null")
                error "Could not find an RDS instance with a valid status field in response '${instance_description}'"
                bail "Please make sure you have selected an existing RDS instance"
                ;;
            "available")
                break
                ;;
            *)
                debug "The status of the RDS instance '${instance_id}' is '${db_instance_status}', expecting 'available'"
                ;;
        esac
        sleep 30
    done

    if [ "${db_instance_status}" != "available" ]; then
        bail "RDS instance '${instance_id}' did not become available after '${duration}' minute(s)"
    fi
}

# Permit account id to restore RDS snapshot
#
# account_id = AWS account id that should be allowed to restore
# snapshot_id = Snapshot that the account needs to restore
#
function permit_account_to_restore_rds_snapshot {
    local account_id=$1
    local snapshot_id=$2
    run aws rds modify-db-cluster-snapshot-attribute --db-cluster-snapshot-identifier "${snapshot_id}" --attribute-name restore \
        --values-to-add "${account_id}" > /dev/null
    info "Granted permissions on RDS snapshot '${snapshot_id}' for AWS account: '${account_id}'"
}

# Copy an RDS snapshot in ${AWS_REGION} under ${AWS_ACCOUNT_ID} to another region
# Gets AWS credentials from the environment if not passed in
#
# snapshot_id = Snapshot id to copy over
# target_region = Region to copy the snapshot over to
# aws_access_key_id = Key ID to use for this operation
# aws_secret_access_key = Key to use for this operation
# aws_session_token = Session token to use for this operation
#
function copy_rds_snapshot_to_region {
    local snapshot_id=$1
    local target_region=$2
    local aws_access_key_id=$3
    local aws_secret_access_key=$4
    local aws_session_token=$5

    local source_rds_snapshot_arn="arn:aws:rds:${AWS_REGION}:${AWS_ACCOUNT_ID}:snapshot:${snapshot_id}"

    if [ -z "${aws_access_key_id}" ]; then
      aws_access_key_id="${AWS_ACCESS_KEY_ID}"
    fi
    if [ -z "${aws_secret_access_key}" ]; then
      aws_secret_access_key="${AWS_SECRET_ACCESS_KEY}"
    fi
    if [ -z "${aws_session_token}" ]; then
      aws_session_token="${AWS_SESSION_TOKEN}"
    fi

    if AWS_ACCESS_KEY_ID="${aws_access_key_id}" AWS_SECRET_ACCESS_KEY="${aws_secret_access_key}"\
           AWS_SESSION_TOKEN="${aws_session_token}" run aws rds copy-db-cluster-snapshot --region "${target_region}" \
        --source-db-cluster-snapshot-identifier "${source_rds_snapshot_arn}" --target-db-cluster-snapshot-identifier "${snapshot_id}" > /dev/null; then
      info "Copied RDS Snapshot ${source_rds_snapshot_arn} as ${snapshot_id} to ${target_region}"
    else
      error "Failed to copy RDS Snapshot ${source_rds_snapshot_arn} to ${target_region}"
    fi
}

# Wait for an RDS snapshot to become available.
#
# snapshot_id = The RDS snapshot to query
# duration = How long to wait for before bailing out. This value is in minutes
#
function wait_for_rds_snapshot {
    local snapshot_id=$1
    local duration=$2

    info "Will wait for $duration min"

    # Bail after duration
    local max_wait_time=$((duration * 60))
    local end_time=$((SECONDS + max_wait_time))

    while [ $SECONDS -lt ${end_time} ]; do
        local snapshot_description=$(run aws rds describe-db-cluster-snapshots --db-cluster-snapshot-identifier "${snapshot_id}")
        local snapshot_status=$(echo "${snapshot_description}" | jq -r '.DBSnapshots[0].Status')

        case "${snapshot_status}" in
            "" | "null")
                error "Could not find an RDS snapshot with a valid status field in response '${snapshot_description}'"
                bail "Please make sure you have selected an existing snapshot id"
                ;;
            "available")
                break
                ;;
            *)
                debug "The status of the RDS snapshot '${snapshot_id}' is '${snapshot_status}', expecting 'available'"
                ;;
        esac
        sleep 30
    done

    if [ "${snapshot_status}" != "available" ]; then
      bail "RDS snapshot '${snapshot_id}' did not become available after '${duration}' minute(s)"
    fi
}

# Verify the existence of a RDS snapshot
#
# snapshot_tag = The tag used to retrieve the RDS snapshot ID
#
function retrieve_rds_snapshot_id {
    local snapshot_tag="$1"
    local db_snapshot_description=$(run aws rds describe-db-cluster-snapshots \
        --db-cluster-snapshot-identifier "${snapshot_tag}")
    local rds_snapshot_id=$(echo "${db_snapshot_description}" | jq -r '.DBClusterSnapshots[0]?.DBClusterSnapshotIdentifier')

    if [ -z "${rds_snapshot_id}" ] || [ "${rds_snapshot_id}" = "null" ]; then
        error "Could not find an RDS snapshot with a valid identifier in response '${db_snapshot_description}'"
        # To assist the with locating snapshot tags list the available RDS snapshot tags, and then bail
        list_available_rds_snapshots
        bail "Please select a restore point"
    fi

    echo "${rds_snapshot_id}"
}

# List available RDS restore points
#
function list_available_rds_snapshots {
    local available_rds_snapshots=$(run aws rds describe-db-cluster-snapshots \
        | jq -r '.DBClusterSnapshots[] | select(.DBClusterSnapshotIdentifier | startswith(("'"${SNAPSHOT_TAG_PREFIX}"'") ) | .DBClusterSnapshotIdentifier' | sort -r)

    if [ -z "${available_rds_snapshots}" ] || [ "${available_rds_snapshots}" = "null" ]; then
        error "Failed to retrieve RDS snapshots in response '${available_rds_snapshots}'"
        bail "Unable to retrieve list of available RDS restore points"
    fi

    print "Available RDS snapshots:"
    print "${available_rds_snapshots}"
}

# List all RDS DB snapshots older than the most recent ${KEEP_BACKUPS}
#
# region = The AWS region to search
# aws_access_key_id = Key ID to use for this operation
# aws_secret_access_key = Key to use for this operation
# aws_session_token = Session token to use for this operation
#
function list_old_rds_snapshots {
    local region=$1
    local aws_access_key_id=$2
    local aws_secret_access_key=$3
    local aws_session_token=$4

    if [ -z "${aws_access_key_id}" ]; then
      aws_access_key_id="${AWS_ACCESS_KEY_ID}"
    fi
    if [ -z "${aws_secret_access_key}" ]; then
      aws_secret_access_key="${AWS_SECRET_ACCESS_KEY}"
    fi
    if [ -z "${aws_session_token}" ]; then
      aws_session_token="${AWS_SESSION_TOKEN}"
    fi

    local old_rds_snapshot_ids=$(AWS_ACCESS_KEY_ID="${aws_access_key_id}" AWS_SECRET_ACCESS_KEY="${aws_secret_access_key}"\
           AWS_SESSION_TOKEN="${aws_session_token}" run aws rds describe-db-cluster-snapshots --region "${region}" --snapshot-type manual \
        --query "reverse(sort_by(DBClusterSnapshots[?starts_with(DBClusterSnapshotIdentifier, \`${SNAPSHOT_TAG_PREFIX}\`)]|\
        [?Status==\`available\`], &SnapshotCreateTime))[${KEEP_BACKUPS}:].DBClusterSnapshotIdentifier" | jq -r '.[]')
    print "${old_rds_snapshot_ids}"
}