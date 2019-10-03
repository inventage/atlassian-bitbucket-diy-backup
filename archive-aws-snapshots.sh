# -------------------------------------------------------------------------------------
# Functions implementing archiving of backups and copy to offsite location for AWS snapshots.
# AWS snapshots reside in AWS and are not archived in this implementation.
#
# You can optionally set BACKUP_DEST_REGION to copy every snapshot to another AWS region,
# for example, as part of a disaster recovery plan.
#
# Additionally, you can also set the variables BACKUP_DEST_AWS_ACCOUNT_ID and BACKUP_DEST_AWS_ROLE to share every
# snapshot with another AWS account.
# -------------------------------------------------------------------------------------

check_command "aws"
check_command "jq"

source "${SCRIPT_DIR}/aws-common.sh"

if [ "$(is_aurora)" ]; then
    source "${SCRIPT_DIR}/aws-rds-aurora-helper.sh"
else
    source "${SCRIPT_DIR}/aws-rds-non-aurora-helper.sh"
fi


function archive_backup {
    # AWS snapshots reside in AWS and do not need to be archived.

    # Optionally copy/share the EBS snapshot to another region and/or account.
    # This is useful to retain a cross region/account copy of the backup.
    if [ "${BACKUP_DISK_TYPE}" = "amazon-ebs" ] && [ -n "${BACKUP_DEST_REGION}" ]; then
        for volume in "${EBS_VOLUME_MOUNT_POINT_AND_DEVICE_NAMES[@]}"; do
            local device_name="$(echo "${volume}" | cut -d ":" -f2)"
            local backup_ebs_snapshot_id=$(run aws ec2 describe-snapshots --filters Name=tag-key,Values="${SNAPSHOT_TAG_KEY}" \
                Name=tag-value,Values="${SNAPSHOT_TAG_VALUE}" Name=tag:"${SNAPSHOT_DEVICE_TAG_KEY}",Values="${device_name}" \
                --query 'Snapshots[0].SnapshotId' --output text)

            if [ -n "${BACKUP_DEST_AWS_ACCOUNT_ID}" ] && [ -n "${BACKUP_DEST_AWS_ROLE}" ]; then
                # Copy to BACKUP_DEST_REGION & share with BACKUP_DEST_AWS_ACCOUNT_ID
                copy_and_share_ebs_snapshot "${backup_ebs_snapshot_id}" "${AWS_REGION}" "${device_name}"
            else
                # Copy EBS snapshot to BACKUP_DEST_REGION
                copy_ebs_snapshot "${backup_ebs_snapshot_id}" "${AWS_REGION}" "${device_name}"
            fi
        done
    fi

    # Optionally copy/share the RDS snapshot to another region and/or account.
    if [ "${BACKUP_DATABASE_TYPE}" = "amazon-rds" ] && [ -n "${BACKUP_DEST_REGION}" ]; then
        local backup_rds_snapshot_id=$(get_rds_snapshot_id_from_tag "${SNAPSHOT_TAG_VALUE}")

        if [ -n "${BACKUP_DEST_AWS_ACCOUNT_ID}" ] && [ -n "${BACKUP_DEST_AWS_ROLE}" ]; then
            # Copy to BACKUP_DEST_REGION & share with BACKUP_DEST_AWS_ACCOUNT_ID
            share_and_copy_rds_snapshot "${backup_rds_snapshot_id}"
        else
            # Copy RDS snapshot to BACKUP_DEST_REGION
            copy_rds_snapshot "${backup_rds_snapshot_id}"
        fi
    fi
}

function prepare_restore_archive {
    # AWS snapshots reside in AWS and do not need any un-archiving.
    no_op
}

function restore_archive {
    # AWS snapshots reside in AWS and do not need any un-archiving.
    no_op
}

function cleanup_old_archives {
    if [ "${KEEP_BACKUPS}" -gt 0 ]; then
        # If necessary, cleanup off-site snapshots
        if [ -n "${BACKUP_DEST_REGION}" ]; then
            if [ -n "${BACKUP_DEST_AWS_ACCOUNT_ID}" -a -n "${BACKUP_DEST_AWS_ROLE}" ]; then
                # Cleanup snapshots in BACKUP_DEST_AWS_ACCOUNT_ID
                if [ "${BACKUP_DATABASE_TYPE}" = "amazon-rds" ]; then
                    cleanup_old_offsite_rds_snapshots_in_backup_account
                fi
                if [ "${BACKUP_DISK_TYPE}" = "amazon-ebs" ]; then
                    cleanup_old_offsite_ebs_snapshots_in_backup_account
                fi
            fi

            # Cleanup snapshots in BACKUP_DEST_REGION
            if [ "${BACKUP_DATABASE_TYPE}" = "rds" ]; then
                cleanup_old_offsite_rds_snapshots
            fi
            if [ "${BACKUP_DISK_TYPE}" = "amazon-ebs" ]; then
                cleanup_old_offsite_ebs_snapshots
            fi
        fi
    fi
}

######################################################################################################################
# Functions implementing off-site copying of snapshots to ${BACKUP_DEST_REGION}

function copy_ebs_snapshot {
    local source_ebs_snapshot_id="$1"
    local source_region="$2"
    local device_name="$3"

    debug "Attempting to copy EBS snapshot '${source_ebs_snapshot_id}' to '${source_region}'"

    info "Waiting for EBS snapshot '${source_ebs_snapshot_id}' to become available in '${source_region}' \
        before copying to '${BACKUP_DEST_REGION}'"
    run aws ec2 wait snapshot-completed --region "${source_region}" --snapshot-ids "${source_ebs_snapshot_id}"

    # Copy snapshot to BACKUP_DEST_REGION
    local result=$(run aws ec2 copy-snapshot --region "${BACKUP_DEST_REGION}" --source-region "${source_region}" \
         --source-snapshot-id "${source_ebs_snapshot_id}")
    local dest_snapshot_id=$(echo "${result}" | jq -r '.SnapshotId')

    if [ -z "${dest_snapshot_id}" ]; then
        bail "Failed to retrieve copied EBS snapshot ID. Result: '${result}'"
    fi

    info "Copied EBS snapshot '${source_ebs_snapshot_id}' from '${source_region}' to '${BACKUP_DEST_REGION}'." \
        "Snapshot copy ID: '${dest_snapshot_id}'"

    info "Waiting for EBS snapshot '${dest_snapshot_id}' to become available in '${BACKUP_DEST_REGION}' before tagging"
    run aws ec2 wait snapshot-completed --region "${BACKUP_DEST_REGION}" --snapshot-ids "${dest_snapshot_id}"

    if [ -n "${AWS_ADDITIONAL_TAGS}" ]; then
        comma=', '
    fi
    local aws_tags="[{\"Key\":\"${SNAPSHOT_TAG_KEY}\",\"Value\":\"${SNAPSHOT_TAG_VALUE}\"}, \
        {\"Key\":\"${SNAPSHOT_DEVICE_TAG_KEY}\",\"Value\":\"${device_name}\"}${comma}${AWS_ADDITIONAL_TAGS}]"

    # Add tags to copied snapshot
    run aws ec2 create-tags --region "${BACKUP_DEST_REGION}" --resources "${dest_snapshot_id}" --tags "${aws_tags}"
    info "Tagged EBS snapshot '${dest_snapshot_id}' with '${aws_tags}'"
}

function copy_rds_snapshot {
    local source_rds_snapshot_id="$1"

    copy_rds_snapshot_to_region "${source_rds_snapshot_id}" "${BACKUP_DEST_REGION}"

    if [ -n "${AWS_ADDITIONAL_TAGS}" ]; then
        comma=', '
    fi
    local aws_tags="[{\"Key\":\"${SNAPSHOT_TAG_KEY}\",\"Value\":\"${SNAPSHOT_TAG_VALUE}\"}${comma}${AWS_ADDITIONAL_TAGS}]"

    local rds_snapshot_arn="arn:aws:rds:${BACKUP_DEST_REGION}:${AWS_ACCOUNT_ID}:snapshot:${source_rds_snapshot_id}"
    run aws rds --region "${BACKUP_DEST_REGION}" add-tags-to-resource --resource-name "${rds_snapshot_arn}" --tags "${aws_tags}"
    debug "Tagged RDS snapshot '${rds_snapshot_id}' with '${aws_tags}'"
}

function cleanup_old_offsite_ebs_snapshots {
    # Delete old EBS snapshots in region BACKUP_DEST_REGION
    for volume in "${EBS_VOLUME_MOUNT_POINT_AND_DEVICE_NAMES[@]}"; do
        local device_name="$(echo "${volume}" | cut -d ":" -f2)"
        for ebs_snapshot_id in $(list_old_ebs_snapshot_ids ${BACKUP_DEST_REGION} ${device_name}); do
            info "Deleting old cross-region EBS snapshot '${ebs_snapshot_id}' in ${BACKUP_DEST_REGION}"
            run aws ec2 delete-snapshot --region "${BACKUP_DEST_REGION}" --snapshot-id "${ebs_snapshot_id}" > /dev/null
        done
    done
}

function cleanup_old_offsite_rds_snapshots {
    # Delete old RDS snapshots in BACKUP_DEST_REGION
    for rds_snapshot_id in $(list_old_rds_snapshot_ids "${BACKUP_DEST_REGION}"); do
        info "Deleting old cross-region RDS snapshot '${rds_snapshot_id}' in ${BACKUP_DEST_REGION}"
        delete_rds_snapshot "${rds_snapshot_id}" "${BACKUP_DEST_REGION}"
    done
}

##################################################################################################################
# Functions implementing off-site copying of snapshots to ${BACKUP_DEST_REGION} in AWS account ${BACKUP_DEST_AWS_ACCOUNT_ID}

function copy_and_share_ebs_snapshot {
    local source_ebs_snapshot_id="$1"
    local source_region="$2"
    local device_name="$3"

    info "Waiting for EBS snapshot '${source_ebs_snapshot_id}' to become available in '${source_region}'" \
        "before copying to '${BACKUP_DEST_REGION}'"
    run aws ec2 wait snapshot-completed --region "${source_region}" --snapshot-ids "${source_ebs_snapshot_id}"

    # Copy snapshot to BACKUP_DEST_REGION
    local dest_snapshot_id=$(run aws ec2 copy-snapshot --region "${BACKUP_DEST_REGION}" --source-region "${source_region}" \
        --source-snapshot-id "${source_ebs_snapshot_id}" | jq -r '.SnapshotId')
    info "Copied EBS snapshot '${source_ebs_snapshot_id}' from '${source_region}' to '${BACKUP_DEST_REGION}'. \
        Snapshot copy ID: '${dest_snapshot_id}'"

    info "Waiting for EBS snapshot '${dest_snapshot_id}' to become available in '${BACKUP_DEST_REGION}' " \
        "before modifying permissions"
    run aws ec2 wait snapshot-completed --region "${BACKUP_DEST_REGION}" --snapshot-ids "${dest_snapshot_id}"

    # Give BACKUP_DEST_AWS_ACCOUNT_ID permissions on the copied snapshot
    run aws ec2 modify-snapshot-attribute --snapshot-id "${dest_snapshot_id}" --region "${BACKUP_DEST_REGION}" \
        --attribute createVolumePermission --operation-type add --user-ids "${BACKUP_DEST_AWS_ACCOUNT_ID}"
    info "Granted create volume permission on '${dest_snapshot_id}' for account: '${BACKUP_DEST_AWS_ACCOUNT_ID}'"

    info "Waiting for EBS snapshot '${dest_snapshot_id}' to become available in '${BACKUP_DEST_REGION}' before tagging"
    run aws ec2 wait snapshot-completed --region "${BACKUP_DEST_REGION}" --snapshot-ids "${dest_snapshot_id}"

    # Tag intermediate snapshot
    if [ -n "${AWS_ADDITIONAL_TAGS}" ]; then
        comma=', '
    fi
    local aws_tags="[{\"Key\":\"${SNAPSHOT_TAG_KEY}\",\"Value\":\"${SNAPSHOT_TAG_VALUE}\"}, \
        {\"Key\":\"${SNAPSHOT_DEVICE_TAG_KEY}\",\"Value\":\"${device_name}\"}${comma}${AWS_ADDITIONAL_TAGS}]"
    run aws ec2 create-tags --region "${BACKUP_DEST_REGION}" --resources "${dest_snapshot_id}" --tags "$aws_tags"

    # Assume destination AWS account role
    info "Assuming AWS role '${BACKUP_DEST_AWS_ROLE}' to tag copied snapshot"
    local credentials=$(run aws sts assume-role --role-arn "${BACKUP_DEST_AWS_ROLE}" \
        --role-session-name "BitbucketServerDIYBackup")
    local access_key_id=$(echo "${credentials}" | jq -r .Credentials.AccessKeyId)
    local secret_access_key=$(echo "${credentials}" | jq -r .Credentials.SecretAccessKey)
    local session_token=$(echo "${credentials}" | jq -r .Credentials.SessionToken)

    # Add tags to copied snapshot in destination AWS account, used to find EBS & RDS snapshot pairs for restoration
    AWS_ACCESS_KEY_ID="${access_key_id}" AWS_SECRET_ACCESS_KEY="${secret_access_key}" \
        AWS_SESSION_TOKEN="${session_token}" run aws ec2 create-tags --region "${BACKUP_DEST_REGION}" \
        --resources "${dest_snapshot_id}" --tags "$aws_tags"

    info "Tagged EBS snapshot ${dest_snapshot_id} with: ${aws_tags}"
}

function share_and_copy_rds_snapshot {
    local rds_snapshot_id="$1"

    info "Waiting for RDS snapshot copy '${rds_snapshot_id}' to become available before giving AWS account: \
        '${BACKUP_DEST_AWS_ACCOUNT_ID}' permissions."
    wait_for_rds_snapshot "${rds_snapshot_id}"

    # Give permission to BACKUP_DEST_AWS_ACCOUNT_ID to restore this snapshot
    permit_account_to_restore_rds_snapshot "${BACKUP_DEST_AWS_ACCOUNT_ID}" "${rds_snapshot_id}"

    # Assume BACKUP_DEST_AWS_ROLE
    local credentials=$(run aws sts assume-role --role-arn "${BACKUP_DEST_AWS_ROLE}" \
        --role-session-name "BitbucketServerDIYBackup")
    local aws_access_key_id=$(echo "${credentials}" | jq -r .Credentials.AccessKeyId)
    local aws_secret_access_key=$(echo "${credentials}" | jq -r .Credentials.SecretAccessKey)
    local aws_session_token=$(echo "${credentials}" | jq -r .Credentials.SessionToken)

    copy_rds_snapshot_to_region "${rds_snapshot_id}" "${BACKUP_DEST_REGION}" "${aws_access_key_id}" "${aws_secret_access_key}" "${aws_session_token}"

    # Tag snapshot in the target account
    if [ -n "${AWS_ADDITIONAL_TAGS}" ]; then
        comma=', '
    fi
    local aws_tags="[{\"Key\":\"${SNAPSHOT_TAG_KEY}\",\"Value\":\"${SNAPSHOT_TAG_VALUE}\"}${comma}${AWS_ADDITIONAL_TAGS}]"
    local rds_snapshot_arn="arn:aws:rds:${BACKUP_DEST_REGION}:${BACKUP_DEST_AWS_ACCOUNT_ID}:snapshot:${rds_snapshot_id}"

    AWS_ACCESS_KEY_ID="${aws_access_key_id}" AWS_SECRET_ACCESS_KEY="${aws_secret_access_key}" \
        AWS_SESSION_TOKEN="${aws_session_token}" run aws --region "${BACKUP_DEST_REGION}" rds add-tags-to-resource \
          --resource-name "${rds_snapshot_arn}" --tags "${aws_tags}"
    debug "Tagged RDS snapshot '${rds_snapshot_arn}' with '${aws_tags}'"
}

function cleanup_old_offsite_ebs_snapshots_in_backup_account {
    # Assume BACKUP_DEST_AWS_ROLE
    local credentials=$(run aws sts assume-role --role-arn "${BACKUP_DEST_AWS_ROLE}" \
        --role-session-name "BitbucketServerDIYBackup")
    local aws_access_key_id=$(echo "${credentials}" | jq -r .Credentials.AccessKeyId)
    local aws_secret_access_key=$(echo "${credentials}" | jq -r .Credentials.SecretAccessKey)
    local aws_session_token=$(echo "${credentials}" | jq -r .Credentials.SessionToken)

    for volume in "${EBS_VOLUME_MOUNT_POINT_AND_DEVICE_NAMES[@]}"; do
        local device_name="$(echo "${volume}" | cut -d ":" -f2)"

        # Query for EBS snapshots using the assumed credentials
        local old_backup_account_ebs_snapshots="$(AWS_ACCESS_KEY_ID="${aws_access_key_id}" \
            AWS_SECRET_ACCESS_KEY="${aws_secret_access_key}" AWS_SESSION_TOKEN="${aws_session_token}" \
            run aws ec2 describe-snapshots --filters "Name=tag:Name,Values=${SNAPSHOT_TAG_PREFIX}*" \
            "Name=tag:${SNAPSHOT_DEVICE_TAG_KEY},Values=${device_name}" | \
            jq -r ".Snapshots | sort_by(.StartTime) | reverse | .[${KEEP_BACKUPS}:] | map(.SnapshotId)[]")"

        # Delete old EBS snapshots from BACKUP_DEST_AWS_ACCOUNT_ID in region BACKUP_DEST_REGION
        for ebs_snapshot_id in ${old_backup_account_ebs_snapshots}; do
            info "Deleting old cross-account EBS snapshot '${ebs_snapshot_id}' of device '${device_name}'"
            AWS_ACCESS_KEY_ID="${aws_access_key_id}" AWS_SECRET_ACCESS_KEY="${aws_secret_access_key}" \
                AWS_SESSION_TOKEN="${aws_session_token}" run aws ec2 delete-snapshot --region "${BACKUP_DEST_REGION}" \
                --snapshot-id "${ebs_snapshot_id}" > /dev/null
        done
    done
}

function cleanup_old_offsite_rds_snapshots_in_backup_account {
    # Assume BACKUP_DEST_AWS_ROLE
    local credentials=$(run aws sts assume-role --role-arn "${BACKUP_DEST_AWS_ROLE}" \
        --role-session-name "BitbucketServerDIYBackup")
    local aws_access_key_id=$(echo "${credentials}" | jq -r .Credentials.AccessKeyId)
    local aws_secret_access_key=$(echo "${credentials}" | jq -r .Credentials.SecretAccessKey)
    local aws_session_token=$(echo "${credentials}" | jq -r .Credentials.SessionToken)

    # Query for RDS snapshots using the assumed credentials
    local old_backup_account_rds_snapshots=$(list_old_rds_snapshots "${BACKUP_DEST_REGION}" "${aws_access_key_id}" "${aws_secret_access_key}" "${aws_session_token}")

    # Delete old RDS snapshots from BACKUP_DEST_AWS_ACCOUNT_ID in region BACKUP_DEST_REGION
    for rds_snapshot_id in ${old_backup_account_rds_snapshots}; do
        delete_rds_snapshot "${rds_snapshot_id}" "${BACKUP_DEST_REGION}" "${aws_access_key_id}" "${aws_secret_access_key}" "${aws_session_token}"
    done
}