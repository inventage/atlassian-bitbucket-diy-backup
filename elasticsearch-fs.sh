# ----------------------------------------------------------------------------------------------------------------------
# The Elasticsearch shared filesystem strategy for Backup and restore
# ----------------------------------------------------------------------------------------------------------------------

source "${SCRIPT_DIR}/es-common.sh"

# ----------------------------------------------------------------------------------------------------------------------
# Backup and restore functions
# ----------------------------------------------------------------------------------------------------------------------

function backup_elasticsearch {
    check_es_needs_configuration
    create_es_snapshot
}

function cleanup_elasticsearch_backups {
    cleanup_es_snapshots
}

function prepare_restore_elasticsearch {
    local requested_snapshot="$1"

    check_es_index_exists
    check_es_needs_configuration

    validate_es_snapshot "${requested_snapshot}"
    RESTORE_ELASTICSEARCH_SNAPSHOT="${requested_snapshot}"
}

function restore_elasticsearch {
    check_var "RESTORE_ELASTICSEARCH_SNAPSHOT"

    restore_es_snapshot "${ELASTICSEARCH_HOST}" "${RESTORE_ELASTICSEARCH_SNAPSHOT}"
}
