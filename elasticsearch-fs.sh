# ----------------------------------------------------------------------------------------------------------------------
# The Elasticsearch shared filesystem strategy for Backup and restore, and Disaster recovery
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
    check_config_var "ELASTICSEARCH_REPOSITORY_LOCATION"

    if check_es_needs_configuration "${ELASTICSEARCH_HOST}"; then
        configure_shared_fs_snapshot_repository "${ELASTICSEARCH_HOST}"
    fi

    if check_es_needs_configuration "${STANDBY_ELASTICSEARCH_HOST}"; then
        configure_shared_fs_snapshot_repository "${STANDBY_ELASTICSEARCH_HOST}"
    fi
}
