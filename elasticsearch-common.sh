# -------------------------------------------------------------------------------------
# Utilities used for Elasticsearch backup, restore and disaster Recovery
# -------------------------------------------------------------------------------------

# ----------------------------------------------------------------------------------------------------------------------
# Shared backup, restore and DR implementation
# ----------------------------------------------------------------------------------------------------------------------

function backup_elasticsearch {
    check_config_var "ELASTICSEARCH_HOST"
    check_config_var "ELASTICSEARCH_PORT"

    create_es_snapshot "${ELASTICSEARCH_HOST}"
}

function restore_elasticsearch {
    check_config_var "ELASTICSEARCH_HOST"
    check_config_var "ELASTICSEARCH_PORT"

    local latest_snapshot=$(get_es_snapshots "${ELASTICSEARCH_HOST}" | tail -1)
    restore_es_snapshot "${STANDBY_ELASTICSEARCH_HOST}" "${latest_snapshot}"
}

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
# Private functions
# ----------------------------------------------------------------------------------------------------------------------

# Check whether the Elasticsearch server has a snapshot repository configured
function check_es_needs_configuration {
    local server="$1"

    info "Checking if snapshot repository with name '${ELASTICSEARCH_REPOSITORY_NAME}' exists on server '${server}'"

    local es_url="http://${server}:${ELASTICSEARCH_PORT}/_snapshot/${ELASTICSEARCH_REPOSITORY_NAME}"
    if run curl ${CURL_OPTIONS} ${ELASTICSEARCH_CREDENTIALS} -X GET "${es_url}" > /dev/null 2>&1; then
        error "The snapshot repository '${ELASTICSEARCH_REPOSITORY_NAME}' already exists on server '${server}'"
        false
    else
        true
    fi
}

# Configure a S3 based snapshot repository
function configure_aws_s3_snapshot_repository {
    local server="$1"

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
    info "Creating Elasticsearch S3 snapshot repository with name '${ELASTICSEARCH_REPOSITORY_NAME}' on server '${server}'"

    local es_url="http://${server}:${ELASTICSEARCH_PORT}/_snapshot/${ELASTICSEARCH_REPOSITORY_NAME}"
    local es_response=$(run curl -s ${ELASTICSEARCH_CREDENTIALS} -X PUT "${es_url}" -d "${create_s3_repository}")

    if [ "$(echo ${es_response} | jq -r '.acknowledged')" != "true" ]; then
        error "Please ensure that the Amazon S3 plugin is correctly installed on Elasticsearch: sudo bin/plugin install cloud-aws"
        bail "Unable to create snapshot repository on server '${server}'. Elasticsearch returned: ${es_response}"
    fi

    success "Created Elasticsearch S3 snapshot repository '${ELASTICSEARCH_REPOSITORY_NAME}' on server '${server}'."
}

# Configure a shared filesystem based snapshot repository
function configure_shared_fs_snapshot_repository {
    local server="$1"

    # Configure the document to configure the FS repository
    local create_fs_repository=$(cat << EOF
{
    "type": "fs",
    "settings": {
        "location": "${ELASTICSEARCH_REPOSITORY_LOCATION}",
        "compress": true,
        "chunk_size": "10m"
    }
}
EOF
)
    info "Creating Elasticsearch shared filesystem snapshot repository with name '${ELASTICSEARCH_REPOSITORY_NAME}' on server '${server}'"

    local es_url="http://${server}:${ELASTICSEARCH_PORT}/_snapshot/${ELASTICSEARCH_REPOSITORY_NAME}"
    local es_response=$(run curl -s ${ELASTICSEARCH_CREDENTIALS} -X PUT "${es_url}" -d "${create_fs_repository}")

    if [ "$(echo ${es_response} | jq -r '.acknowledged')" != "true" ]; then
        error "Please ensure that Elasticsearch is correctly configured to access shared filesystem '${ELASTICSEARCH_REPOSITORY_LOCATION}'"
        error "To do this the 'elasticsearch.yml' entry 'path.repo: /media/${ELASTICSEARCH_REPOSITORY_LOCATION}' must exist"
        bail "Unable to create snapshot repository on server '${server}'. Elasticsearch returned: ${es_response}"
    fi

    success "Created Elasticsearch shared filesystem snapshot repository '${ELASTICSEARCH_REPOSITORY_NAME}' on server '${server}'."
}

# Close the requested index (used for restores)
function close_es_index {
    local server="$1"

    debug "Closing Elasticsearch index '${ELASTICSEARCH_INDEX_NAME}' on server '${server}'"

    local close_url="http://${server}:${ELASTICSEARCH_PORT}/${ELASTICSEARCH_INDEX_NAME}/_close"
    if ! run curl -s ${ELASTICSEARCH_CREDENTIALS} -X POST "${close_url}" > /dev/null 2>&1; then
        bail "Unable to close Elasticsearch index '${ELASTICSEARCH_INDEX_NAME}' on server '${server}'"
    fi

    success "Elasticsearch index '${ELASTICSEARCH_INDEX_NAME}' closed"
}

# Creates a Elasticsearch snapshot
function create_es_snapshot {
    local server="$1"

    # Configure the snapshot body
    local snapshot_body=$(cat << EOF
{
   "indices": "${ELASTICSEARCH_INDEX_NAME}",
   "ignore_unavailable": "true",
   "include_global_state": false
}
EOF
)
    local snapshot_name="${SNAPSHOT_TAG_PREFIX}${BACKUP_TIME}"
    local es_url="http://${server}:${ELASTICSEARCH_PORT}/_snapshot/${ELASTICSEARCH_REPOSITORY_NAME}/${snapshot_name}"

    debug "Creating Elasticsearch snapshot '${snapshot_name}' on server '${server}'"

    local es_response=$(run curl -s ${ELASTICSEARCH_CREDENTIALS} -X PUT "${es_url}" -d "${snapshot_body}")
    if [ "$(echo ${es_response} | jq -r '.accepted')" != "true" ]; then
        bail "Unable to create snapshot '${snapshot_name}' on server '${server}'. Elasticsearch returned: ${es_response}"
    fi

    debug "Waiting for Elasticsearch snapshot '${snapshot_name}' to complete"
    wait_for_es_snapshot "${server}" "${snapshot_name}"

    success "Elasticsearch snapshot '${snapshot_name}' created"
}

# Opens a Elasticsearch index after it has been restored
function open_es_index {
    local server="$1"

    debug "Opening Elasticsearch index '${ELASTICSEARCH_INDEX_NAME}' on server '${server}'"

    local open_url="http://${server}:${ELASTICSEARCH_PORT}/${ELASTICSEARCH_INDEX_NAME}/_open"
    if ! run curl -s ${ELASTICSEARCH_CREDENTIALS} -X POST "${open_url}" > /dev/null 2>&1; then
        bail "Unable to close index '${ELASTICSEARCH_INDEX_NAME}' on server '${server}'"
    fi

    success "Elasticsearch index '${ELASTICSEARCH_INDEX_NAME}' opened"
}

# Deletes a Elasticsearch snapshot
function delete_es_snapshot {
    local server="$1"
    local snapshot_name="$2"

    debug "Deleting Elasticsearch snapshot '${snapshot_name}' on server '${server}'"

    local delete_url="http://${server}:${ELASTICSEARCH_PORT}/_snapshot/${ELASTICSEARCH_REPOSITORY_NAME}/${snapshot_name}"
    if ! run curl -s ${ELASTICSEARCH_CREDENTIALS} -X DELETE "${delete_url}" > /dev/null 2>&1; then
        bail "Unable to delete snapshot '${snapshot_name}' on server '${server}'"
    fi

    success "Elasticsearch snapshot '${snapshot_name}' deleted"
}

# Restore a Elasticsearch instance from the specified snapshot
function restore_es_snapshot {
    local server="$1"
    local snapshot_name="$2"

    local snapshot_body=$(cat << EOF
{
  "indices": "${ELASTICSEARCH_INDEX_NAME}",
  "ignore_unavailable": true,
  "include_global_state": false,
  "include_aliases": true
}
EOF
)
    debug "Restoring Elasticsearch snapshot '${snapshot_name}' on server '${server}'"

    # Close the index so it can be restored
    close_es_index "${server}"
    add_cleanup_routine "open_es_index '${server}'"

    # Begin the restore
    local restore_url="http://${server}:${ELASTICSEARCH_PORT}/_snapshot/${ELASTICSEARCH_REPOSITORY_NAME}/${snapshot_name}/_restore"
    local es_response=$(run curl -s ${ELASTICSEARCH_CREDENTIALS} -X POST "${restore_url}" -d "${snapshot_body}")
    if [ "$(echo ${es_response} | jq -r '.snapshot.snapshot')" != "${snapshot_name}" ]; then
        if [ "$(echo ${es_response} | jq -r '.accepted')" != "true" ]; then
            bail "Unable to restore snapshot '${snapshot_name}' on ${server_type} server '${server}'. Elasticsearch returned: ${es_response}"
        fi
    fi

    # Open the index
    open_es_index "${server}"
    remove_cleanup_routine "open_es_index '${server}'"

    success "Elasticsearch index '${snapshot_name}' has been restored from snapshot '${snapshot_name}' on server '${server}'"
}

# Get a list of snapshots available
function get_es_snapshots {
    local server="$1"

    local snapshots_url="http://${server}:${ELASTICSEARCH_PORT}/_snapshot/${ELASTICSEARCH_REPOSITORY_NAME}/_all"
    local es_response=$(run curl -s ${ELASTICSEARCH_CREDENTIALS} -X GET "${snapshots_url}")
    local snapshots=$(echo ${es_response} | jq -r '.[] | sort_by(.start_time_in_millis) | .[]  | .snapshot')

    if [  -z "${snapshots}" ]; then
        bail "No snapshots were found on server '${server}'. Elasticsearch returned: ${es_response}"
    fi

    echo "${snapshots}"
}

# Clean up old Elasticsearch snapshots leaving the configured KEEP_BACKUPS number of snapshots
function cleanup_es_snapshots {
    local server="$1"

    local snapshots=$(get_es_snapshots "${server}")
    local no_of_snapshots=$(echo "${snapshots}" | wc -l)
    local no_of_snapshots_to_delete=$((no_of_snapshots-${KEEP_BACKUPS}))

    if [ ${no_of_snapshots_to_delete} -gt 0 ]; then
        debug "There are '${no_of_snapshots}' Elasticsearch snapshots, '${no_of_snapshots_to_delete}' need to be cleaned up"
        local snapshots_to_clean=$(echo "${snapshots}" | head -${no_of_snapshots_to_delete})
        for snapshot in ${snapshots_to_clean}; do
            delete_es_snapshot "${server}" "${snapshot}"
        done
    else
        debug "There are '${no_of_snapshots}' Elasticsearch snapshots, nothing to clean up"
    fi

    success "Elasticsearch snapshot cleanup successful"
}

# Waits for the snapshot creation to complete
function wait_for_es_snapshot {
    local server="$1"
    local snapshot_name="$2"

    # 60 Minutes
    local max_wait_time=3600
    local end_time=$((SECONDS+max_wait_time))
    local snapshot_status_url="http://${server}:${ELASTICSEARCH_PORT}/_snapshot/${ELASTICSEARCH_REPOSITORY_NAME}/${snapshot_name}"
    local timeout=true

    debug "Waiting for snapshot '${snapshot_name}' to complete on server '${server}'"

    while [ $SECONDS -lt ${end_time} ]; do
        sleep 15 # Give small snapshots time to settle before we check
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
            error "The snapshot '${snapshot_name}' failed, it is currently in state '${state}'"
            bail "Elasticsearch returned: ${es_response}"
            ;;
        esac
        sleep 15
    done

    if [ "${timeout}" = "true" ]; then
        bail "Restore of snapshot '${snapshot_name}' timed out after '${max_wait_time}' seconds on server '${server}'"
    fi
}

