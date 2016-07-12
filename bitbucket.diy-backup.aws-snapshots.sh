#!/bin/bash

# Functions implementing archiving of backups and copy to offsite location for AWS snapshots.
# AWS snapshots reside in AWS and are not archived in this implementation.
#
# You can optionally set BACKUP_EBS_DEST_REGION and BACKUP_RDS_DEST_REGION to copy every snapshot to another AWS region,
# for example, as part of a disaster recovery plan.
#
# Additionally, you can also set the variables BACKUP_DEST_AWS_ACCOUNT_ID and BACKUP_DEST_AWS_ROLE to share every
# snapshot with another AWS account.

function bitbucket_backup_archive {
    # AWS snapshots reside in AWS and do not need to be archived.

    # Optionally copy/share the EBS snapshot to another region and/or account.
    # This is useful to retain a cross region/account copy of the backup.
    if [ -n "${BACKUP_EBS_DEST_REGION}" ]; then
        if [ -n "${BACKUP_DEST_AWS_ACCOUNT_ID}" ] && [ -n "${BACKUP_DEST_AWS_ROLE}" ]; then
            copy_and_share_ebs_snapshot ${BACKUP_EBS_SNAPSHOT_ID} ${AWS_REGION}
        else
            copy_ebs_snapshot ${BACKUP_EBS_SNAPSHOT_ID} ${AWS_REGION} ${BACKUP_EBS_DEST_REGION}
        fi
    fi

    if [ -n "${BACKUP_RDS_DEST_REGION}" ]; then
        if [ -n "${BACKUP_DEST_AWS_ACCOUNT_ID}" ] && [ -n "${BACKUP_DEST_AWS_ROLE}" ]; then
            share_and_copy_rds_snapshot "${BACKUP_RDS_SNAPSHOT_ID}"
        else
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

    if [ -n "${BACKUP_EBS_DEST_REGION}" ]; then
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

    if [ -n "${BACKUP_RDS_DEST_REGION}" ]; then
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
            aws rds describe-db-snapshots --region ${BACKUP_RDS_DEST_REGION} --snapshot-type manual \
                | jq -r ".DBSnapshots | map(select(.DBSnapshotIdentifier | startswith(\"${SNAPSHOT_TAG_PREFIX}\"))) | sort_by(.SnapshotCreateTime) | reverse | .[${KEEP_BACKUPS}:] | map(.DBSnapshotIdentifier)[]")

        # Delete old RDS snapshots from BACKUP_DEST_AWS_ACCOUNT_ID in region BACKUP_RDS_DEST_REGION
        for snapshot_id in $old_offsite_snapshots; do
            info "Deleting old cross-account RDS snapshot ${snapshot_id}"
            AWS_ACCESS_KEY_ID=${aws_access_key_id} AWS_SECRET_ACCESS_KEY=${aws_secret_access_key} AWS_SESSION_TOKEN=${aws_session_token} \
                aws rds delete-db-snapshot --region ${BACKUP_RDS_DEST_REGION} --db-snapshot-identifier "${snapshot_id}" > /dev/null
        done
    else
        # Delete old RDS snapshots in BACKUP_RDS_DEST_REGION
        for snapshot_id in $(list_old_rds_snapshot_ids ${AWS_REGION}); do
            info "Deleting old cross-region RDS snapshot ${snapshot_id}"
            aws rds delete-db-snapshot --db-snapshot-identifier "${snapshot_id}" > /dev/null
        done
    fi
}

function cleanup_old_offsite_ebs_snapshots {
    # Fraser implement me!
}