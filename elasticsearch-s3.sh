# ----------------------------------------------------------------------------------------------------------------------
# The Amazon S3 based Elasticsearch strategy for Backup and restore, and Disaster recovery
#
# This script depends on elasticsearch-common.sh
# ----------------------------------------------------------------------------------------------------------------------

check_command "jq"
check_command "curl"
check_command "nc"

# ----------------------------------------------------------------------------------------------------------------------
# Backup and restore functions
# ----------------------------------------------------------------------------------------------------------------------

function backup_elasticsearch {
    check_config_var "ELASTICSEARCH_HOST"
    check_config_var "ELASTICSEARCH_PORT"

    create_es_snapshot "${ELASTICSEARCH_HOST}"
}

function restore_elasticsearch {
    check_config_var "ELASTICSEARCH_HOST"
    check_config_var "ELASTICSEARCH_PORT"

    error "Please specify a snapshot name and server on which to restore"
}

# ----------------------------------------------------------------------------------------------------------------------
# Disaster recovery functions
# ----------------------------------------------------------------------------------------------------------------------

function replicate_elasticsearch {
    check_config_var "ELASTICSEARCH_HOST"
    check_config_var "ELASTICSEARCH_PORT"
    check_config_var "STANDBY_ELASTICSEARCH_HOST"

    create_es_snapshot "${ELASTICSEARCH_HOST}"
    local latest_snapshot=$(get_es_snapshots "${ELASTICSEARCH_HOST}" | tail -1)
    restore_es_snapshot "${STANDBY_ELASTICSEARCH_HOST}" "${latest_snapshot}"
    cleanup_es_snapshots "${ELASTICSEARCH_HOST}"
}

# ----------------------------------------------------------------------------------------------------------------------
# Setup functions
# ----------------------------------------------------------------------------------------------------------------------

function setup_es_replication {
    check_config_var "ELASTICSEARCH_HOST"
    check_config_var "ELASTICSEARCH_PORT"
    check_config_var "STANDBY_ELASTICSEARCH_HOST"
    check_config_var "ELASTICSEARCH_S3_BUCKET"
    check_config_var "ELASTICSEARCH_S3_BUCKET_REGION"

    if check_es_connectivity "${ELASTICSEARCH_HOST}"; then
        if check_es_needs_configuration "${ELASTICSEARCH_HOST}"; then
            configure_aws_s3_snapshot_repository "${ELASTICSEARCH_HOST}"
        fi
    fi

    if check_es_connectivity "${STANDBY_ELASTICSEARCH_HOST}"; then
        if check_es_needs_configuration "${STANDBY_ELASTICSEARCH_HOST}"; then
            configure_aws_s3_snapshot_repository "${STANDBY_ELASTICSEARCH_HOST}"
        fi
    fi
}
