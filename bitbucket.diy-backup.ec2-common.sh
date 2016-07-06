#!/bin/bash

check_command "aws"
check_command "jq"

# Ensure the AWS region has been provided
if [ -z "${AWS_REGION}" ] || [ "${AWS_REGION}" == null ]; then
    error "The AWS region must be set as AWS_REGION in ${BACKUP_VARS_FILE}"
    bail "See bitbucket.diy-aws-backup.vars.sh.example for the defaults."
fi

if [ -z "${AWS_ACCESS_KEY_ID}" ] ||  [ -z "${AWS_SECRET_ACCESS_KEY}" ]; then
    AWS_INSTANCE_ROLE=`curl ${CURL_OPTIONS} http://169.254.169.254/latest/meta-data/iam/security-credentials/`
    if [ -z "${AWS_INSTANCE_ROLE}" ]; then
        error "Could not find the necessary credentials to run backup"
        error "We recommend launching the instance with an appropriate IAM role"
        error "Alternatively AWS credentials can be set as AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY in ${BACKUP_VARS_FILE}"
        bail "See bitbucket.diy-aws-backup.vars.sh.example for the defaults."
    else
        info "Using IAM instance role ${AWS_INSTANCE_ROLE}"
    fi
else
    info "Found AWS credentials"
    export AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
    export AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}
fi

export AWS_DEFAULT_REGION=${AWS_REGION}
export AWS_DEFAULT_OUTPUT=json

if [ -z "${INSTANCE_NAME}" ]; then
    error "The ${PRODUCT} instance name must be set as INSTANCE_NAME in ${BACKUP_VARS_FILE}"

    bail "See bitbucket.diy-aws-backup.vars.sh.example for the defaults."
elif [ ! "${INSTANCE_NAME}" == ${INSTANCE_NAME%[[:space:]]*} ]; then
    error "Instance name cannot contain spaces"

    bail "See bitbucket.diy-aws-backup.vars.sh.example for the defaults."
elif [ ${#INSTANCE_NAME} -ge 100 ]; then
    error "Instance name must be under 100 characters in length"

    bail "See bitbucket.diy-aws-backup.vars.sh.example for the defaults."
fi

SNAPSHOT_TAG_KEY="Name"
SNAPSHOT_TAG_PREFIX="${INSTANCE_NAME}-"
SNAPSHOT_TIME=`date +"%Y%m%d-%H%M%S-%3N"`
SNAPSHOT_TAG_VALUE="${SNAPSHOT_TAG_PREFIX}${SNAPSHOT_TIME}"

function snapshot_ebs_volume {
    local VOLUME_ID="$1"

    local EBS_SNAPSHOT_ID=$(aws ec2 create-snapshot --volume-id "${VOLUME_ID}" --description "$2" | jq -r '.SnapshotId')

    success "Taken EBS snapshot ${EBS_SNAPSHOT_ID} of volume ${VOLUME_ID}"

    aws ec2 create-tags --resources "${EBS_SNAPSHOT_ID}" --tags Key="${SNAPSHOT_TAG_KEY}",Value="${SNAPSHOT_TAG_VALUE}"

    info "Tagged EBS snapshot ${EBS_SNAPSHOT_ID} with ${SNAPSHOT_TAG_KEY}=${SNAPSHOT_TAG_VALUE}"

    if [ ! -z "${AWS_ADDITIONAL_TAGS}" ]; then
       aws ec2 create-tags --resources "${EBS_SNAPSHOT_ID}" --tags "[ ${AWS_ADDITIONAL_TAGS} ]"
       info "Tagged EBS snapshot ${EBS_SNAPSHOT_ID} with additional tags: ${AWS_ADDITIONAL_TAGS}"
    fi

    # Return EBS snapshot ID
    echo ${EBS_SNAPSHOT_ID}
}

function create_volume {
    local SNAPSHOT_ID="$1"
    local VOLUME_TYPE="$2"
    local PROVISIONED_IOPS="$3"

    local OPTIONAL_ARGS=
    if [ "io1" == "${VOLUME_TYPE}" ] && [ ! -z "${PROVISIONED_IOPS}" ]; then
        info "Restoring volume with ${PROVISIONED_IOPS} provisioned IOPS"
        OPTIONAL_ARGS="--iops ${PROVISIONED_IOPS}"
    fi

    eval "VOLUME_ID=$(aws ec2 create-volume --snapshot ${SNAPSHOT_ID} --availability-zone ${AWS_AVAILABILITY_ZONE} --volume-type ${VOLUME_TYPE} ${OPTIONAL_ARGS} | jq -r '.VolumeId')"

    aws ec2 wait volume-available --volume-ids "${VOLUME_ID}"

    success "Restored snapshot ${SNAPSHOT_ID} into volume ${VOLUME_ID}"
}

function attach_volume {
    local VOLUME_ID="$1"
    local DEVICE_NAME="$2"
    local INSTANCE_ID="$3"

    aws ec2 attach-volume --volume-id "${VOLUME_ID}" --instance "${INSTANCE_ID}" --device "${DEVICE_NAME}" > /dev/null

    wait_attached_volume "${VOLUME_ID}"

    success "Attached volume ${VOLUME_ID} to device ${DEVICE_NAME} at instance ${INSTANCE_ID}"
}

function wait_attached_volume {
    local VOLUME_ID="$1"

    info "Waiting for volume ${VOLUME_ID} to be attached. This could take some time"

    TIMEOUT=120
    END=$((SECONDS+${TIMEOUT}))

    local STATE='attaching'
    while [ $SECONDS -lt $END ]; do
        # aws ec2 wait volume-in-use ${VOLUME_ID} is not enough.
        # A volume state can be 'in-use' while its attachment state is still 'attaching'
        # If the volume is not fully attach we cannot issue a mount command for it
        STATE=$(aws ec2 describe-volumes --volume-ids ${VOLUME_ID} | jq -r '.Volumes[0].Attachments[0].State')
        info "Volume ${VOLUME_ID} state: ${STATE}"
        if [ "attached" == "${STATE}" ]; then
            break
        fi

        sleep 10
    done

    if [ "attached" != "${STATE}" ]; then
        bail "Unable to attach volume ${VOLUME_ID}. Attachment state is ${STATE} after ${TIMEOUT} seconds"
    fi
}

function restore_from_snapshot {
    local SNAPSHOT_ID="$1"
    local VOLUME_TYPE="$2"
    local PROVISIONED_IOPS="$3"
    local DEVICE_NAME="$4"
    local MOUNT_POINT="$5"

    local VOLUME_ID=
    create_volume "${SNAPSHOT_ID}" "${VOLUME_TYPE}" "${PROVISIONED_IOPS}" VOLUME_ID

    local INSTANCE_ID=`curl ${CURL_OPTIONS} http://169.254.169.254/latest/meta-data/instance-id`

    attach_volume "${VOLUME_ID}" "${DEVICE_NAME}" "${INSTANCE_ID}"

    mount_device "${DEVICE_NAME}" "${MOUNT_POINT}"
}

function validate_ebs_snapshot {
    local SNAPSHOT_TAG="$1"
    local  __RETURN=$2

    local SNAPSHOT_ID="$(aws ec2 describe-snapshots --filters Name=tag-key,Values=\"Name\" Name=tag-value,Values=\"${SNAPSHOT_TAG}\" | jq -r '.Snapshots[0]?.SnapshotId')"
    if [ -z "${SNAPSHOT_ID}" ] || [ "${SNAPSHOT_ID}" == null ]; then
        error "Could not find EBS snapshot for tag ${SNAPSHOT_TAG}"
        list_available_ebs_snapshot_tags

        bail "Please select an available tag"
    else
        info "Found EBS snapshot ${SNAPSHOT_ID} for tag ${SNAPSHOT_TAG}"

        eval ${__RETURN}="${SNAPSHOT_ID}"
    fi
}

function validate_device_name {
    local DEVICE_NAME="${1}"
    local INSTANCE_ID=`curl ${CURL_OPTIONS} http://169.254.169.254/latest/meta-data/instance-id`

    # If there's a volume taking the provided DEVICE_NAME it must be unmounted and detached
    info "Checking for existing volumes using device name ${DEVICE_NAME}"
    local VOLUME_ID="$(aws ec2 describe-volumes --filter Name=attachment.instance-id,Values=${INSTANCE_ID} Name=attachment.device,Values=${DEVICE_NAME} | jq -r '.Volumes[0].VolumeId')"

    case "${VOLUME_ID}" in vol-*)
        error "Device name ${DEVICE_NAME} appears to be taken by volume ${VOLUME_ID}"

        bail "Please stop Bitbucket. Stop PostgreSQL if it is running. Unmount the device and detach the volume"
        ;;
    esac
}

function snapshot_rds_instance {
    local INSTANCE_ID="$1"

    if [ ! -z "${AWS_ADDITIONAL_TAGS}" ]; then
        COMMA=', '
    fi

    AWS_TAGS="[ {\"Key\": \"${SNAPSHOT_TAG_KEY}\", \"Value\": \"${SNAPSHOT_TAG_VALUE}\"}${COMMA}${AWS_ADDITIONAL_TAGS} ]"

    # We use SNAPSHOT_TAG as the snapshot identifier because it's unique and because it will allow us to relate an EBS snapshot to an RDS snapshot by tag
    aws rds create-db-snapshot --db-instance-identifier "${INSTANCE_ID}" --db-snapshot-identifier "${SNAPSHOT_TAG_VALUE}" --tags "${AWS_TAGS}" > /dev/null

    # Wait until the database has completed the backup
    info "Waiting for instance ${INSTANCE_ID} to complete backup. This could take some time"
    aws rds wait db-instance-available --db-instance-identifier "${INSTANCE_ID}"

    success "Taken snapshot ${SNAPSHOT_TAG_VALUE} of RDS instance ${INSTANCE_ID}"

    info "Tagged ${SNAPSHOT_TAG_VALUE} with ${AWS_TAGS}"

    # Return RDS Snapshot ID
    echo ${SNAPSHOT_TAG_VALUE}
}

function restore_rds_instance {
    local INSTANCE_ID="$1"
    local SNAPSHOT_ID="$2"

    local OPTIONAL_ARGS=
    if [ ! -z "${RESTORE_RDS_INSTANCE_CLASS}" ]; then
        info "Restoring database to instance class ${RESTORE_RDS_INSTANCE_CLASS}"
        OPTIONAL_ARGS="--db-instance-class ${RESTORE_RDS_INSTANCE_CLASS}"
    fi

    if [ ! -z "${RESTORE_RDS_SUBNET_GROUP_NAME}" ]; then
        info "Restoring database to subnet group ${RESTORE_RDS_SUBNET_GROUP_NAME}"
        OPTIONAL_ARGS="${OPTIONAL_ARGS} --db-subnet-group-name ${RESTORE_RDS_SUBNET_GROUP_NAME}"
    fi

    aws rds restore-db-instance-from-db-snapshot --db-instance-identifier "${INSTANCE_ID}" --db-snapshot-identifier "${SNAPSHOT_ID}" ${OPTIONAL_ARGS} > /dev/null

    info "Waiting until the RDS instance is available. This could take some time"

    aws rds wait db-instance-available --db-instance-identifier "${INSTANCE_ID}"

    info "Restored snapshot ${SNAPSHOT_ID} to instance ${INSTANCE_ID}"

    if [ ! -z "${RESTORE_RDS_SECURITY_GROUP}" ]; then
        # When restoring a DB instance outside of a VPC this command will need to be modified to use --db-security-groups instead of --vpc-security-group-ids
        # For more information see http://docs.aws.amazon.com/cli/latest/reference/rds/modify-db-instance.html
        aws rds modify-db-instance --apply-immediately --db-instance-identifier "${INSTANCE_ID}" --vpc-security-group-ids "${RESTORE_RDS_SECURITY_GROUP}" > /dev/null

        info "Changed security groups of ${INSTANCE_ID} to ${RESTORE_RDS_SECURITY_GROUP}"
    fi
}

function validate_ebs_volume {
    local DEVICE_NAME="${1}"
    local __RETURN=$2
    local INSTANCE_ID=`curl ${CURL_OPTIONS} http://169.254.169.254/latest/meta-data/instance-id`

    info "Looking up volume for device name ${DEVICE_NAME}"
    local VOLUME_ID="$(aws ec2 describe-volumes --filter Name=attachment.instance-id,Values=${INSTANCE_ID} Name=attachment.device,Values=${DEVICE_NAME} | jq -r '.Volumes[0].VolumeId')"

    eval ${__RETURN}="${VOLUME_ID}"
}

function validate_rds_instance_id {
    local INSTANCE_ID="$1"

    STATE=$(aws rds describe-db-instances --db-instance-identifier ${INSTANCE_ID} | jq -r '.DBInstances[0].DBInstanceStatus')
    if [ -z "${STATE}" ] || [ "${STATE}" == null ]; then
        error "Could not retrieve instance status for db ${INSTANCE_ID}"

        bail "Please make sure you have selected an existing rds instance"
    elif [ "${STATE}" != "available" ]; then
        error "The instance ${INSTANCE_ID} status is ${STATE}"

        bail "The instance must be available before the backup can be started"
    fi
}

function validate_rds_snapshot {
    local SNAPSHOT_TAG="$1"

    local RDS_SNAPSHOT_ID="`aws rds describe-db-snapshots --db-snapshot-identifier \"${SNAPSHOT_TAG}\" | jq -r '.DBSnapshots[0]?.DBSnapshotIdentifier'`"
    if [ -z "${RDS_SNAPSHOT_ID}" ] || [ "${RDS_SNAPSHOT_ID}" == null ]; then
         error "Could not find RDS snapshot for tag ${SNAPSHOT_TAG}"

        list_available_ebs_snapshot_tags
        bail "Please select a tag with an associated RDS snapshot"
    else
        info "Found RDS snapshot ${RDS_SNAPSHOT_ID} for tag ${SNAPSHOT_TAG}"
    fi
}

function list_available_ebs_snapshot_tags {
    # Print a list of all snapshots tag values that start with the tag prefix
    print "Available snapshot tags:"
    aws ec2 describe-snapshots --filters Name=tag-key,Values="Name" Name=tag-value,Values="${SNAPSHOT_TAG_PREFIX}*" | jq -r ".Snapshots[].Tags[] | select(.Key == \"Name\") | .Value" | sort -r
}

# List all RDS DB snapshots older than the most recent ${KEEP_BACKUPS}
function list_old_rds_snapshot_ids {
    if [ "${KEEP_BACKUPS}" -gt 0 ]; then
        aws rds describe-db-snapshots --snapshot-type manual | jq -r ".DBSnapshots | map(select(.DBSnapshotIdentifier | startswith(\"${SNAPSHOT_TAG_PREFIX}\"))) | sort_by(.SnapshotCreateTime) | reverse | .[${KEEP_BACKUPS}:] | map(.DBSnapshotIdentifier)[]"
    fi
}

function delete_rds_snapshot {
    local RDS_SNAPSHOT_ID="$1"
    aws rds delete-db-snapshot --db-snapshot-identifier "${RDS_SNAPSHOT_ID}" > /dev/null
}

# List all EBS snapshots older than the most recent ${KEEP_BACKUPS}
function list_old_ebs_snapshot_ids {
    if [ "${KEEP_BACKUPS}" -gt 0 ]; then
        aws ec2 describe-snapshots --filters "Name=tag:Name,Values=${SNAPSHOT_TAG_PREFIX}*" \
         | jq -r ".Snapshots | sort_by(.StartTime) | reverse | .[${KEEP_BACKUPS}:] | map(.SnapshotId)[]"
    fi
}

function delete_ebs_snapshot {
    local EBS_SNAPSHOT_ID="$1"
    aws ec2 delete-snapshot --snapshot-id "${EBS_SNAPSHOT_ID}"
}

function copy_ebs_snapshot {
    local source_ebs_snapshot_id="$1"
    local source_region="$2"

   if [ -z "${BACKUP_EBS_DEST_REGION}" ]; then
        error "Cannot share EBS snapshot across account as vars have not been set."
        bail "Please ensure var BACKUP_EBS_DEST_REGION has been correctly set"
   fi

    info "Waiting for EBS snapshot ${source_ebs_snapshot_id} to become available in ${source_region} before copying to ${BACKUP_EBS_DEST_REGION}"
    aws ec2 wait snapshot-completed --region ${source_region} --snapshot-ids ${source_ebs_snapshot_id}

    # Copy snapshot to DEST_REGION
    local dest_snapshot_id=$(aws ec2 copy-snapshot --region "${BACKUP_EBS_DEST_REGION}" --source-region "${source_region}" \
     --source-snapshot-id "${source_ebs_snapshot_id}" | jq -r '.SnapshotId')
    info "Copied EBS snapshot ${source_ebs_snapshot_id} from ${source_region} to ${BACKUP_EBS_DEST_REGION}. Snapshot copy ID: ${dest_snapshot_id}"

    info "Waiting for EBS snapshot ${dest_snapshot_id} to become available in ${BACKUP_EBS_DEST_REGION} before tagging"
    aws ec2 wait snapshot-completed --region ${BACKUP_EBS_DEST_REGION} --snapshot-ids ${dest_snapshot_id}

    # Add tags to copied snapshot
    aws ec2 create-tags --region ${BACKUP_EBS_DEST_REGION} --resources "${dest_snapshot_id}" --tags Key=Name,Value="${SNAPSHOT_TAG_VALUE}"
    info "Tagged EBS snapshot ${dest_snapshot_id} with {Name: ${SNAPSHOT_TAG_VALUE}}"
}

function copy_and_share_ebs_snapshot {
    local source_ebs_snapshot_id="$1"
    local source_region="$2"

    info "Waiting for EBS snapshot ${source_ebs_snapshot_id} to become available in ${source_region} before copying to ${BACKUP_EBS_DEST_REGION}"
    aws ec2 wait snapshot-completed --region ${source_region} --snapshot-ids ${source_ebs_snapshot_id}

    # Copy snapshot to BACKUP_EBS_DEST_REGION
    local dest_snapshot_id=$(aws ec2 copy-snapshot --region "${BACKUP_EBS_DEST_REGION}" --source-region "${source_region}" \
        --source-snapshot-id "${source_ebs_snapshot_id}" | jq -r '.SnapshotId')
    info "Copied EBS snapshot ${source_ebs_snapshot_id} from ${source_region} to ${BACKUP_EBS_DEST_REGION}. Snapshot copy ID: ${dest_snapshot_id}"

    info "Waiting for EBS snapshot ${dest_snapshot_id} to become available in ${BACKUP_EBS_DEST_REGION} before modifying permissions"
    aws ec2 wait snapshot-completed --region ${BACKUP_EBS_DEST_REGION} --snapshot-ids ${dest_snapshot_id}

    # Give BACKUP_DEST_AWS_ACCOUNT_ID permissions on the copied snapshot
    aws ec2 modify-snapshot-attribute --snapshot-id "${dest_snapshot_id}" --region ${BACKUP_EBS_DEST_REGION} \
        --attribute createVolumePermission --operation-type add --user-ids "${BACKUP_DEST_AWS_ACCOUNT_ID}"
    info "Granted create volume permission on ${dest_snapshot_id} for account:${BACKUP_DEST_AWS_ACCOUNT_ID}"

    info "Waiting for EBS snapshot ${dest_snapshot_id} to become available in ${BACKUP_EBS_DEST_REGION} before tagging"
    aws ec2 wait snapshot-completed --region ${BACKUP_EBS_DEST_REGION} --snapshot-ids ${dest_snapshot_id}

    info "Assuming AWS role ${BACKUP_DEST_AWS_ROLE} to tag copied snapshot"
    local creds=$(aws sts assume-role --role-arn ${BACKUP_DEST_AWS_ROLE} --role-session-name "BitbucketServerDIYBackup")

    # Add tag to copied snapshot, used to find EBS & RDS snapshot pairs for restoration
    AWS_ACCESS_KEY_ID="$(echo $creds | jq -r .Credentials.AccessKeyId)" \
        AWS_SECRET_ACCESS_KEY="$(echo $creds | jq -r .Credentials.SecretAccessKey)" \
        AWS_SESSION_TOKEN="$(echo $creds | jq -r .Credentials.SessionToken)" \
        aws ec2 create-tags --region ${BACKUP_EBS_DEST_REGION} --resources "${dest_snapshot_id}" \
            --tags Key=Name,Value="${SNAPSHOT_TAG_VALUE}"
    info "Tagged EBS snapshot ${dest_snapshot_id} with {Name: ${SNAPSHOT_TAG_VALUE}}"
}

function share_and_copy_rds_snapshot {
    local rds_snapshot_id="$1"
    local source_aws_account_id=$(get_aws_account_id)

    if [ -z "${BACKUP_DEST_AWS_ROLE}" ] ; then
        error "Cannot share RDS snapshot across account as vars aren't correctly set."
        bail "Please ensure both BACKUP_DEST_AWS_ROLE has been set"
    fi

    info "Waiting for RDS snapshot copy ${rds_snapshot_id} to become available before giving AWS account:${BACKUP_DEST_AWS_ACCOUNT_ID} permissions."
    aws rds wait db-snapshot-completed --db-snapshot-identifier "${rds_snapshot_id}"

    # Give permission to BACKUP_DEST_AWS_ACCOUNT_ID
    aws rds modify-db-snapshot-attribute --db-snapshot-identifier "${rds_snapshot_id}" --attribute-name restore \
        --values-to-add "${BACKUP_DEST_AWS_ACCOUNT_ID}" > /dev/null
    info "Granted permissions on RDS snapshot ${rds_snapshot_id} for AWS account:${BACKUP_DEST_AWS_ACCOUNT_ID}"

    # Assume BACKUP_DEST_AWS_ROLE
    local creds=$(aws sts assume-role --role-arn ${BACKUP_DEST_AWS_ROLE} --role-session-name "BitbucketServerDIYBackup")
    local aws_access_key_id="$(echo $creds | jq -r .Credentials.AccessKeyId)"
    local aws_secret_access_key="$(echo $creds | jq -r .Credentials.SecretAccessKey)"
    local aws_session_token="$(echo $creds | jq -r .Credentials.SessionToken)"

    # Copy RDS snapshot to BACKUP_RDS_DEST_REGION in BACKUP_DEST_AWS_ACCOUNT_ID
    local source_rds_snapshot_arn="arn:aws:rds:${AWS_REGION}:${source_aws_account_id}:snapshot:${rds_snapshot_id}"
    AWS_ACCESS_KEY_ID=${aws_access_key_id} AWS_SECRET_ACCESS_KEY=${aws_secret_access_key} AWS_SESSION_TOKEN=${aws_session_token} \
        aws rds copy-db-snapshot --region "${BACKUP_RDS_DEST_REGION}" --source-db-snapshot-identifier "${source_rds_snapshot_arn}" \
            --target-db-snapshot-identifier "${rds_snapshot_id}" > /dev/null
    info "Copied RDS Snapshot ${source_rds_snapshot_arn} as ${rds_snapshot_id} to ${BACKUP_RDS_DEST_REGION}"
}

function copy_rds_snapshot {
    local source_rds_snapshot_id="$1"
    local source_aws_account_id=$(get_aws_account_id)

    info "Waiting for RDS snapshot ${source_rds_snapshot_id} to become available before copying to another region. This could take some time."
    aws rds wait db-snapshot-completed --db-snapshot-identifier "${source_rds_snapshot_id}"

    # Copy RDS snapshot to BACKUP_RDS_DEST_REGION
    local source_rds_snapshot_arn="arn:aws:rds:${AWS_REGION}:${source_aws_account_id}:snapshot:${source_rds_snapshot_id}"
    aws rds copy-db-snapshot --region "${BACKUP_RDS_DEST_REGION}" --source-db-snapshot-identifier "${source_rds_snapshot_arn}" \
      --target-db-snapshot-identifier "${source_rds_snapshot_id}" > /dev/null
    info "Copied RDS Snapshot ${source_rds_snapshot_arn} as ${source_rds_snapshot_id} to ${BACKUP_RDS_DEST_REGION}"
}

function get_aws_account_id {
    # Returns the ID of the AWS account that this instance is running in.
    local account_id=$(curl http://169.254.169.254/latest/dynamic/instance-identity/document | jq -r '.accountId')
    echo ${account_id}
}
