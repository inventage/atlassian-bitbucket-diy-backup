#!/bin/bash

function bitbucket_prepare_db {
    # Validate that all the configuration parameters have been provided to avoid bailing out and leaving Bitbucket locked
    if [ -z "${BACKUP_RDS_INSTANCE_ID}" ]; then
        error "The RDS instance id must be set in ${BACKUP_VARS_FILE}"
        bail "See bitbucket.diy-aws-backup.vars.sh.example for the defaults."
    fi

    validate_rds_instance_id "${BACKUP_RDS_INSTANCE_ID}"
}

function bitbucket_backup_db {
    info "Performing backup of RDS instance ${BACKUP_RDS_INSTANCE_ID}"

    local source_rds_snapshot_id=$(snapshot_rds_instance "${BACKUP_RDS_INSTANCE_ID}")

    if [ -n "${BACKUP_RDS_DEST_REGION}" ]; then
        if [ -n "${BACKUP_DEST_AWS_ACCOUNT_ID}" ] && [ -n "${BACKUP_DEST_AWS_ROLE}" ]; then
            share_and_copy_rds_snapshot "${source_rds_snapshot_id}"
        else
            copy_rds_snapshot "${source_rds_snapshot_id}"
        fi
    fi
}

function bitbucket_prepare_db_restore {
    local SNAPSHOT_TAG="${1}"

    if [ -z "${RESTORE_RDS_INSTANCE_ID}" ]; then
        error "The RDS instance id must be set in ${BACKUP_VARS_FILE}"
        bail "See bitbucket.diy-aws-backup.vars.sh.example for the defaults."
    fi

    if [ -z "${RESTORE_RDS_INSTANCE_CLASS}" ]; then
        info "No restore instance class has been set in ${BACKUP_VARS_FILE}"
    fi

    if [ -z "${RESTORE_RDS_SUBNET_GROUP_NAME}" ]; then
        info "No restore subnet group has been set in ${BACKUP_VARS_FILE}"
    fi

    if [ -z "${RESTORE_RDS_SECURITY_GROUP}" ]; then
        info "No restore security group has been set in ${BACKUP_VARS_FILE}"
    fi

    validate_rds_snapshot "${SNAPSHOT_TAG}"

    RESTORE_RDS_SNAPSHOT_ID="${SNAPSHOT_TAG}"
}

function bitbucket_restore_db {
    restore_rds_instance "${RESTORE_RDS_INSTANCE_ID}" "${RESTORE_RDS_SNAPSHOT_ID}"

    info "Performed restore of ${RESTORE_RDS_SNAPSHOT_ID} to RDS instance ${RESTORE_RDS_INSTANCE_ID}"
}

function cleanup_old_db_snapshots {

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
        cleanup_old_offsite_snapshots
    fi
}

function cleanup_old_offsite_snapshots {
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