#!/bin/bash

# Functions implementing archiving of backups and copy to offsite location for AWS snapshots.
# AWS snapshots reside in AWS and are not archived in this implementation.
#
# You can optionally set BACKUP_DEST_REGION to copy every snapshot to another AWS region,
# for example, as part of a disaster recovery plan.
#
# Additionally, you can also set the variables BACKUP_DEST_AWS_ACCOUNT_ID and BACKUP_DEST_AWS_ROLE to share every
# snapshot with another AWS account.

function archive_backup {
    # AWS snapshots reside in AWS and do not need to be archived.

    # Optionally copy/share the EBS snapshot to another region and/or account.
    # This is useful to retain a cross region/account copy of the backup.
    if [ -n "${BACKUP_DEST_REGION}" ]; then
        local backup_ebs_snapshot_id=$(run aws ec2 describe-snapshots --filters Name=tag-key,Values="${SNAPSHOT_TAG_KEY}" \
            Name=tag-value,Values="${SNAPSHOT_TAG_VALUE}" --query 'Snapshots[0].SnapshotId' --output text)

        if [ -n "${BACKUP_DEST_AWS_ACCOUNT_ID}" -a -n "${BACKUP_DEST_AWS_ROLE}" ]; then
            # Copy to BACKUP_DEST_REGION & share with BACKUP_DEST_AWS_ACCOUNT_ID
            copy_and_share_ebs_snapshot ${backup_ebs_snapshot_id} ${AWS_REGION}
        else
            # Copy EBS snapshot to BACKUP_DEST_REGION
            copy_ebs_snapshot ${backup_ebs_snapshot_id} ${AWS_REGION}
        fi
    fi

    if [ -n "${BACKUP_DEST_REGION}" ]; then
        local backup_rds_snapshot_id=$(run aws rds describe-db-snapshots --db-snapshot-identifier "${SNAPSHOT_TAG_VALUE}" \
            --query 'DBSnapshots[*].DBSnapshotIdentifier' --output text)

        if [ -n "${BACKUP_DEST_AWS_ACCOUNT_ID}" -a -n "${BACKUP_DEST_AWS_ROLE}" ]; then
            # Copy to BACKUP_DEST_REGION & share with BACKUP_DEST_AWS_ACCOUNT_ID
            share_and_copy_rds_snapshot "${backup_rds_snapshot_id}"
        else
            # Copy RDS snapshot to BACKUP_DEST_REGION
            copy_rds_snapshot "${backup_rds_snapshot_id}"
        fi
    fi
}

function prepare_restore_archive {
    local snapshot_tag="${1}"

    if [ -z ${snapshot_tag} ]; then
        info "Usage: $0 <snapshot-tag>"

        list_available_ebs_snapshot_tags

        exit 99
    fi

    BACKUP_HOME_DIRECTORY_VOLUME_ID="$(find_attached_ebs_volume "${HOME_DIRECTORY_DEVICE_NAME}")"

    RESTORE_HOME_DIRECTORY_SNAPSHOT_ID=
    validate_ebs_snapshot "${snapshot_tag}" RESTORE_HOME_DIRECTORY_SNAPSHOT_ID

    validate_rds_snapshot "${snapshot_tag}"

    RESTORE_RDS_SNAPSHOT_ID="${snapshot_tag}"
}

function restore_archive {
    # AWS snapshots reside in AWS and do not need any un-archiving.
    no_op
}

function cleanup_old_archives {
    if [ "${KEEP_BACKUPS}" -gt 0 ]; then
        if [ "${BACKUP_DATABASE_TYPE}" = "rds" ]; then
            for snapshot_id in $(list_old_rds_snapshot_ids ${AWS_REGION}); do
                run aws rds delete-db-snapshot --db-snapshot-identifier "${snapshot_id}" > /dev/null
            done
        fi
        if [ "${BACKUP_HOME_TYPE}" = "ebs-home" ]; then
            for snapshot_id in $(list_old_ebs_snapshot_ids); do
                delete_ebs_snapshot "${snapshot_id}"
            done
        fi

        if [ -n "${BACKUP_DEST_REGION}" ]; then
            if [ "${BACKUP_DATABASE_TYPE}" = "rds" ]; then
                cleanup_old_offsite_rds_snapshots
            fi
            if [ "${BACKUP_HOME_TYPE}" = "ebs-home" ]; then
                cleanup_old_offsite_ebs_snapshots
            fi
        fi
    fi
}

function cleanup_old_offsite_rds_snapshots {
    if [ -n "${BACKUP_DEST_AWS_ACCOUNT_ID}" -a -n "${BACKUP_DEST_AWS_ROLE}" ]; then
        # Assume BACKUP_DEST_AWS_ROLE
        local credentials=$(run aws sts assume-role --role-arn "${BACKUP_DEST_AWS_ROLE}" \
            --role-session-name "BitbucketServerDIYBackup")
        local aws_access_key_id=$(echo ${credentials} | jq -r .Credentials.AccessKeyId)
        local aws_secret_access_key=$(echo ${credentials} | jq -r .Credentials.SecretAccessKey)
        local aws_session_token=$(echo ${credentials} | jq -r .Credentials.SessionToken)

        local old_off_site_snapshots=$(AWS_ACCESS_KEY_ID="${aws_access_key_id}" AWS_SECRET_ACCESS_KEY="${aws_secret_access_key}" \
            AWS_SESSION_TOKEN="${aws_session_token}" run aws rds describe-db-snapshots --region "${BACKUP_DEST_REGION}" \
            --snapshot-type manual | jq -r ".DBSnapshots | map(select(.DBSnapshotIdentifier | \
            startswith(\"${SNAPSHOT_TAG_PREFIX}\"))) | sort_by(.SnapshotCreateTime) | reverse | .[${KEEP_BACKUPS}:] | \
            map(.DBSnapshotIdentifier)[]")

        # Delete old RDS snapshots from BACKUP_DEST_AWS_ACCOUNT_ID in region BACKUP_DEST_REGION
        for snapshot_id in ${old_off_site_snapshots}; do
            info "Deleting old cross-account RDS snapshot '${snapshot_id}'"
            AWS_ACCESS_KEY_ID="${aws_access_key_id}" AWS_SECRET_ACCESS_KEY="${aws_secret_access_key}" \
                AWS_SESSION_TOKEN="${aws_session_token}" run aws rds delete-db-snapshot --region "${BACKUP_DEST_REGION}" \
                --db-snapshot-identifier "${snapshot_id}" > /dev/null
        done
    else
        # Delete old RDS snapshots in BACKUP_DEST_REGION
        for snapshot_id in $(list_old_rds_snapshot_ids ${AWS_REGION}); do
            info "Deleting old cross-region RDS snapshot '${snapshot_id}'"
            run aws rds delete-db-snapshot --db-snapshot-identifier "${snapshot_id}" > /dev/null
        done
    fi
}

function cleanup_old_offsite_ebs_snapshots {
    # TODO: Fraser implement me!
    echo "Implement cleanup_old_offsite_ebs_snapshots"
}

function share_and_copy_rds_snapshot {
    local rds_snapshot_id="$1"
    local source_aws_account_id=$(get_aws_account_id)

    info "Waiting for RDS snapshot copy '${rds_snapshot_id}' to become available before giving AWS account: \
        '${BACKUP_DEST_AWS_ACCOUNT_ID}' permissions."
    run aws rds wait db-snapshot-completed --db-snapshot-identifier "${rds_snapshot_id}"

    # Give permission to BACKUP_DEST_AWS_ACCOUNT_ID
    run aws rds modify-db-snapshot-attribute --db-snapshot-identifier "${rds_snapshot_id}" --attribute-name restore \
        --values-to-add "${BACKUP_DEST_AWS_ACCOUNT_ID}" > /dev/null
    info "Granted permissions on RDS snapshot '${rds_snapshot_id}' for AWS account: '${BACKUP_DEST_AWS_ACCOUNT_ID}'"

    # Assume BACKUP_DEST_AWS_ROLE
    local credentials=$(run aws sts assume-role --role-arn "${BACKUP_DEST_AWS_ROLE}" \
        --role-session-name "BitbucketServerDIYBackup")
    local aws_access_key_id=$(echo ${credentials} | jq -r .Credentials.AccessKeyId)
    local aws_secret_access_key=$(echo ${credentials} | jq -r .Credentials.SecretAccessKey)
    local aws_session_token=$(echo ${credentials} | jq -r .Credentials.SessionToken)

    # Copy RDS snapshot to BACKUP_DEST_REGION in BACKUP_DEST_AWS_ACCOUNT_ID
    local source_rds_snapshot_arn="arn:aws:rds:${AWS_REGION}:${source_aws_account_id}:snapshot:${rds_snapshot_id}"
    AWS_ACCESS_KEY_ID="${aws_access_key_id}" AWS_SECRET_ACCESS_KEY="${aws_secret_access_key}" \
        AWS_SESSION_TOKEN="${aws_session_token}" run aws rds copy-db-snapshot --region "${BACKUP_DEST_REGION}" \
        --source-db-snapshot-identifier "${source_rds_snapshot_arn}" --target-db-snapshot-identifier "${rds_snapshot_id}" > /dev/null
    info "Copied RDS Snapshot '${source_rds_snapshot_arn}' as '${rds_snapshot_id}' to '${BACKUP_DEST_REGION}'"
}

function copy_rds_snapshot {
    local source_rds_snapshot_id="$1"
    local source_aws_account_id=$(get_aws_account_id)

    info "Waiting for RDS snapshot '${source_rds_snapshot_id}' to become available before copying to another region. \
        This could take some time."
    run aws rds wait db-snapshot-completed --db-snapshot-identifier "${source_rds_snapshot_id}"

    # Copy RDS snapshot to BACKUP_DEST_REGION
    local source_rds_snapshot_arn="arn:aws:rds:${AWS_REGION}:${source_aws_account_id}:snapshot:${source_rds_snapshot_id}"
    run aws rds copy-db-snapshot --region "${BACKUP_DEST_REGION}" --source-db-snapshot-identifier "${source_rds_snapshot_arn}" \
      --target-db-snapshot-identifier "${source_rds_snapshot_id}" > /dev/null
    info "Copied RDS Snapshot '${source_rds_snapshot_arn}' as '${source_rds_snapshot_id}' to '${BACKUP_DEST_REGION}'"
}

function copy_ebs_snapshot {
    local source_ebs_snapshot_id="$1"
    local source_region="$2"

    info "Waiting for EBS snapshot '${source_ebs_snapshot_id}' to become available in '${source_region}' \
        before copying to '${BACKUP_DEST_REGION}'"
    run aws ec2 wait snapshot-completed --region "${source_region}" --snapshot-ids "${source_ebs_snapshot_id}"

    # Copy snapshot to BACKUP_DEST_REGION
    local dest_snapshot_id=$(aws ec2 copy-snapshot --region "${BACKUP_DEST_REGION}" --source-region "${source_region}" \
         --source-snapshot-id "${source_ebs_snapshot_id}" | jq -r '.SnapshotId')
    info "Copied EBS snapshot '${source_ebs_snapshot_id}' from '${source_region}' to '${BACKUP_DEST_REGION}'. \
        Snapshot copy ID: '${dest_snapshot_id}'"

    info "Waiting for EBS snapshot '${dest_snapshot_id}' to become available in '${BACKUP_DEST_REGION}' before tagging"
    run aws ec2 wait snapshot-completed --region "${BACKUP_DEST_REGION}" --snapshot-ids "${dest_snapshot_id}"

    # Add tags to copied snapshot
    run aws ec2 create-tags --region "${BACKUP_DEST_REGION}" --resources "${dest_snapshot_id}" \
        --tags Key=Name,Value="${SNAPSHOT_TAG_VALUE}"
    info "Tagged EBS snapshot '${dest_snapshot_id}' with '{Name: ${SNAPSHOT_TAG_VALUE}}'"
}

function copy_and_share_ebs_snapshot {
    local source_ebs_snapshot_id="$1"
    local source_region="$2"

    info "Waiting for EBS snapshot '${source_ebs_snapshot_id}' to become available in '${source_region}' \
        before copying to '${BACKUP_DEST_REGION}'"
    run aws ec2 wait snapshot-completed --region "${source_region}" --snapshot-ids "${source_ebs_snapshot_id}"

    # Copy snapshot to BACKUP_DEST_REGION
    local dest_snapshot_id=$(run aws ec2 copy-snapshot --region "${BACKUP_DEST_REGION}" --source-region "${source_region}" \
        --source-snapshot-id "${source_ebs_snapshot_id}" | jq -r '.SnapshotId')
    info "Copied EBS snapshot '${source_ebs_snapshot_id}' from '${source_region}' to '${BACKUP_DEST_REGION}'. \
        Snapshot copy ID: '${dest_snapshot_id}'"

    info "Waiting for EBS snapshot '${dest_snapshot_id}' to become available in '${BACKUP_DEST_REGION}' before modifying permissions"
    run aws ec2 wait snapshot-completed --region "${BACKUP_DEST_REGION}" --snapshot-ids "${dest_snapshot_id}"

    # Give BACKUP_DEST_AWS_ACCOUNT_ID permissions on the copied snapshot
    run aws ec2 modify-snapshot-attribute --snapshot-id "${dest_snapshot_id}" --region "${BACKUP_DEST_REGION}" \
        --attribute createVolumePermission --operation-type add --user-ids "${BACKUP_DEST_AWS_ACCOUNT_ID}"
    info "Granted create volume permission on '${dest_snapshot_id}' for account: '${BACKUP_DEST_AWS_ACCOUNT_ID}'"

    info "Waiting for EBS snapshot '${dest_snapshot_id}' to become available in '${BACKUP_DEST_REGION}' before tagging"
    run aws ec2 wait snapshot-completed --region "${BACKUP_DEST_REGION}" --snapshot-ids "${dest_snapshot_id}"

    info "Assuming AWS role '${BACKUP_DEST_AWS_ROLE}' to tag copied snapshot"
    local credentials=$(run aws sts assume-role --role-arn "${BACKUP_DEST_AWS_ROLE}" \
        --role-session-name "BitbucketServerDIYBackup")
    local access_key_id=$(echo ${credentials} | jq -r .Credentials.AccessKeyId)
    local secret_access_key=$(echo ${credentials} | jq -r .Credentials.SecretAccessKey)
    local session_token=$(echo ${credentials} | jq -r .Credentials.SessionToken)

    # Add tag to copied snapshot, used to find EBS & RDS snapshot pairs for restoration
    AWS_ACCESS_KEY_ID="${access_key_id}" AWS_SECRET_ACCESS_KEY="${secret_access_key}" \
        AWS_SESSION_TOKEN="${session_token}" run aws ec2 create-tags --region "${BACKUP_DEST_REGION}" \
        --resources "${dest_snapshot_id}" --tags Key=Name,Value="${SNAPSHOT_TAG_VALUE}"

    info "Tagged EBS snapshot ${dest_snapshot_id} with {Name: ${SNAPSHOT_TAG_VALUE}}"
}