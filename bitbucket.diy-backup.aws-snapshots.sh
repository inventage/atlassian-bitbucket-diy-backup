#!/bin/bash

# Functions implementing archiving of backups and copy to offsite location for AWS snapshots.
# AWS snapshots reside in AWS and are not archived in this implementation.
#
# You can optionally set BACKUP_DEST_REGION and BACKUP_DEST_REGION to copy every snapshot to another AWS region,
# for example, as part of a disaster recovery plan.
#
# Additionally, you can also set the variables BACKUP_DEST_AWS_ACCOUNT_ID and BACKUP_DEST_AWS_ROLE to share every
# snapshot with another AWS account.

function bitbucket_backup_archive {
    # AWS snapshots reside in AWS and do not need to be archived.

    # Optionally copy/share the EBS snapshot to another region and/or account.
    # This is useful to retain a cross region/account copy of the backup.
    if [ -n "${BACKUP_DEST_REGION}" ]; then

        BACKUP_EBS_SNAPSHOT_ID=$(aws ec2 describe-snapshots --filters Name=tag-key,Values="${SNAPSHOT_TAG_KEY}" \
            Name=tag-value,Values="${SNAPSHOT_TAG_VALUE}" --query 'Snapshots[0].SnapshotId' --output text)

        if [ -n "${BACKUP_DEST_AWS_ACCOUNT_ID}" ] && [ -n "${BACKUP_DEST_AWS_ROLE}" ]; then
            # Copy to BACKUP_DEST_REGION & share with BACKUP_DEST_AWS_ACCOUNT_ID
            copy_and_share_ebs_snapshot ${BACKUP_EBS_SNAPSHOT_ID} ${AWS_REGION}
        else
            # Copy EBS snapshot to BACKUP_DEST_REGION
            copy_ebs_snapshot ${BACKUP_EBS_SNAPSHOT_ID} ${AWS_REGION}
        fi
    fi

    if [ -n "${BACKUP_DEST_REGION}" ]; then

        BACKUP_RDS_SNAPSHOT_ID=$(aws rds describe-db-snapshots --db-snapshot-identifier "${SNAPSHOT_TAG_VALUE}" \
            --query 'DBSnapshots[*].DBSnapshotIdentifier' --output text)

        if [ -n "${BACKUP_DEST_AWS_ACCOUNT_ID}" ] && [ -n "${BACKUP_DEST_AWS_ROLE}" ]; then
            # Copy to BACKUP_DEST_REGION & share with BACKUP_DEST_AWS_ACCOUNT_ID
            share_and_copy_rds_snapshot "${BACKUP_RDS_SNAPSHOT_ID}"
        else
            # Copy RDS snapshot to BACKUP_DEST_REGION
            copy_rds_snapshot "${BACKUP_RDS_SNAPSHOT_ID}"
        fi
    fi
}

function bitbucket_restore_archive {
    # AWS snapshots reside in AWS and do not need any un-archiving.
    no_op
}

function bitbucket_cleanup {
    bitbucket_cleanup_ebs_snapshots
    bitbucket_cleanup_rds_snapshots
}

function bitbucket_cleanup_ebs_snapshots {
    for snapshot_id in $(list_old_ebs_snapshot_ids); do
        info "Deleting old EBS snapshot ${snapshot_id}"
        delete_ebs_snapshot "${snapshot_id}"
    done

    if [ -n "${BACKUP_DEST_REGION}" ]; then
        cleanup_old_offsite_ebs_snapshots
    fi
}

function bitbucket_cleanup_rds_snapshots {
    if ! [ "${KEEP_BACKUPS}" -gt 0 ]; then
        info "Skipping cleanup of RDS snapshots"
        return
    fi

    # Delete old snapshots in source AWS account
    for snapshot_id in $(list_old_rds_snapshot_ids ${AWS_REGION}); do
        info "Deleting old RDS snapshot ${snapshot_id}"
        aws rds delete-db-snapshot --db-snapshot-identifier "${snapshot_id}" > /dev/null
    done

    if [ -n "${BACKUP_DEST_REGION}" ]; then
        cleanup_old_offsite_rds_snapshots
    fi
}

function cleanup_old_offsite_rds_snapshots {
    if [ -n "${BACKUP_DEST_AWS_ACCOUNT_ID}" ] && [ -n "${BACKUP_DEST_AWS_ROLE}" ]; then
        # Assume BACKUP_DEST_AWS_ROLE
        local creds=$(aws sts assume-role --role-arn ${BACKUP_DEST_AWS_ROLE} --role-session-name "BitbucketServerDIYBackup")
        local aws_access_key_id="$(echo $creds | jq -r .Credentials.AccessKeyId)"
        local aws_secret_access_key="$(echo $creds | jq -r .Credentials.SecretAccessKey)"
        local aws_session_token="$(echo $creds | jq -r .Credentials.SessionToken)"

        old_offsite_snapshots=$(AWS_ACCESS_KEY_ID=${aws_access_key_id} AWS_SECRET_ACCESS_KEY=${aws_secret_access_key} AWS_SESSION_TOKEN=${aws_session_token} \
            aws rds describe-db-snapshots --region ${BACKUP_DEST_REGION} --snapshot-type manual \
                | jq -r ".DBSnapshots | map(select(.DBSnapshotIdentifier | startswith(\"${SNAPSHOT_TAG_PREFIX}\"))) | sort_by(.SnapshotCreateTime) | reverse | .[${KEEP_BACKUPS}:] | map(.DBSnapshotIdentifier)[]")

        # Delete old RDS snapshots from BACKUP_DEST_AWS_ACCOUNT_ID in region BACKUP_DEST_REGION
        for snapshot_id in $old_offsite_snapshots; do
            info "Deleting old cross-account RDS snapshot ${snapshot_id}"
            AWS_ACCESS_KEY_ID=${aws_access_key_id} AWS_SECRET_ACCESS_KEY=${aws_secret_access_key} AWS_SESSION_TOKEN=${aws_session_token} \
                aws rds delete-db-snapshot --region ${BACKUP_DEST_REGION} --db-snapshot-identifier "${snapshot_id}" > /dev/null
        done
    else
        # Delete old RDS snapshots in BACKUP_DEST_REGION
        for snapshot_id in $(list_old_rds_snapshot_ids ${AWS_REGION}); do
            info "Deleting old cross-region RDS snapshot ${snapshot_id}"
            aws rds delete-db-snapshot --db-snapshot-identifier "${snapshot_id}" > /dev/null
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

    # Copy RDS snapshot to BACKUP_DEST_REGION in BACKUP_DEST_AWS_ACCOUNT_ID
    local source_rds_snapshot_arn="arn:aws:rds:${AWS_REGION}:${source_aws_account_id}:snapshot:${rds_snapshot_id}"
    AWS_ACCESS_KEY_ID=${aws_access_key_id} AWS_SECRET_ACCESS_KEY=${aws_secret_access_key} AWS_SESSION_TOKEN=${aws_session_token} \
        aws rds copy-db-snapshot --region "${BACKUP_DEST_REGION}" --source-db-snapshot-identifier "${source_rds_snapshot_arn}" \
            --target-db-snapshot-identifier "${rds_snapshot_id}" > /dev/null
    info "Copied RDS Snapshot ${source_rds_snapshot_arn} as ${rds_snapshot_id} to ${BACKUP_DEST_REGION}"
}

function copy_rds_snapshot {
    local source_rds_snapshot_id="$1"
    local source_aws_account_id=$(get_aws_account_id)

    info "Waiting for RDS snapshot ${source_rds_snapshot_id} to become available before copying to another region. This could take some time."
    aws rds wait db-snapshot-completed --db-snapshot-identifier "${source_rds_snapshot_id}"

    # Copy RDS snapshot to BACKUP_DEST_REGION
    local source_rds_snapshot_arn="arn:aws:rds:${AWS_REGION}:${source_aws_account_id}:snapshot:${source_rds_snapshot_id}"
    aws rds copy-db-snapshot --region "${BACKUP_DEST_REGION}" --source-db-snapshot-identifier "${source_rds_snapshot_arn}" \
      --target-db-snapshot-identifier "${source_rds_snapshot_id}" > /dev/null
    info "Copied RDS Snapshot ${source_rds_snapshot_arn} as ${source_rds_snapshot_id} to ${BACKUP_DEST_REGION}"
}

function copy_ebs_snapshot {
    local source_ebs_snapshot_id="$1"
    local source_region="$2"

    info "Waiting for EBS snapshot ${source_ebs_snapshot_id} to become available in ${source_region} before copying to ${BACKUP_DEST_REGION}"
    aws ec2 wait snapshot-completed --region ${source_region} --snapshot-ids ${source_ebs_snapshot_id}

    # Copy snapshot to BACKUP_DEST_REGION
    local dest_snapshot_id=$(aws ec2 copy-snapshot --region "${BACKUP_DEST_REGION}" --source-region "${source_region}" \
         --source-snapshot-id "${source_ebs_snapshot_id}" | jq -r '.SnapshotId')
    info "Copied EBS snapshot ${source_ebs_snapshot_id} from ${source_region} to ${BACKUP_DEST_REGION}. Snapshot copy ID: ${dest_snapshot_id}"

    info "Waiting for EBS snapshot ${dest_snapshot_id} to become available in ${BACKUP_DEST_REGION} before tagging"
    aws ec2 wait snapshot-completed --region ${BACKUP_DEST_REGION} --snapshot-ids ${dest_snapshot_id}

    # Add tags to copied snapshot
    aws ec2 create-tags --region ${BACKUP_DEST_REGION} --resources "${dest_snapshot_id}" --tags Key=Name,Value="${SNAPSHOT_TAG_VALUE}"
    info "Tagged EBS snapshot ${dest_snapshot_id} with {Name: ${SNAPSHOT_TAG_VALUE}}"
}

function copy_and_share_ebs_snapshot {
    local source_ebs_snapshot_id="$1"
    local source_region="$2"

    info "Waiting for EBS snapshot ${source_ebs_snapshot_id} to become available in ${source_region} before copying to ${BACKUP_DEST_REGION}"
    aws ec2 wait snapshot-completed --region ${source_region} --snapshot-ids ${source_ebs_snapshot_id}

    # Copy snapshot to BACKUP_DEST_REGION
    local dest_snapshot_id=$(aws ec2 copy-snapshot --region "${BACKUP_DEST_REGION}" --source-region "${source_region}" \
        --source-snapshot-id "${source_ebs_snapshot_id}" | jq -r '.SnapshotId')
    info "Copied EBS snapshot ${source_ebs_snapshot_id} from ${source_region} to ${BACKUP_DEST_REGION}. Snapshot copy ID: ${dest_snapshot_id}"

    info "Waiting for EBS snapshot ${dest_snapshot_id} to become available in ${BACKUP_DEST_REGION} before modifying permissions"
    aws ec2 wait snapshot-completed --region ${BACKUP_DEST_REGION} --snapshot-ids ${dest_snapshot_id}

    # Give BACKUP_DEST_AWS_ACCOUNT_ID permissions on the copied snapshot
    aws ec2 modify-snapshot-attribute --snapshot-id "${dest_snapshot_id}" --region ${BACKUP_DEST_REGION} \
        --attribute createVolumePermission --operation-type add --user-ids "${BACKUP_DEST_AWS_ACCOUNT_ID}"
    info "Granted create volume permission on ${dest_snapshot_id} for account:${BACKUP_DEST_AWS_ACCOUNT_ID}"

    info "Waiting for EBS snapshot ${dest_snapshot_id} to become available in ${BACKUP_DEST_REGION} before tagging"
    aws ec2 wait snapshot-completed --region ${BACKUP_DEST_REGION} --snapshot-ids ${dest_snapshot_id}

    info "Assuming AWS role ${BACKUP_DEST_AWS_ROLE} to tag copied snapshot"
    local creds=$(aws sts assume-role --role-arn ${BACKUP_DEST_AWS_ROLE} --role-session-name "BitbucketServerDIYBackup")

    # Add tag to copied snapshot, used to find EBS & RDS snapshot pairs for restoration
    AWS_ACCESS_KEY_ID="$(echo $creds | jq -r .Credentials.AccessKeyId)" \
        AWS_SECRET_ACCESS_KEY="$(echo $creds | jq -r .Credentials.SecretAccessKey)" \
        AWS_SESSION_TOKEN="$(echo $creds | jq -r .Credentials.SessionToken)" \
        aws ec2 create-tags --region ${BACKUP_DEST_REGION} --resources "${dest_snapshot_id}" \
            --tags Key=Name,Value="${SNAPSHOT_TAG_VALUE}"
    info "Tagged EBS snapshot ${dest_snapshot_id} with {Name: ${SNAPSHOT_TAG_VALUE}}"
}