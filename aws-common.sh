#!/bin/bash

check_command "aws"
check_command "jq"

# Ensure the AWS region has been provided
if [ -z "${AWS_REGION}" -o "${AWS_REGION}" = "null" ]; then
    error "The AWS region must be set as AWS_REGION in '${BACKUP_VARS_FILE}'"
    bail "See bitbucket.diy-aws-backup.vars.sh.example for the defaults."
fi

if [ -z "${AWS_ACCESS_KEY_ID}" -o -z "${AWS_SECRET_ACCESS_KEY}" ]; then
    AWS_INSTANCE_ROLE=$(curl ${CURL_OPTIONS} http://169.254.169.254/latest/meta-data/iam/security-credentials/)
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

export AWS_DEFAULT_REGION=${AWS_REGION}
export AWS_DEFAULT_OUTPUT=json

SNAPSHOT_TAG_KEY="Name"
# This is used to identify RDS + EBS snapshots.
# Note that this prefix is used to delete old backups and if set improperly will delete incorrect snapshots on cleanup.
SNAPSHOT_TAG_PREFIX="${INSTANCE_NAME}-"
SNAPSHOT_TIME=$(date +"%Y%m%d-%H%M%S-%3N")
SNAPSHOT_TAG_VALUE="${SNAPSHOT_TAG_PREFIX}${SNAPSHOT_TIME}"

function snapshot_ebs_volume {
    local volume_id="$1"
    local description="$2"
    local create_snapshot_response=$(run aws ec2 create-snapshot --volume-id "${volume_id}" --description "${description}")

    local ebs_snapshot_id=$(echo "${create_snapshot_response}" | jq -r '.SnapshotId')
    if [ -z "${ebs_snapshot_id}" -o "${ebs_snapshot_id}" = "null" ]; then
        error "Could not find 'SnapshotId' in response '${create_snapshot_response}'"
        bail "Unable to create EBS snapshot of volume '${volume_id}'"
    fi

    run aws ec2 create-tags --resources "${ebs_snapshot_id}" --tags Key="${SNAPSHOT_TAG_KEY}",Value="${SNAPSHOT_TAG_VALUE}" > /dev/null
    if [ -n "${AWS_ADDITIONAL_TAGS}" ]; then
        run aws ec2 create-tags --resources "${ebs_snapshot_id}" --tags "[ ${AWS_ADDITIONAL_TAGS} ]" > /dev/null
    fi
}

function create_volume {
    local snapshot_id="$1"
    local volume_type="$2"
    local provisioned_iops="$3"

    local optional_args=
    if [ "io1" = "${volume_type}" -a -n "${provisioned_iops}" ]; then
        optional_args="--iops ${provisioned_iops}"
    fi

    local create_volume_response=$(run aws ec2 create-volume --snapshot "${snapshot_id}" --availability-zone \
        "${AWS_AVAILABILITY_ZONE}" --volume-type "${volume_type}" ${optional_args})

    local volume_id=$(echo "${create_volume_response}" | jq -r '.VolumeId')
    if [ -z "${volume_id}" -o "${volume_id}" = "null" ]; then
        error "Could not find 'VolumeId' in response '${create_volume_response}'"
        bail "Error getting volume id from volume creation response"
    fi

    run aws ec2 wait volume-available --volume-ids "${volume_id}" > /dev/null
    echo "${volume_id}"
}

function attach_volume {
    local volume_id="$1"
    local device_name="$2"

    run aws ec2 attach-volume --volume-id "${volume_id}" --instance "${AWS_EC2_INSTANCE_ID}" --device "${device_name}" > /dev/null
    wait_attached_volume "${volume_id}"
}

function detach_volume {
    run aws ec2 detach-volume --volume-id "${BACKUP_HOME_DIRECTORY_VOLUME_ID}" > /dev/null
}

function reattach_old_volume {
    remove_cleanup_routine reattach_old_volume
    attach_volume "${BACKUP_HOME_DIRECTORY_VOLUME_ID}" "${HOME_DIRECTORY_DEVICE_NAME}"
}

function wait_attached_volume {
    local volume_id="$1"

    info "Waiting for volume '${volume_id}' to be attached. This could take some time"

    # 60 Minutes
    local max_wait_time=3600
    local end_time=$((SECONDS+max_wait_time))

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

function create_and_attach_volume {
    local snapshot_id="$1"
    local volume_type="$2"
    local provisioned_iops="$3"
    local device_name="$4"
    local mount_point="$5"

    local volume_id="$(create_volume "${snapshot_id}" "${volume_type}" "${provisioned_iops}")"
    attach_volume "${volume_id}" "${device_name}"
}

function validate_ebs_snapshot {
    local snapshot_tag="$1"
    local  __RETURN=$2

    local snapshot_description=$(run aws ec2 describe-snapshots --filters Name=tag-key,Values="Name" \
        Name=tag-value,Values="${snapshot_tag}")

    local snapshot_id=$(echo "${snapshot_description}" | jq -r '.Snapshots[0]?.SnapshotId')
    if [ -z "${snapshot_id}" -o "${snapshot_id}" = "null" ]; then
        error "Could not find a 'Snapshot' with 'SnapshotId' in response '${snapshot_description}'"
        # Get the list of available snapshot tags to assist with selecting a valid one
        list_available_ebs_snapshot_tags
        bail "Please select an available tag"
    else
        eval ${__RETURN}="${snapshot_id}"
    fi
}

function snapshot_rds_instance {
    local instance_id="$1"
    local comma=
    if [ -n "${AWS_ADDITIONAL_TAGS}" ]; then
        comma=', '
    fi

    local aws_tags="[{\"Key\":\"${SNAPSHOT_TAG_KEY}\",\"Value\":\"${SNAPSHOT_TAG_VALUE}\"}${comma}${AWS_ADDITIONAL_TAGS}]"

    # We use SNAPSHOT_TAG_VALUE as the snapshot identifier because it is unique and allows pairing of an EBS snapshot to an RDS snapshot by tag
    run aws rds create-db-snapshot --db-instance-identifier "${instance_id}" \
        --db-snapshot-identifier "${SNAPSHOT_TAG_VALUE}" --tags "${aws_tags}" > /dev/null

    # Wait until the database has completed the backup
    info "Waiting for instance '${instance_id}' to complete backup. This could take some time"
    run aws rds wait db-instance-available --db-instance-identifier "${instance_id}"
}

function restore_rds_instance {
    local instance_id="$1"
    local snapshot_id="$2"

    local optional_args=
    if [ -n "${RESTORE_RDS_INSTANCE_CLASS}" ]; then
        optional_args="--db-instance-class ${RESTORE_RDS_INSTANCE_CLASS}"
    fi

    if [ -n "${RESTORE_RDS_SUBNET_GROUP_NAME}" ]; then
        optional_args="${optional_args} --db-subnet-group-name ${RESTORE_RDS_SUBNET_GROUP_NAME}"
    fi

    info "Waiting for RDS snapshot '${snapshot_id}' to become available before restoring"
    run aws rds wait db-snapshot-completed --db-snapshot-identifier "${snapshot_id}" > /dev/null

    run aws rds restore-db-instance-from-db-snapshot --db-instance-identifier "${instance_id}" \
        --db-snapshot-identifier "${snapshot_id}" ${optional_args} > /dev/null

    info "Waiting until the RDS instance is available. This could take some time"
    run aws rds wait db-instance-available --db-instance-identifier "${instance_id}"  > /dev/null

    if [ -n "${RESTORE_RDS_SECURITY_GROUP}" ]; then
        # When restoring a DB instance outside of a VPC this command will need
        # to be modified to use --db-security-groups instead of --vpc-security-group-ids
        # For more information see http://docs.aws.amazon.com/cli/latest/reference/rds/modify-db-instance.html
        run aws rds modify-db-instance --apply-immediately --db-instance-identifier "${instance_id}" \
            --vpc-security-group-ids "${RESTORE_RDS_SECURITY_GROUP}" > /dev/null
    fi
}

function find_attached_ebs_volume {
    local device_name="${1}"
    local volume_description=$(run aws ec2 describe-volumes --filter Name=attachment.instance-id,Values="${AWS_EC2_INSTANCE_ID}" \
            Name=attachment.device,Values="${device_name}")

    local ebs_volume=$(echo "${volume_description}" | jq -r '.Volumes[0].VolumeId')
    if [ -z "${ebs_volume}" -o "${ebs_volume}" = "null" ]; then
        error "Could not find 'Volume' with 'VolumeId' in response '${volume_description}'"
        bail "Unable to retrieve volume information for device '${device_name}'"
    fi

    echo "${ebs_volume}"
}

function validate_rds_instance_id {
    local instance_id="$1"
    local instance_description=$(run aws rds describe-db-instances --db-instance-identifier "${instance_id}")

    local db_instance_status=$(echo "${instance_description}" | jq -r '.DBInstances[0].DBInstanceStatus')
    case "${db_instance_status}" in
        "" | "null")
            error "Could not find a 'DBInstance' with 'DBInstanceStatus' in response '${instance_description}'"
            bail "Please make sure you have selected an existing RDS instance"
            ;;
        "available")
            ;;
        *)
            error "The RDS instance '${instance_id}' status is '${db_instance_status}', expected 'available'"
            bail "The RDS instance must be 'available' before the backup can be started."
            ;;
    esac
}

function validate_rds_snapshot {
    local snapshot_tag="$1"
    local db_snapshot_description=$(run aws rds describe-db-snapshots --db-snapshot-identifier "${snapshot_tag}")

    local rds_snapshot_id=$(echo "${db_snapshot_description}" | jq -r '.DBSnapshots[0]?.DBSnapshotIdentifier')
    if [ -z "${rds_snapshot_id}" -o "${rds_snapshot_id}" = "null" ]; then
        error "Could not find a 'DBSnapshot' with 'DBSnapshotIdentifier' in response '${db_snapshot_description}'"
        # To assist the with locating snapshot tags list the available EBS snapshot tags, and then bail
        list_available_ebs_snapshot_tags
        bail "Please select a tag with an associated RDS snapshot."
    else
        info "Found RDS snapshot '${rds_snapshot_id}' for tag '${snapshot_tag}'"
    fi
}

function list_available_ebs_snapshot_tags {
    # Print a list of all snapshots tag values that start with the tag prefix
    print "Available snapshot tags:"

    local available_ebs_snapshot_tags=$(run aws ec2 describe-snapshots --filters Name=tag-key,Values="Name" \
        Name=tag-value,Values="${SNAPSHOT_TAG_PREFIX}*" | jq -r ".Snapshots[].Tags[] | select(.Key == \"Name\") \
        | .Value" | sort -r)
    if [ -z "${available_ebs_snapshot_tags}" -o "${available_ebs_snapshot_tags}" = "null" ]; then
        error "Could not find 'Snapshots' with 'Tags' with 'Value' in response '${snapshot_description}'"
        bail "Unable to retrieve list of available EBS snapshot tags"
    fi

    echo "${available_ebs_snapshot_tags}"
}

# List all RDS DB snapshots older than the most recent ${KEEP_BACKUPS}
function list_old_rds_snapshot_ids {
    local region=$1
    run aws rds describe-db-snapshots --region "${region}" --snapshot-type manual | \
        jq -r ".DBSnapshots | map(select(.DBSnapshotIdentifier | \
        startswith(\"${SNAPSHOT_TAG_PREFIX}\"))) | sort_by(.SnapshotCreateTime) | reverse | .[${KEEP_BACKUPS}:] | \
        map(.DBSnapshotIdentifier)[]"
}

# List all EBS snapshots older than the most recent ${KEEP_BACKUPS}
function list_old_ebs_snapshot_ids {
    local region=$1
    run aws ec2 describe-snapshots --region "${region}" --filters "Name=tag:Name,Values=${SNAPSHOT_TAG_PREFIX}*" | \
        jq -r ".Snapshots | sort_by(.StartTime) | reverse | .[${KEEP_BACKUPS}:] | map(.SnapshotId)[]"
}

function get_aws_account_id {
    # Returns the ID of the AWS account that this instance is running in.
    local instance_info=$(run curl ${CURL_OPTIONS} http://169.254.169.254/latest/dynamic/instance-identity/document)

    local account_id=$(echo "${instance_info}" | jq -r '.accountId')
    if [ -z "${account_id}" ]; then
        error "Could not find 'accountId' in response '${instance_info}'"
        bail "Unable to determine account id"
    fi

    echo "${account_id}"
}
