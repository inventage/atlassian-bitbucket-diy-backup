# ----------------------------------------------------------------------------------------------------------------------
# The Amazon S3 based Elasticsearch strategy for Backup and restore, and Disaster recovery
#
# This script depends on elasticsearch-common.sh
# ----------------------------------------------------------------------------------------------------------------------

check_command "jq"
check_command "curl"

# ----------------------------------------------------------------------------------------------------------------------
# Backup and restore functions
# ----------------------------------------------------------------------------------------------------------------------

# See elasticsearch-common.sh for the implementation(s) of:
#  - backup_elasticsearch
#  - restore_elasticsearch

# ----------------------------------------------------------------------------------------------------------------------
# Disaster recovery functions
# ----------------------------------------------------------------------------------------------------------------------

# See elasticsearch-common.sh for the implementation(s) of:
#  - replicate_elasticsearch

# ----------------------------------------------------------------------------------------------------------------------
# Setup functions
# ----------------------------------------------------------------------------------------------------------------------

function setup_es_replication {
    check_config_var "ELASTICSEARCH_HOST"
    check_config_var "ELASTICSEARCH_PORT"
    check_config_var "STANDBY_ELASTICSEARCH_HOST"
    check_config_var "ELASTICSEARCH_S3_BUCKET"
    check_config_var "ELASTICSEARCH_S3_BUCKET_REGION"

    if check_es_needs_configuration "${ELASTICSEARCH_HOST}"; then
        configure_aws_s3_snapshot_repository "${ELASTICSEARCH_HOST}"
    fi

    if check_es_needs_configuration "${STANDBY_ELASTICSEARCH_HOST}"; then
        configure_aws_s3_snapshot_repository "${STANDBY_ELASTICSEARCH_HOST}"
    fi
}
