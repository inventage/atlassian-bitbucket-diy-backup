# -------------------------------------------------------------------------------------
# Utilities used for AWS backup and restore
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
SNAPSHOT_DEVICE_TAG_KEY="Device"

# Used for cleaning up the EBS volume snapshots created as part of a failed/incomplete backup
declare -a CREATED_EBS_SNAPSHOTS

# Create a snapshot of an EBS volume
#
# volume_id = The volume to snapshot
# description = The description of the snapshot
# device_name = The device containing the volume
#
function snapshot_ebs_volume {
    local volume_id="$1"
    local description="$2"
    local device_name="$3"

    # Bail after 10 Minutes
    local max_wait_time=600
    local end_time=$((SECONDS + max_wait_time))

    while [ $SECONDS -lt ${end_time} ]; do
        local create_snapshot_response=$(run aws ec2 create-snapshot --volume-id "${volume_id}" --description "${description}")

        if [ "${create_snapshot_response}" = *"SnapshotCreationPerVolumeRateExceeded"* ]; then
            debug "Snapshot creation per volume rate exceeded. AWS returned: ${create_snapshot_response}"
        else
            local ebs_snapshot_id=$(echo "${create_snapshot_response}" | jq -r '.SnapshotId')

            if [ -z "${ebs_snapshot_id}" ] || [ "${ebs_snapshot_id}" = "null" ]; then
                error "Could not find 'SnapshotId' in response '${create_snapshot_response}'"
                bail "Unable to create EBS snapshot of volume '${volume_id}'"
            else
                break
            fi
        fi
        sleep 10
    done

    if [ -n "${AWS_ADDITIONAL_TAGS}" ]; then
        comma=', '
    fi
    local aws_tags="[{\"Key\":\"${SNAPSHOT_TAG_KEY}\",\"Value\":\"${SNAPSHOT_TAG_VALUE}\"}, \
        {\"Key\":\"${SNAPSHOT_DEVICE_TAG_KEY}\",\"Value\":\"${device_name}\"}${comma}${AWS_ADDITIONAL_TAGS}]"

    run aws ec2 create-tags --resources "${ebs_snapshot_id}" --tags "$aws_tags" > /dev/null
    debug "Tagged EBS snapshot '${ebs_snapshot_id}' with '${aws_tags}'"

    CREATED_EBS_SNAPSHOTS+=("${ebs_snapshot_id}")
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
    if [ "io1" = "${volume_type}" ] && [ -n "${provisioned_iops}" ]; then
        optional_args="--iops ${provisioned_iops}"
    fi

    local create_volume_response=$(run aws ec2 create-volume --snapshot "${snapshot_id}"\
        --availability-zone "${AWS_AVAILABILITY_ZONE}" --volume-type "${volume_type}" "${optional_args}")

    local volume_id=$(echo "${create_volume_response}" | jq -r '.VolumeId')
    if [ -z "${volume_id}" ] || [ "${volume_id}" = "null" ]; then
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

# Detach a currently attached EBS volume
#
# volume_id = The volume id to detach
#
function detach_volume {
    local volume_id="$1"
    run aws ec2 detach-volume --volume-id "${volume_id}" > /dev/null
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
    local end_time=$((SECONDS + max_wait_time))

    local attachment_state='attaching'
    while [ $SECONDS -lt ${end_time} ]; do
        # aws ec2 wait volume-in-use ${VOLUME_ID} is not enough.
        # A volume state can be 'in-use' while its attachment state is still 'attaching'
        # If the volume is not fully attach we cannot issue a mount command for it
        local volume_description=$(run aws ec2 describe-volumes --volume-ids "${volume_id}")

        attachment_state=$(echo "${volume_description}" | jq -r '.Volumes[0].Attachments[0].State')
        if [ -z "${attachment_state}" ] || [ "${attachment_state}" = "null" ]; then
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

# Remount the previously mounted ebs volumes
function remount_ebs_volumes {
    remove_cleanup_routine remount_ebs_volumes

    case ${FILESYSTEM_TYPE} in
    zfs)
        run sudo zpool import tank
        run sudo zfs mount -a
        run sudo zfs share -a
        ;;
    *)
        for volume in "${EBS_VOLUME_MOUNT_POINT_AND_DEVICE_NAMES[@]}"; do
            local mount_point="$(echo "${volume}" | cut -d ":" -f1)"
            local device_name="$(echo "${volume}" | cut -d ":" -f2)"
            run sudo mount "${device_name}" "${mount_point}"
        done

        # Start up NFS daemon and export via NFS
        run sudo service nfs start
        run sudo exportfs -ar
        ;;
    esac
}

# Unmount the currently mounted ebs volumes
function unmount_ebs_volumes {
    case ${FILESYSTEM_TYPE} in
    zfs)
        local shared=
        for fs_name in "${ZFS_FILESYSTEM_NAMES[@]}"; do
            shared=$(run sudo zfs get -o value -H sharenfs "${fs_name}")
            if [ "${shared}" = "on" ]; then
                run sudo zfs unshare "${fs_name}"
            fi
            run sudo zfs unmount "${fs_name}"
        done
        run sudo zpool export tank
        ;;
    *)
        # Un-export via NFS and stop the NFS daemon
        run sudo exportfs -au
        run sudo service nfs stop

        # Unmount each EBS volume
        for volume in "${EBS_VOLUME_MOUNT_POINT_AND_DEVICE_NAMES[@]}"; do
            local mount_point="$(echo "${volume}" | cut -d ":" -f1)"
            run sudo umount "${mount_point}"
        done
        ;;
    esac

    add_cleanup_routine remount_ebs_volumes
}

# Validate the existence of a EBS snapshot
#
# snapshot_tag = The tag used to retrieve the EBS snapshot ID
# device_name = The device to retrieve an EBS snapshot for
#
function retrieve_ebs_snapshot_id {
    local snapshot_tag="$1"
    local device_name="$2"

    local snapshot_description=$(run aws ec2 describe-snapshots --filters Name=tag:${SNAPSHOT_TAG_KEY},Values="${snapshot_tag}" \
        Name=tag:${SNAPSHOT_DEVICE_TAG_KEY},Values="${device_name}")

    local snapshot_id=$(echo "${snapshot_description}" | jq -r '.Snapshots[0]?.SnapshotId')
    if [ -z "${snapshot_id}" ] || [ "${snapshot_id}" = "null" ]; then
        error "Could not find a 'Snapshot' with 'SnapshotId' in response '${snapshot_description}'"
        # Get the list of available snapshot tags to assist with selecting a valid one
        list_available_ebs_snapshots
        bail "Please select an available EBS restore point"
    fi
    echo "${snapshot_id}"
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
    if [ -z "${ebs_volume}" ] || [ "${ebs_volume}" = "null" ]; then
        error "Could not find 'Volume' with 'VolumeId' in response '${volume_description}'"
        bail "Unable to retrieve volume information for device '${device_name}'"
    fi

    echo "${ebs_volume}"
}

# List available EBS restore points
function list_available_ebs_snapshots {
    local available_ebs_snapshots=$(run aws ec2 describe-snapshots \
        --filters Name=tag-key,Values="Name" Name=tag-value,Values="${SNAPSHOT_TAG_PREFIX}*"\
        | jq -r ".Snapshots[].Tags[] | select(.Key == \"Name\") | .Value" | sort -ru)
    if [ -z "${available_ebs_snapshots}" -o "${available_ebs_snapshots}" = "null" ]; then
        error "Could not find 'Snapshots' with 'Tags' with 'Value' in response '${snapshot_description}'"
        bail "Unable to retrieve list of available EBS snapshots"
    fi

    print "Available EBS restore points:"
    print "${available_ebs_snapshots}"
}


# List all EBS snapshots older than the most recent ${KEEP_BACKUPS}
#
# region = The AWS region to list snapshots from
# device_name = The device to list snapshots for
#
function list_old_ebs_snapshot_ids {
    local region=$1
    local device_name=$2
    run aws ec2 describe-snapshots --region="${region}" --filters "Name=tag:Name,Values=${SNAPSHOT_TAG_PREFIX}*" \
        "Name=tag:${SNAPSHOT_DEVICE_TAG_KEY},Values=${device_name}" | \
        jq -r ".Snapshots | sort_by(.StartTime) | reverse | .[${KEEP_BACKUPS}:] | map(.SnapshotId)[]"
}

# Returns "true" if Aurora cluster, "false" otherwise
#
function is_aurora {
    if [ -n "${IS_AURORA}" ]; then
        print "true"
    else
        print "false"
    fi
}
