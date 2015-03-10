#!/bin/bash

check_command "aws"
check_command "jq"

# Ensure the AWS region has been provided
if [[ -z ${AWS_REGION} ]]; then
  error "The AWS region must be set in stash.diy-backup.vars.sh"
  bail "See stash.diy-backup.vars.sh.example for the defaults."
fi

if [ -z "${AWS_ACCESS_KEY_ID}" ] ||  [ -z "${AWS_SECRET_ACCESS_KEY}" ]
then
    # The AWS credentials have not been set. Retreive the credentials for the IAM role used to launch the instance
    IAM_INSTANCE_ROLE=`curl --fail http://169.254.169.254/latest/meta-data/iam/security-credentials/`
    if [ ! -z "${IAM_INSTANCE_ROLE}" ]
    then
        AWS_ACCESS_KEY_ID=`curl --fail http://169.254.169.254/latest/meta-data/iam/security-credentials/${IAM_INSTANCE_ROLE} | grep AccessKeyId | cut -d':' -f2 | sed 's/[^0-9A-Z]*//g'`
        AWS_SECRET_ACCESS_KEY=`curl --fail http://169.254.169.254/latest/meta-data/iam/security-credentials/${IAM_INSTANCE_ROLE} | grep SecretAccessKey | cut -d':' -f2 | sed 's/[^0-9A-Za-z/+=]*//g'`
    fi
fi

if [ -z "${AWS_ACCESS_KEY_ID}" ] ||  [ -z "${AWS_SECRET_ACCESS_KEY}" ]
then
    error "The AWS credentials must be set via an instance IAM role or in stash.diy-backup.vars.sh"
    bail "See stash.diy-backup.vars.sh.example for the defaults."
fi

#The aws command requires these to be set
aws configure set aws_access_key_id ${AWS_ACCESS_KEY_ID}
aws configure set aws_secret_access_key ${AWS_SECRET_ACCESS_KEY}
aws configure set region ${AWS_REGION}
aws configure set format json

TAG_KEY="${PRODUCT}-Backup-ID"

function snapshot_ebs_volume {
    VOLUME_ID="$1"

    SNAPSHOT_ID=$(aws ec2 create-snapshot --volume-id ${VOLUME_ID} --description "$2" | jq -r '.SnapshotId')

    success "Taken snapshot ${SNAPSHOT_ID} of volume ${VOLUME_ID}"

    aws ec2 create-tags --resources "${SNAPSHOT_ID}" --tags Key="${TAG_KEY}",Value="${BACKUP_ID}"

    info "Tagged ${SNAPSHOT_ID} with Key [${TAG_KEY}] and Value [${BACKUP_ID}]"
}

function create_volume {
    SNAPSHOT_ID="$1"
    VOLUME_TYPE="$2"
    PROVISIONED_IOPS="$3"

    OPTIONAL_ARGS=
    if [ "io1" == "${VOLUME_TYPE}" ] && [ ! -z "${PROVISIONED_IOPS}" ]; then
        info "Restoring volume with ${PROVISIONED_IOPS} provisioned IOPS"
        OPTIONAL_ARGS="--iops ${PROVISIONED_IOPS}"
    fi

    VOLUME_ID=$(aws ec2 create-volume --snapshot ${SNAPSHOT_ID} --availability-zone ${AWS_AVAILABILITY_ZONE} --volume-type ${VOLUME_TYPE} ${OPTIONAL_ARGS} | jq -r '.VolumeId')

    aws ec2 wait volume-available --volume-ids ${VOLUME_ID}

    success "Restored snapshot ${SNAPSHOT_ID} into volume ${VOLUME_ID}"
}

function restore_from_snapshot {
    SNAPSHOT_ID="$1"
    VOLUME_TYPE="$2"
    PROVISIONED_IOPS="$3"

    validate_ebs_snapshot "${SNAPSHOT_ID}"

    create_volume "${SNAPSHOT_ID}" "${VOLUME_TYPE}" "${PROVISIONED_IOPS}"
}

function validate_ebs_snapshot {
    SNAPSHOT_ID="$1"

    aws ec2 describe-snapshots | grep ${SNAPSHOT_ID} 2>&1 > /dev/null
    if [ $? != 0 ]; then
        error "Could not find snapshot ${SNAPSHOT_ID} in region ${AWS_REGION}"

        print "Available snapshots:"
        aws ec2 describe-snapshots

        bail "If the snapshot was created in a region other than ${AWS_REGION} please copy the snapshot before restoring ${PRODUCT}"
    fi
}

function snapshot_rds_instance {
    INSTANCE_ID="$1"
    SNAPSHOT_ID="$2"

    aws rds create-db-snapshot --db-instance-identifier ${INSTANCE_ID} --db-snapshot-identifier ${SNAPSHOT_ID} --tags Key="${TAG_KEY}",Value="${BACKUP_ID}" > /dev/null

    # Wait until the database has completed the backup
    aws rds wait db-instance-available --db-instance-identifier ${INSTANCE_ID}

    success "Taken snapshot ${SNAPSHOT_ID} of RDS instance ${INSTANCE_ID}"

    info "Tagged ${SNAPSHOT_ID} with Key [${TAG_KEY}] and Value [${BACKUP_ID}]"
}

function restore_rds_instance {
    INSTANCE_ID="$1"
    SNAPSHOT_ID="$2"

    validate_rds_snapshot "${SNAPSHOT_ID}"

    OPTIONAL_ARGS=
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

    aws rds wait db-instance-available --db-instance-identifier ${INSTANCE_ID}

    info "Restored snapshot ${SNAPSHOT_ID} to instance ${INSTANCE_ID}"

    if [ ! -z "${RESTORE_RDS_SECURITY_GROUP}" ]; then
        SNAPSHOT_VPC_ID="$(aws rds describe-db-snapshots --db-snapshot-identifier ${SNAPSHOT_ID} | jq -r '.DBSnapshots[0].VpcId')"

        # The command argument is different for databases in a VPC
        # A database will be in a VPC if the user specified a VPC subnet group or if the snapshot was in a VPC
        if [ -z "${SNAPSHOT_VPC_ID}" ] && [ -z "${RESTORE_RDS_SUBNET_GROUP_NAME}" ]; then
            aws rds modify-db-instance --apply-immediately --db-instance-identifier "${INSTANCE_ID}" --db-security-groups "${RESTORE_RDS_SECURITY_GROUP}" > /dev/null
        else
            aws rds modify-db-instance --apply-immediately --db-instance-identifier "${INSTANCE_ID}" --vpc-security-group-ids "${RESTORE_RDS_SECURITY_GROUP}" > /dev/null
        fi

        info "Changed security groups of ${INSTANCE_ID} to ${RESTORE_RDS_SECURITY_GROUP}"
    fi
}

function validate_rds_snapshot {
    SNAPSHOT_ID="$1"

    aws rds describe-db-snapshots --db-snapshot-identifier ${SNAPSHOT_ID} > /dev/null
    if [ $? != 0 ]; then
        error "Could not find snapshot ${SNAPSHOT_ID} in region ${AWS_REGION}"

        print "Available snapshots:"
        aws rds describe-db-snapshots

        bail "If the snapshot was created in a region other than ${AWS_REGION} please copy the snapshot before restoring ${PRODUCT}"
    fi
}