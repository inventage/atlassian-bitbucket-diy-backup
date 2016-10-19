# ----------------------------------------------------------------------------------------------------------------------
# The AWS Elasticsearch service strategy for Backup and restore
# ----------------------------------------------------------------------------------------------------------------------

source "${SCRIPT_DIR}/es-common.sh"

# Required to run the python script that will sign each curl request to AWS ES
check_command "python"

# ----------------------------------------------------------------------------------------------------------------------
# Backup and restore functions
# ----------------------------------------------------------------------------------------------------------------------

function backup_elasticsearch {
    check_es_needs_configuration "${ELASTICSEARCH_HOST}"
    create_es_snapshot "${ELASTICSEARCH_HOST}"
}

function cleanup_elasticsearch_backups {
    check_config_var "ELASTICSEARCH_HOST"

    cleanup_es_snapshots "${ELASTICSEARCH_HOST}"
}

function prepare_restore_elasticsearch {
    check_es_index_exists
    check_es_needs_configuration
    validate_es_snapshot "$1"
    RESTORE_ELASTICSEARCH_SNAPSHOT="$1"
}

function restore_elasticsearch {
    check_var "RESTORE_ELASTICSEARCH_SNAPSHOT"

    restore_es_snapshot "${RESTORE_ELASTICSEARCH_SNAPSHOT}"
}