#!/bin/bash

check_command "aws"
check_command "jq"

# Ensure the AWS region has been provided
if [ -z "${AWS_REGION}" ] || [ "${AWS_REGION}" == null ]; then
    error "The AWS region must be set as AWS_REGION in ${BACKUP_VARS_FILE}"
    bail "See stash.diy-aws-backup.vars.sh.example for the defaults."
fi

if [ -z "${AWS_ACCESS_KEY_ID}" ] ||  [ -z "${AWS_SECRET_ACCESS_KEY}" ]; then
    AWS_INSTANCE_ROLE=`curl --silent --fail http://169.254.169.254/latest/meta-data/iam/security-credentials/`
    if [ -z "${AWS_INSTANCE_ROLE}" ]; then
        error "Could not find the necessary credentials to run backup"
        error "We recommend launching the instance with an appropiate IAM role"
        error "Alternatively AWS credentials can be set as AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY in ${BACKUP_VARS_FILE}"
        bail "See stash.diy-aws-backup.vars.sh.example for the defaults."
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

    bail "See stash.diy-aws-backup.vars.sh.example for the defaults."
elif [ ! "${INSTANCE_NAME}" == ${INSTANCE_NAME%[[:space:]]*} ]; then
    error "Instance name cannot contain spaces"

    bail "See stash.diy-aws-backup.vars.sh.example for the defaults."
elif [ ${#INSTANCE_NAME} -ge 100 ]; then
    error "Instance name must be under 100 characters in length"

    bail "See stash.diy-aws-backup.vars.sh.example for the defaults."
fi

SNAPSHOT_TAG_KEY="Name"
SNAPSHOT_TAG_PREFIX="${INSTANCE_NAME}-"
SNAPSHOT_TAG_VALUE="${SNAPSHOT_TAG_PREFIX}`date +"%Y%m%d-%H%M%S-%3N"`"

function snapshot_ebs_volume {
    local VOLUME_ID="$1"

    local SNAPSHOT_ID=$(aws ec2 create-snapshot --volume-id "${VOLUME_ID}" --description "$2" | jq -r '.SnapshotId')

    success "Taken snapshot ${SNAPSHOT_ID} of volume ${VOLUME_ID}"

    aws ec2 create-tags --resources "${SNAPSHOT_ID}" --tags Key="${SNAPSHOT_TAG_KEY}",Value="${SNAPSHOT_TAG_VALUE}"

    info "Tagged ${SNAPSHOT_ID} with ${SNAPSHOT_TAG_KEY}=${SNAPSHOT_TAG_VALUE}"
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

    aws ec2 attach-volume --volume-id "${VOLUME_ID}" --instance "${INSTANCE_ID}" --device "${DEVICE_NAME}" > /dev/null 2>&1

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

    local INSTANCE_ID=`curl --silent --fail http://169.254.169.254/latest/meta-data/instance-id`

    attach_volume "${VOLUME_ID}" "${DEVICE_NAME}" "${INSTANCE_ID}"

    mount_device "${DEVICE_NAME}" "${MOUNT_POINT}"
}

function validate_ebs_snapshot {
    local SNAPSHOT_TAG="$1"
    local  __RETURN=$2

    local SNAPSHOT_ID="$(aws ec2 describe-snapshots --filters Name=tag-key,Values=\"Name\" Name=tag-value,Values=\"${SNAPSHOT_TAG}\" 2>/dev/null | jq -r '.Snapshots[0]?.SnapshotId')"
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
    local INSTANCE_ID=`curl --silent --fail http://169.254.169.254/latest/meta-data/instance-id`

    # If there's a volume taking the provided DEVICE_NAME it must be unmounted and detached
    info "Checking for existing volumes using device name ${DEVICE_NAME}"
    local VOLUME_ID="$(aws ec2 describe-volumes --filter Name=attachment.instance-id,Values=${INSTANCE_ID} Name=attachment.device,Values=${DEVICE_NAME} 2> /dev/null | jq -r '.Volumes[0].VolumeId')"

    case "${VOLUME_ID}" in vol-*)
        error "Device name ${DEVICE_NAME} appears to be taken by volume ${VOLUME_ID}"

        bail "Please make sure Stash has been stopped, that the EBS volume is not in use, and that it has been unmounted and dettached"
        ;;
    esac
}

function snapshot_rds_instance {
    local INSTANCE_ID="$1"

    # We use SNAPSHOT_TAG as the snapshot identifier because it's unique and because it will allow us to relate an EBS snapshot to an RDS snapshot by tag
    aws rds create-db-snapshot --db-instance-identifier "${INSTANCE_ID}" --db-snapshot-identifier "${SNAPSHOT_TAG_VALUE}" --tags Key="${SNAPSHOT_TAG_KEY}",Value="${SNAPSHOT_TAG_VALUE}" > /dev/null

    # Wait until the database has completed the backup
    info "Waiting for instance ${INSTANCE_ID} to complete backup. This could take some time"
    aws rds wait db-instance-available --db-instance-identifier "${INSTANCE_ID}"

    success "Taken snapshot ${SNAPSHOT_TAG_VALUE} of RDS instance ${INSTANCE_ID}"

    info "Tagged ${SNAPSHOT_TAG_VALUE} with ${SNAPSHOT_TAG_KEY}=${SNAPSHOT_TAG_VALUE}"
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
    local VOLUME_ID="$1"

    STATE=$(aws ec2 describe-volumes --volume-ids ${VOLUME_ID} 2> /dev/null | jq -r '.Volumes[0].State')
    if [ -z "${STATE}" ] || [ "${STATE}" == null ]; then
        error "Could not retrieve attachment state for volume ${VOLUME_ID}"

        bail "Please make sure you have selected an existing volume"
    elif [ "${STATE}" != "in-use" ]; then
        error "The volume ${VOLUME_ID} state is ${STATE}"

        bail "Please select a volume in use"
    fi
}

function validate_rds_instance_id {
    local INSTANCE_ID="$1"

    STATE=$(aws rds describe-db-instances --db-instance-identifier ${INSTANCE_ID} 2> /dev/null | jq -r '.DBInstances[0].DBInstanceStatus')
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

    local SNAPSHOT_ID="`aws rds describe-db-snapshots --db-snapshot-identifier \"${SNAPSHOT_TAG}\" 2>/dev/null | jq -r '.DBSnapshots[0]?.DBSnapshotIdentifier'`"
    if [ -z "${SNAPSHOT_ID}" ] || [ "${SNAPSHOT_ID}" == null ]; then
         error "Could not find RDS snapshot for tag ${SNAPSHOT_TAG}"

        list_available_ebs_snapshot_tags
        bail "Please select a tag with an associated RDS snapshot"
    else
        info "Found RDS snapshot ${SNAPSHOT_ID} for tag ${SNAPSHOT_TAG}"
    fi
}

function list_available_ebs_snapshot_tags {
    # Print a list of all snapshots tag values that start with the tag prefix
    print "Available snapshot tags:"
    aws ec2 describe-snapshots --filters Name=tag-key,Values="Name" Name=tag-value,Values="${SNAPSHOT_TAG_PREFIX}*" | jq -r ".Snapshots[].Tags[] | select(.Key == \"Name\") | .Value" | sort -r
}
