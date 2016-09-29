# ----------------------------------------------------------------------------------------------------------------------
# The Elasticsearch shared filesystem strategy for Backup and restore
# ----------------------------------------------------------------------------------------------------------------------

source "${SCRIPT_DIR}/es-common.sh"

# ----------------------------------------------------------------------------------------------------------------------
# Backup and restore functions
# ----------------------------------------------------------------------------------------------------------------------

function backup_elasticsearch {
    check_config_var "ELASTICSEARCH_HOST"
    check_config_var "ELASTICSEARCH_PORT"

    check_es_needs_configuration "${ELASTICSEARCH_HOST}"
    create_es_snapshot "${ELASTICSEARCH_HOST}"
}

function cleanup_elasticsearch_backups {
    check_config_var "ELASTICSEARCH_HOST"
    check_config_var "ELASTICSEARCH_PORT"

    cleanup_es_snapshots "${ELASTICSEARCH_HOST}"
}

function prepare_restore_elasticsearch {
    local requested_snapshot="$1"

    check_es_index_exists "${ELASTICSEARCH_HOST}" "${ELASTICSEARCH_INDEX_NAME}"
    check_es_needs_configuration "${ELASTICSEARCH_HOST}"

    validate_es_snapshot "${requested_snapshot}"
    RESTORE_ELASTICSEARCH_SNAPSHOT="${requested_snapshot}"
}

function restore_elasticsearch {
    check_config_var "ELASTICSEARCH_HOST"
    check_config_var "ELASTICSEARCH_PORT"
    check_var "RESTORE_ELASTICSEARCH_SNAPSHOT"

    restore_es_snapshot "${ELASTICSEARCH_HOST}" "${RESTORE_ELASTICSEARCH_SNAPSHOT}"
}
