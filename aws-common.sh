# -------------------------------------------------------------------------------------
# Utilities used for AWS backup and restore
# -------------------------------------------------------------------------------------

check_command "aws"

# Ensure the AWS region has been provided
if [ -z "${AWS_REGION}" -o "${AWS_REGION}" = "null" ]; then
    error "The AWS region must be set as AWS_REGION in '${BACKUP_VARS_FILE}'"
    bail "See bitbucket.diy-aws-backup.vars.sh.example for the defaults."
fi

if [ -z "${AWS_ACCESS_KEY_ID}" -o -z "${AWS_SECRET_ACCESS_KEY}" ]; then
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
elif [ ! "${INSTANCE_NAME}" = ${INSTANCE_NAME%[[:space:]]*} ]; then
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

# Create a snapshot of an EBS volume
#
# volume_id = The volume to snapshot
# description = The description of the snapshot
#
function snapshot_ebs_volume {
    local volume_id="$1"
    local description="$2"

    # Bail after 10 Minutes
    local max_wait_time=600
    local end_time=$(($SECONDS + max_wait_time))

    set +e
    while [ $SECONDS -lt ${end_time} ]; do
        local create_snapshot_response=$(run aws ec2 create-snapshot --volume-id "${volume_id}" --description "${description}")
        local ebs_snapshot_id=$(echo "${create_snapshot_response}" | jq -r '.SnapshotId')

        case "${ebs_snapshot_id}" in
            "" | "null")
                error "Could not find 'SnapshotId' in response '${create_snapshot_response}'"
                bail "Unable to create EBS snapshot of volume '${volume_id}'"
                ;;
            *"SnapshotCreationPerVolumeRateExceeded"*)
                debug "Snapshot creation per volume rate exceeded. AWS returned: ${create_snapshot_response}"
                ;;
            *)
                break
                ;;
        esac
        sleep 10
    done
    set -e

    if [ -n "${AWS_ADDITIONAL_TAGS}" ]; then
        comma=', '
    fi
    local aws_tags="[{\"Key\":\"${SNAPSHOT_TAG_KEY}\",\"Value\":\"${SNAPSHOT_TAG_VALUE}\"}${comma}${AWS_ADDITIONAL_TAGS}]"

    run aws ec2 create-tags --resources "${ebs_snapshot_id}" --tags "$aws_tags" > /dev/null
    debug "Tagged EBS snapshot '${ebs_snapshot_id}' with '${aws_tags}'"
}

# Create a EBS volume from a snapshot
#
# snapshot_id = The snapshot id to use
# volume_type = The type of volume to create (i.e. gp2, io1)
# provisioned_iops = The IOPS to be provisioned
#
function create_volume {
    local snapshot_id="$1"
    local volume_type="$2"
    local provisioned_iops="$3"

    local optional_args=
    if [ "io1" = "${volume_type}" -a -n "${provisioned_iops}" ]; then
        optional_args="--iops ${provisioned_iops}"
    fi

    local create_volume_response=$(run aws ec2 create-volume --snapshot "${snapshot_id}"\
        --availability-zone "${AWS_AVAILABILITY_ZONE}" --volume-type "${volume_type}" ${optional_args})

    local volume_id=$(echo "${create_volume_response}" | jq -r '.VolumeId')
    if [ -z "${volume_id}" -o "${volume_id}" = "null" ]; then
        error "Could not find 'VolumeId' in response '${create_volume_response}'"
        bail "Error getting volume id from volume creation response"
    fi

    run aws ec2 wait volume-available --volume-ids "${volume_id}" > /dev/null
    echo "${volume_id}"
}

# Attach an existing EBS volume to the requested device name
#
# volume_id = The volume id to attach
# device_name = The device name
#
function attach_volume {
    local volume_id="$1"
    local device_name="$2"

    run aws ec2 attach-volume --volume-id "${volume_id}" \
        --instance "${AWS_EC2_INSTANCE_ID}" --device "${device_name}" > /dev/null
    wait_attached_volume "${volume_id}"
}

# Detach the currently attached EBS volume
function detach_volume {
    run aws ec2 detach-volume --volume-id "${BACKUP_HOME_DIRECTORY_VOLUME_ID}" > /dev/null
}

# Re-attach the previously attached EBS volume.
function reattach_old_volume {
    remove_cleanup_routine reattach_old_volume
    attach_volume "${BACKUP_HOME_DIRECTORY_VOLUME_ID}" "${HOME_DIRECTORY_DEVICE_NAME}"
}

# Wait for an EBS volume to attach
#
# volume_id = The volume id
#
function wait_attached_volume {
    local volume_id="$1"

    info "Waiting for volume '${volume_id}' to be attached. This could take some time"

    # 60 Minutes
    local max_wait_time=3600
    local end_time=$(($SECONDS + max_wait_time))

    local attachment_state='attaching'
    while [ $SECONDS -lt ${end_time} ]; do
        # aws ec2 wait volume-in-use ${VOLUME_ID} is not enough.
        # A volume state can be 'in-use' while its attachment state is still 'attaching'
        # If the volume is not fully attach we cannot issue a mount command for it
        local volume_description=$(run aws ec2 describe-volumes --volume-ids "${volume_id}")

        attachment_state=$(echo "${volume_description}" | jq -r '.Volumes[0].Attachments[0].State')
        if [ -z "${attachment_state}" -o "${attachment_state}" = "null" ]; then
            error "Could not find 'Volume' with 'Attachment' with 'State' in response '${volume_description}'"
            bail "Unable to get volume state for volume '${volume_id}'"
        fi
        case "${attachment_state}" in
            "attaching")
                sleep 10
                ;;
            "attached")
                break
                ;;
            *)
                bail "Error while waiting for volume '${volume_id}' to attach"
                ;;
        esac
    done

    if [ "attached" != "${attachment_state}" ]; then
        bail "Unable to attach volume '${volume_id}'. Attachment state is '${attachment_state}' after \
            '${max_wait_time}' seconds"
    fi
}

# Create a new EBS volume from a snapshot and attach it
#
# snapshot_id = The snapshot id to use
# volume_type = The type of volume to create (i.e. gp2, io1)
# provisioned_iops = The no of IOPS required
# device_name = The destination device name
# mount_point = The destination mount point
#
function create_and_attach_volume {
    local snapshot_id="$1"
    local volume_type="$2"
    local provisioned_iops="$3"
    local device_name="$4"
    local mount_point="$5"

    local volume_id="$(create_volume "${snapshot_id}" "${volume_type}" "${provisioned_iops}")"
    attach_volume "${volume_id}" "${device_name}"
}

# Validate the existence of a EBS snapshot
#
# snapshot_tag = The tag used to retrieve the EBS snapshot ID
#
function retrieve_ebs_snapshot_id {
    local snapshot_tag="$1"

    local snapshot_description=$(run aws ec2 describe-snapshots --filters Name=tag-key,Values="${SNAPSHOT_TAG_KEY}" \
        Name=tag-value,Values="${snapshot_tag}")

    local snapshot_id=$(echo "${snapshot_description}" | jq -r '.Snapshots[0]?.SnapshotId')
    if [ -z "${snapshot_id}" -o "${snapshot_id}" = "null" ]; then
        error "Could not find a 'Snapshot' with 'SnapshotId' in response '${snapshot_description}'"
        # Get the list of available snapshot tags to assist with selecting a valid one
        list_available_ebs_snapshots
        bail "Please select an available EBS restore point"
    fi
    echo "${snapshot_id}"
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
    wait_for_available_rds_instance "${instance_id}"

    # We use SNAPSHOT_TAG_VALUE as the snapshot identifier because it is unique and allows pairing of an EBS snapshot to an RDS snapshot by tag
    run aws rds create-db-snapshot --db-instance-identifier "${instance_id}" \
        --db-snapshot-identifier "${SNAPSHOT_TAG_VALUE}" --tags "${aws_tags}" > /dev/null

    # Wait until the database has completed the backup
    info "Waiting for instance '${instance_id}' to complete backup. This could take some time"
    wait_for_available_rds_instance "${instance_id}"
}

# Waits for a RDS instance to become available
#
# instance_id = The RDS instance to query
#
function wait_for_available_rds_instance {
    local instance_id=$1

    # Bail after 10 Minutes
    local max_wait_time=600
    local end_time=$(($SECONDS + max_wait_time))

    set +e
    while [ $SECONDS -lt ${end_time} ]; do
        local instance_description=$(run aws rds describe-db-instances --db-instance-identifier "${instance_id}")
        local db_instance_status=$(echo "${instance_description}" | jq -r '.DBInstances[0].DBInstanceStatus')

        case "${db_instance_status}" in
            "" | "null")
                error "Could not find a 'DBInstance' with 'DBInstanceStatus' in response '${instance_description}'"
                bail "Please make sure you have selected an existing RDS instance"
                ;;
            "available")
                break
                ;;
            *)
                debug "The RDS instance '${instance_id}' status is '${db_instance_status}', expected 'available'"
                ;;
        esac
        sleep 10
    done
    set -e

    if [ "${db_instance_status}" != "available" ]; then
        bail "RDS instance '${instance_id}' did not become available after '${max_wait_time}' seconds"
    fi
}

# Output the id of the currently attached EBS Volume
#
# device_name = The device name where the EBS volume is attached
#
function find_attached_ebs_volume {
    local device_name="${1}"
    local volume_description=$(run aws ec2 describe-volumes \
        --filter Name=attachment.instance-id,Values="${AWS_EC2_INSTANCE_ID}" Name=attachment.device,Values="${device_name}")

    local ebs_volume=$(echo "${volume_description}" | jq -r '.Volumes[0].VolumeId')
    if [ -z "${ebs_volume}" -o "${ebs_volume}" = "null" ]; then
        error "Could not find 'Volume' with 'VolumeId' in response '${volume_description}'"
        bail "Unable to retrieve volume information for device '${device_name}'"
    fi

    echo "${ebs_volume}"
}

# Verify the existence of a RDS snapshot
#
# snapshot_tag = The tag used to retrieve the RDS snapshot ID
#
function retrieve_rds_snapshot_id {
    local snapshot_tag="$1"
    local db_snapshot_description=$(run aws rds describe-db-snapshots \
     --db-snapshot-identifier "${snapshot_tag}")

    local rds_snapshot_id=$(echo "${db_snapshot_description}" | jq -r '.DBSnapshots[0]?.DBSnapshotIdentifier')
    if [ -z "${rds_snapshot_id}" -o "${rds_snapshot_id}" = "null" ]; then
        error "Could not find a 'DBSnapshot' with 'DBSnapshotIdentifier' in response '${db_snapshot_description}'"
        # To assist the with locating snapshot tags list the available EBS snapshot tags, and then bail
        list_available_rds_snapshots
        bail "Please select a restore point"
    fi

    echo "${rds_snapshot_id}"
}

# List available EBS restore points
function list_available_ebs_snapshots {
    local available_ebs_snapshots=$(run aws ec2 describe-snapshots \
        --filters Name=tag-key,Values="Name" Name=tag-value,Values="${SNAPSHOT_TAG_PREFIX}*"\
        | jq -r ".Snapshots[].Tags[] | select(.Key == \"Name\") | .Value" | sort -r)
    if [ -z "${available_ebs_snapshots}" -o "${available_ebs_snapshots}" = "null" ]; then
        error "Could not find 'Snapshots' with 'Tags' with 'Value' in response '${snapshot_description}'"
        bail "Unable to retrieve list of available EBS snapshots"
    fi

    print "Available EBS restore points:"
    print "${available_ebs_snapshots}"
}

# List available RDS restore points
function list_available_rds_snapshots {
    local available_rds_snapshots=$(run aws rds describe-db-snapshots | jq -r '.DBSnapshots[] | \
        select(.DBSnapshotIdentifier | startswith(("'${SNAPSHOT_TAG_PREFIX}'") ) | .DBSnapshotIdentifier' | sort -r)
    if [ -z "${available_rds_snapshots}" -o "${available_rds_snapshots}" = "null" ]; then
        error "Failed to retrieve RDS snapshots in response '${available_rds_snapshots}'"
        bail "Unable to retrieve list of available RDS restore points"
    fi

    print "Available RDS snapshots:"
    print "${available_rds_snapshots}"
}

# List all RDS DB snapshots older than the most recent ${KEEP_BACKUPS}
#
# region = The AWS region to search
#
function list_old_rds_snapshot_ids {
    local region=$1
    run aws --output=text rds describe-db-snapshots --region "${region}" --snapshot-type manual \
      --query "reverse(sort_by(DBSnapshots[?starts_with(DBSnapshotIdentifier, \`${SNAPSHOT_TAG_PREFIX}\`)]|[?Status==\`available\`], &SnapshotCreateTime))[${KEEP_BACKUPS}:].DBSnapshotIdentifier"
}

# List all EBS snapshots older than the most recent ${KEEP_BACKUPS}
function list_old_ebs_snapshot_ids {
    local region=$1
    run aws ec2 describe-snapshots --region="${region}" --filters "Name=tag:Name,Values=${SNAPSHOT_TAG_PREFIX}*" | \
        jq -r ".Snapshots | sort_by(.StartTime) | reverse | .[${KEEP_BACKUPS}:] | map(.SnapshotId)[]"
}
