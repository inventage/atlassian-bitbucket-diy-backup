# -------------------------------------------------------------------------------------
# Utilities used for Elasticsearch backup, restore and disaster Recovery
# -------------------------------------------------------------------------------------

check_command "jq"
check_command "curl"

# Validates whether a valid snapshot identifier has been specified
function validate_es_snapshot {
    local snapshot_tag="$1"

    debug "Getting snapshot list from Elasticsearch server '${ELASTICSEARCH_HOST}'"
    local snapshot_list=$(get_es_snapshots "${ELASTICSEARCH_HOST}")

    if [ -z "${snapshot_tag}" ]; then
        info "Available Snapshots:"
        info "${snapshot_list}"
        bail "Please select a snapshot to restore"
    fi

    debug "Validating Elasticsearch snapshot '${snapshot_tag}'"
    local has_snapshot=$(echo "${snapshot_list}" | grep "${snapshot_tag}")
    if [ -z "${has_snapshot}" ]; then
        error "Unable to find snapshot '${snapshot_tag}' in the list of Elasticsearch snapshots:"
        info "Available Snapshots:"
        print "${snapshot_list}"
        bail "Please select a snapshot to restore"
    fi
}

# Check whether the Elasticsearch server has a snapshot repository configured
function check_es_index_exists {
    local server="$1"
    local index="$2"

    info "Checking whether index with name '${index}' exists on server '${server}'"

    local es_url="http://${server}:${ELASTICSEARCH_PORT}/${index}"

    if run curl ${CURL_OPTIONS} ${ELASTICSEARCH_CREDENTIALS} -X GET "${es_url}" > /dev/null 2>&1; then
        bail "An index with name '${index}' exists on server '${server}', please remove it before restoring"
    fi
}

# Check whether the Elasticsearch server has a snapshot repository configured
function check_es_needs_configuration {
    local server="$1"

    info "Checking if snapshot repository with name '${ELASTICSEARCH_REPOSITORY_NAME}' exists on server '${server}'"

    local es_url="http://${server}:${ELASTICSEARCH_PORT}/_snapshot/${ELASTICSEARCH_REPOSITORY_NAME}"
    if run curl ${CURL_OPTIONS} ${ELASTICSEARCH_CREDENTIALS} -X GET "${es_url}" > /dev/null 2>&1; then
        debug "The snapshot repository '${ELASTICSEARCH_REPOSITORY_NAME}' already exists on server '${server}'"
    else
        case "${BACKUP_ELASTICSEARCH_TYPE}" in
        s3)
            configure_aws_s3_snapshot_repository "${server}"
            ;;
        fs)
            configure_shared_fs_snapshot_repository "${server}"
            ;;
        esac
    fi
}

# Configure a S3 based snapshot repository
function configure_aws_s3_snapshot_repository {
    local server="$1"

    check_config_var "ELASTICSEARCH_S3_BUCKET"
    check_config_var "ELASTICSEARCH_S3_BUCKET_REGION"

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

    check_config_var "ELASTICSEARCH_REPOSITORY_LOCATION"

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
    local snapshot_name="${SNAPSHOT_TAG_VALUE}"
    local es_url="http://${server}:${ELASTICSEARCH_PORT}/_snapshot/${ELASTICSEARCH_REPOSITORY_NAME}/${snapshot_name}"

    debug "Creating Elasticsearch snapshot '${snapshot_name}' on server '${server}'"

    local es_response=$(run curl -s ${ELASTICSEARCH_CREDENTIALS} -X PUT "${es_url}" -d "${snapshot_body}")
    if [ "$(echo ${es_response} | jq -r '.accepted')" != "true" ]; then
        bail "Unable to create snapshot '${snapshot_name}' on server '${server}'. Elasticsearch returned: ${es_response}"
    fi

    success "Elasticsearch snapshot '${snapshot_name}' created"
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

    # Begin the restore
    local restore_url="http://${server}:${ELASTICSEARCH_PORT}/_snapshot/${ELASTICSEARCH_REPOSITORY_NAME}/${snapshot_name}/_restore"
    local es_response=$(run curl -s ${ELASTICSEARCH_CREDENTIALS} -X POST "${restore_url}" -d "${snapshot_body}")
    if [ "$(echo ${es_response} | jq -r '.snapshot.snapshot')" != "${snapshot_name}" ]; then
        if [ "$(echo ${es_response} | jq -r '.accepted')" != "true" ]; then
            bail "Unable to restore snapshot '${snapshot_name}' on ${server_type} server '${server}'. Elasticsearch returned: ${es_response}"
        fi
    fi

    success "Elasticsearch index '${ELASTICSEARCH_INDEX_NAME}' has been restored from snapshot '${snapshot_name}' on server '${server}'."
    info "The index will be available as soon as index recovery completes, it might take a little while."
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

