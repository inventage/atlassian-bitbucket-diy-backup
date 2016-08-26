#!/bin/bash

# -------------------------------------------------------------------------------------
# The Amazon S3 based Elasticsearch strategy for replication and backup
# -------------------------------------------------------------------------------------

# ----------------------------------------------------------------------------------------------------------------------
# Backup and restore functions
# ----------------------------------------------------------------------------------------------------------------------


# ----------------------------------------------------------------------------------------------------------------------
# Disaster recovery functions
# ----------------------------------------------------------------------------------------------------------------------

function replicate_elasticsearch {
    check_config_var "ELASTICSEARCH_HOST"
    check_config_var "ELASTICSEARCH_PORT"
    check_config_var "STANDBY_ELASTICSEARCH_HOST"

    create_es_snapshot "${ELASTICSEARCH_HOST}" "${ELASTICSEARCH_PORT}" "primary"
    local latest_snapshot=$(get_es_snapshots | tail -1)
    restore_es_snapshot "${STANDBY_ELASTICSEARCH_HOST}" "${ELASTICSEARCH_PORT}" "standby" "${latest_snapshot}"
    cleanup_es_snapshots
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

    if check_es_connectivity "${ELASTICSEARCH_HOST}" "${ELASTICSEARCH_PORT}"; then
        if check_es_needs_configuration "${ELASTICSEARCH_HOST}" "${ELASTICSEARCH_PORT}" "primary"; then
            configure_snapshot_repository "${ELASTICSEARCH_HOST}" "${ELASTICSEARCH_PORT}"  "primary"
        fi
    fi


    if check_es_connectivity "${STANDBY_ELASTICSEARCH_HOST}" "${ELASTICSEARCH_PORT}"; then
        if check_es_needs_configuration "${STANDBY_ELASTICSEARCH_HOST}" "${ELASTICSEARCH_PORT}" "standby"; then
            configure_snapshot_repository "${STANDBY_ELASTICSEARCH_HOST}" "${ELASTICSEARCH_PORT}"  "standby"
        fi
    fi
}

# ----------------------------------------------------------------------------------------------------------------------
# Private methods
# ----------------------------------------------------------------------------------------------------------------------

function check_es_connectivity {
    local server="$1"
    local port="$2"

    info "Checking whether Elasticsearch is responding to connections"
    if nc -z -w5 ${server} ${port}; then
        true
    else
        error "Please ensure that Elasticsearch is correctly configured on host '${server}' to listen on port '${port}'"
        false
    fi
}

function check_es_needs_configuration {
    local server="$1"
    local port="$2"
    local server_type="$3"
    local es_url="http://${server}:${port}/_snapshot/${ELASTICSEARCH_REPOSITORY_NAME}"

    info "Checking if snapshot repository with name '${ELASTICSEARCH_REPOSITORY_NAME}' exists on the ${server_type} server"
    if run curl ${CURL_OPTIONS} ${ELASTICSEARCH_CREDENTIALS} -X GET "${es_url}" > /dev/null 2>&1; then
        error "The snapshot repository '${ELASTICSEARCH_REPOSITORY_NAME}' already exists on the ${server_type} server"
        false
    else
        true
    fi
}

function configure_snapshot_repository {
    local server="$1"
    local port="$2"
    local server_type="$3"
    local es_url="http://${server}:${port}/_snapshot/${ELASTICSEARCH_REPOSITORY_NAME}"

    # Configure the document to configure the S3 bucket
    local create_s3_repository=$(cat << EOF
{
    "type": "s3",
    "settings": {
        "bucket": "${ELASTICSEARCH_S3_BUCKET}",
        "region": "${ELASTICSEARCH_S3_BUCKET_REGION}"
    }
}
EOF
)

    info "Creating snapshot repository with name '${ELASTICSEARCH_REPOSITORY_NAME}' on the ${server_type} server"
    local es_response=$(run curl -s ${ELASTICSEARCH_CREDENTIALS} -X PUT "${es_url}" -d "${create_s3_repository}")

    if [ "$(echo ${es_response} | jq -r '.acknowledged')" != "true" ]; then
        error "Please ensure that the Amazon S3 plugin is correctly installed on Elasticsearch: sudo bin/plugin install cloud-aws"
        bail "Unable to create snapshot repository on ${server_type} server '${server}'. Elasticsearch returned: ${es_response}"
    fi

    success "Created Elasticsearch snapshot repository '${ELASTICSEARCH_REPOSITORY_NAME}' on the ${server_type} server."
}

function create_es_snapshot {
    local server="$1"
    local port="$2"
    local server_type="$3"

    local snapshot_timestamp=$(date "+%d%m%Y-%H%M%S")
    local snapshot_name="dr-snapshot-${snapshot_timestamp}"
    local es_url="http://${server}:${port}/_snapshot/${ELASTICSEARCH_REPOSITORY_NAME}/${snapshot_name}"

    # Configure the snapsnot body
    local snapshot_body=$(cat << EOF
{
   "indices": "${ELASTICSEARCH_INDEX_NAME}",
   "ignore_unavailable": "true",
   "include_global_state": false
}
EOF
)

    debug "Creating Elasticsearch snapshot '${snapshot_name}' on the ${server_type} server"
    local es_response=$(run curl -s ${ELASTICSEARCH_CREDENTIALS} -X PUT "${es_url}" -d "${snapshot_body}")

    if [ "$(echo ${es_response} | jq -r '.snapshot.state')" != "SUCCESS" ]; then
        if [ "$(echo ${es_response} | jq -r '.accepted')" != "true" ]; then
            bail "Unable to create snapshot on ${server_type} server '${server}'. Elasticsearch returned: ${es_response}"
        fi
    fi

    debug "Waiting for Elasticsearch snapshot '${snapshot_name}' to complete"
    wait_for_es_snapshot "${snapshot_name}"
}

function close_es_index {
    local close_url="http://${STANDBY_ELASTICSEARCH_HOST}:${ELASTICSEARCH_PORT}/${ELASTICSEARCH_INDEX_NAME}/_close"
    debug "Closing Elasticsearch index '${ELASTICSEARCH_INDEX_NAME}' on the standby server"
    if ! run curl -s ${ELASTICSEARCH_CREDENTIALS} -X POST "${close_url}" > /dev/null 2>&1; then
        bail "Unable to close index '${ELASTICSEARCH_INDEX_NAME}' on server '${STANDBY_ELASTICSEARCH_HOST}'"
    fi
}

function open_es_index {
    local open_url="http://${STANDBY_ELASTICSEARCH_HOST}:${ELASTICSEARCH_PORT}/${ELASTICSEARCH_INDEX_NAME}/_open"
    debug "Opening Elasticsearch index '${ELASTICSEARCH_INDEX_NAME}' on the standby server"
    if ! run curl -s ${ELASTICSEARCH_CREDENTIALS} -X POST "${open_url}" > /dev/null 2>&1; then
        bail "Unable to close index '${ELASTICSEARCH_INDEX_NAME}' on server '${STANDBY_ELASTICSEARCH_HOST}'"
    fi
}

function delete_es_snapshot {
    local snapshot_name="$1"
    local delete_url="http://${ELASTICSEARCH_HOST}:${ELASTICSEARCH_PORT}/_snapshot/${ELASTICSEARCH_REPOSITORY_NAME}/${snapshot_name}"

    debug "Deleting Elasticsearch snapshot '${snapshot_name}'"
    if ! run curl -s ${ELASTICSEARCH_CREDENTIALS} -X DELETE "${delete_url}" > /dev/null 2>&1; then
        bail "Unable to delete snapshot '${snapshot_name}'"
    fi
}

function restore_es_snapshot {
    local server="$1"
    local port="$2"
    local server_type="$3"
    local snapshot_name="$4"

    local restore_url="http://${server}:${port}/_snapshot/${ELASTICSEARCH_REPOSITORY_NAME}/${snapshot_name}/_restore"
    local snapshot_body=$(cat << EOF
{
  "indices": "${ELASTICSEARCH_INDEX_NAME}",
  "ignore_unavailable": true,
  "include_global_state": false,
  "include_aliases": true
}
EOF
)

    # Close the index so it can be restored
    close_es_index
    local cleanup="open_es_index '${server}' '${port}'"

    add_cleanup_routine open_es_index

    # Begin the restore
    debug "Restoring Elasticsearch snapshot '${snapshot_name}' on the ${server_type} server"
    local es_response=$(run curl -s ${ELASTICSEARCH_CREDENTIALS} -X POST "${restore_url}" -d "${snapshot_body}")

    if [ "$(echo ${es_response} | jq -r '.snapshot.snapshot')" != "${snapshot_name}" ]; then
        if [ "$(echo ${es_response} | jq -r '.accepted')" != "true" ]; then
            bail "Unable to restore snapshot '${snapshot_name}' on ${server_type} server '${server}'. Elasticsearch returned: ${es_response}"
        fi
    fi

    # Wait for restore to complete
    wait_for_es_recovery

    # Open the index
    open_es_index
    remove_cleanup_routine open_es_index
}

function get_es_snapshots {
    local snapshots_url="http://${ELASTICSEARCH_HOST}:${ELASTICSEARCH_PORT}/_snapshot/${ELASTICSEARCH_REPOSITORY_NAME}/_all"
    local es_response=$(run curl -s ${ELASTICSEARCH_CREDENTIALS} -X GET "${snapshots_url}")
    local snapshots=$(echo ${es_response} | jq -r '.[] | sort_by(.start_time_in_millis) | .[]  | .snapshot')

    if [  -z "${snapshots}" ]; then
        bail "Unable to get the list of snapshots. Elasticsearch returned: ${es_response}"
    fi

    echo "${snapshots}"
}

function cleanup_es_snapshots {
    local snapshots=$(get_es_snapshots)
    local no_of_snapshots=$(echo "${snapshots}" | wc -l)
    local no_of_snapshots_to_delete=$((no_of_snapshots-${KEEP_BACKUPS}))

    if [ ${no_of_snapshots_to_delete} -gt 0 ]; then
        debug "There are '${no_of_snapshots}' Elasticsearch snapshots, '${no_of_snapshots_to_delete}' need to be cleaned up"
        local snapshots_to_clean=$(echo "${snapshots}" | head -${no_of_snapshots_to_delete})
        for snapshot in ${snapshots_to_clean}; do
            delete_es_snapshot "${snapshot}"
        done
    else
        debug "There are '${no_of_snapshots}' Elasticsearch snapshots, nothing to clean up"
    fi
}

function wait_for_es_snapshot {
    local snapshot_name="$1"

    # 15 Minutes
    local max_wait_time=900
    local end_time=$((SECONDS+max_wait_time))
    local timeout=true
    local snapshot_status_url="http://${ELASTICSEARCH_HOST}:${ELASTICSEARCH_PORT}/_snapshot/${ELASTICSEARCH_REPOSITORY_NAME}/${snapshot_name}"

    debug "Waiting for snapshot '${snapshot_name}' to complete"

    while [ $SECONDS -lt ${end_time} ]; do
        sleep 5
        local es_response=$(run curl -s ${ELASTICSEARCH_CREDENTIALS} -X GET "${snapshot_status_url}")
        local state=$(echo "${es_response}" | jq -r '.snapshots[0].state')
        case ${state} in
        "SUCCESS")
            debug "Snapshot '${snapshot_name}' is successful"
            timeout=false
            break
            ;;
        "IN_PROGRESS")
            debug "Snapshot '${snapshot_name}' is in progress"
            ;;
        *)
            # Aborted / Failed and all the other error cases
            bail "The snapshot '${snapshot_name}' has failed with state '${state}'. Elasticsearch returned: ${es_response}"
            ;;
        esac
        sleep 5
    done

    if [ "${timeout}" = "true" ]; then
        bail "Restore of snapshot '${snapshot_name}' timed out after '${max_wait_time}' seconds"
    fi
}

function wait_for_es_recovery {
    # 15 Minutes
    local max_wait_time=900
    local end_time=$((SECONDS+max_wait_time))
    local timeout=true
    local recovery_url="http://${STANDBY_ELASTICSEARCH_HOST}:${ELASTICSEARCH_PORT}/${ELASTICSEARCH_INDEX_NAME}/_recovery"

    debug "Waiting for recovery to complete"

    while [ $SECONDS -lt ${end_time} ]; do
        sleep 5
        local es_response=$(run curl -s ${ELASTICSEARCH_CREDENTIALS} -X GET "${recovery_url}")
        local busy_shards=$(echo ${es_response} | jq -r '.[]?.shards | map(select(.stage!="DONE")) | length')
        if [ ${busy_shards} -eq 0 ]; then
            timeout=false
            break;
        fi
        debug "Waiting for '${busy_shards}' shards to finish recovering"
        sleep 5
    done

    if [ "${timeout}" = "true" ]; then
        bail "Waiting for recovery timed out after '${max_wait_time}' seconds"
    fi
}
