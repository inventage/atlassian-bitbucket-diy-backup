# -------------------------------------------------------------------------------------
# Utilities used for Elasticsearch backup, restore and disaster Recovery
# -------------------------------------------------------------------------------------

check_command "jq"
check_command "curl"

check_config_var "ELASTICSEARCH_HOST"
check_config_var "ELASTICSEARCH_INDEX_NAME"
check_config_var "ELASTICSEARCH_REPOSITORY_NAME"

# Validate that the input is a snapshot that exists on the Elasticsearch instance
function validate_es_snapshot {
    local snapshot_tag="$1"

    debug "Getting snapshot list from Elasticsearch instance '${ELASTICSEARCH_HOST}'"
    local snapshot_list=$(get_es_snapshots)

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

# Check whether the Elasticsearch instance has an index named $ELASTICSEARCH_INDEX_NAME
function check_es_index_exists {
    info "Checking whether index with name '${ELASTICSEARCH_INDEX_NAME}' exists on instance '${ELASTICSEARCH_HOST}'"

    local es_response=$(curl_elasticsearch "GET" "/${ELASTICSEARCH_INDEX_NAME}")

    if [ "$(echo ${es_response} | jq -r '.error .type')" != "index_not_found_exception" ]; then
        debug "Elasticsearch response: ${es_response}"
        bail "An index with name '${ELASTICSEARCH_INDEX_NAME}' exists on instance '${ELASTICSEARCH_HOST}', please remove it before restoring"
    fi
}

# Check whether the Elasticsearch instance has a snapshot repository configured
function check_es_needs_configuration {
    info "Checking if snapshot repository with name '${ELASTICSEARCH_REPOSITORY_NAME}' exists on instance '${ELASTICSEARCH_HOST}'"

    local es_response=$(curl_elasticsearch "GET" "/_snapshot/${ELASTICSEARCH_REPOSITORY_NAME}")
    if [ "$(echo ${es_response} | jq -r '.error .type')" = "repository_missing_exception" ]; then
        case "${BACKUP_ELASTICSEARCH_TYPE}" in
        amazon-es)
            configure_aws_es_snapshot_repository
            ;;
        s3)
            configure_aws_s3_snapshot_repository
            ;;
        fs)
            configure_shared_fs_snapshot_repository
            ;;
        esac
    elif [[ "${es_response}" == *"${ELASTICSEARCH_REPOSITORY_NAME}"* ]]; then
        debug "The snapshot repository '${ELASTICSEARCH_REPOSITORY_NAME}' already exists on server '${ELASTICSEARCH_HOST}'"
    else
        bail "Elasticsearch snapshot repository configuration failed with '${es_response}'"
    fi
}

# Configures the AWS Elasticsearch domain to use the specified S3 bucket as the snapshot repository
function configure_aws_es_snapshot_repository {
    check_config_var "ELASTICSEARCH_S3_BUCKET"
    check_config_var "ELASTICSEARCH_S3_BUCKET_REGION"
    check_config_var "ELASTICSEARCH_SNAPSHOT_IAM_ROLE"

    local data=$(cat << EOF
{
    "type": "s3",
    "settings": {
        "bucket": "${ELASTICSEARCH_S3_BUCKET}",
        "region": "${ELASTICSEARCH_S3_BUCKET_REGION}",
        "role_arn": "${ELASTICSEARCH_SNAPSHOT_IAM_ROLE}"
    }
}
EOF
)
    info "Creating Elasticsearch S3 snapshot repository with name '${ELASTICSEARCH_REPOSITORY_NAME}' on instance '${ELASTICSEARCH_HOST}'"

    local es_response=$(curl_elasticsearch "POST" "/_snapshot/${ELASTICSEARCH_REPOSITORY_NAME}" "${data}")

    if [ "$(echo ${es_response} | jq -r '.acknowledged')" != "true" ]; then
        bail "Failed to create S3 snapshot repository, '${ELASTICSEARCH_HOST}' responded with ${es_response}"
    fi

    success "Created Elasticsearch S3 snapshot repository '${ELASTICSEARCH_REPOSITORY_NAME}' on instance '${ELASTICSEARCH_HOST}'"
}

# Configures a S3 based snapshot repository
function configure_aws_s3_snapshot_repository {
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
    info "Creating Elasticsearch S3 snapshot repository with name '${ELASTICSEARCH_REPOSITORY_NAME}' on instance '${ELASTICSEARCH_HOST}'"

    local es_response=$(curl_elasticsearch "PUT" "/_snapshot/${ELASTICSEARCH_REPOSITORY_NAME}" "${create_s3_repository}")

    if [ "$(echo ${es_response} | jq -r '.acknowledged')" != "true" ]; then
        error "Please ensure that the Amazon S3 plugin is correctly installed on Elasticsearch: sudo bin/plugin install cloud-aws"
        bail "Unable to create snapshot repository on server '${ELASTICSEARCH_HOST}'. Elasticsearch returned: ${es_response}"
    fi

    success "Created Elasticsearch S3 snapshot repository '${ELASTICSEARCH_REPOSITORY_NAME}' on instance '${ELASTICSEARCH_HOST}'."
}

# Configure a shared filesystem based snapshot repository
function configure_shared_fs_snapshot_repository {
    check_config_var "ELASTICSEARCH_REPOSITORY_LOCATION"

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
    info "Creating Elasticsearch shared filesystem snapshot repository with name '${ELASTICSEARCH_REPOSITORY_NAME}' on instance '${ELASTICSEARCH_HOST}'"

    local es_response=$(curl_elasticsearch "PUT" "/_snapshot/${ELASTICSEARCH_REPOSITORY_NAME}" "${create_fs_repository}")

    if [ "$(echo ${es_response} | jq -r '.acknowledged')" != "true" ]; then
        error "Please ensure that Elasticsearch is correctly configured to access shared filesystem '${ELASTICSEARCH_REPOSITORY_LOCATION}'"
        error "To do this the 'elasticsearch.yml' entry 'path.repo: /media/${ELASTICSEARCH_REPOSITORY_LOCATION}' must exist"
        bail "Unable to create snapshot repository on instance '${ELASTICSEARCH_HOST}'. Elasticsearch returned: ${es_response}"
    fi

    success "Created Elasticsearch shared filesystem snapshot repository '${ELASTICSEARCH_REPOSITORY_NAME}' on instance '${ELASTICSEARCH_HOST}'."
}

# Creates an Elasticsearch snapshot
function create_es_snapshot {
    check_var "SNAPSHOT_TAG_VALUE"

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

    debug "Creating Elasticsearch snapshot '${snapshot_name}' on instance '${ELASTICSEARCH_HOST}'"

    local es_response=$(curl_elasticsearch "PUT" "/_snapshot/${ELASTICSEARCH_REPOSITORY_NAME}/${snapshot_name}" "${snapshot_body}")
    if [ "$(echo ${es_response} | jq -r '.accepted')" != "true" ]; then
        bail "Unable to create snapshot '${snapshot_name}' on instance '${ELASTICSEARCH_HOST}'. Elasticsearch returned: ${es_response}"
    fi

    success "Elasticsearch snapshot '${snapshot_name}' created"
}

# Deletes an Elasticsearch snapshot
function delete_es_snapshot {
    local snapshot_name="$1"

    debug "Deleting Elasticsearch snapshot '${snapshot_name}' on instance '${ELASTICSEARCH_HOST}'"

    local es_response=$(curl_elasticsearch "DELETE" "/_snapshot/${ELASTICSEARCH_REPOSITORY_NAME}/${snapshot_name}")
    if [ "$(echo ${es_response} | jq -r '.acknowledged')" = "true" ]; then
        debug "Successfully deleted snapshot '${snapshot_name}'"
    else
        info "Failed to delete snapshot '${snapshot_name}', Elasticsearch responded with '${es_response}'"
    fi

    success "Elasticsearch snapshot '${snapshot_name}' deleted"
}

# Restores an Elasticsearch instance from the specified snapshot
function restore_es_snapshot {
    local snapshot_name="$1"

    local snapshot_body=$(cat << EOF
{
  "indices": "${ELASTICSEARCH_INDEX_NAME}",
  "ignore_unavailable": true,
  "include_global_state": false,
  "include_aliases": true
}
EOF
)
    debug "Restoring Elasticsearch snapshot '${snapshot_name}' on instance '${ELASTICSEARCH_HOST}'"

    local es_response=$(curl_elasticsearch "POST" "/_snapshot/${ELASTICSEARCH_REPOSITORY_NAME}/${snapshot_name}/_restore" "${snapshot_body}")
    if [ "$(echo ${es_response} | jq -r '.snapshot.snapshot')" != "${snapshot_name}" ]; then
        if [ "$(echo ${es_response} | jq -r '.accepted')" != "true" ]; then
            bail "Unable to restore snapshot '${snapshot_name}' on instance '${ELASTICSEARCH_HOST}'. Elasticsearch returned: ${es_response}"
        fi
    fi

    success "Elasticsearch index '${ELASTICSEARCH_INDEX_NAME}' has been restored from snapshot '${snapshot_name}' on instance '${ELASTICSEARCH_HOST}'."
    info "The index will be available as soon as index recovery completes, it might take a little while."
}

# Queries the Elasticsearch instance and returns a list of available snapshots
function get_es_snapshots {
    local data='{"ignore_unavailable": "true"}'
    local es_response=$(curl_elasticsearch "GET" "/_snapshot/${ELASTICSEARCH_REPOSITORY_NAME}/_all" ${data})

    local snapshots=$(echo ${es_response} | jq -r '.[] | sort_by(.start_time_in_millis) | reverse | .[]  | .snapshot')
    if [  -z "${snapshots}" ]; then
        bail "No snapshots were found on instance '${ELASTICSEARCH_HOST}'. Elasticsearch returned: ${es_response}"
    fi

    echo "${snapshots}"
}

# Clean up old Elasticsearch snapshots leaving the configured $KEEP_BACKUPS number of snapshots
function cleanup_es_snapshots {
    if [ "${KEEP_BACKUPS}" -gt 0 ]; then
        local snapshots=$(get_es_snapshots)
        local no_of_snapshots=$(echo "${snapshots}" | wc -l)
        local no_of_snapshots_to_delete=$((no_of_snapshots-${KEEP_BACKUPS}))

        if [ ${no_of_snapshots_to_delete} -gt 0 ]; then
            debug "There are '${no_of_snapshots}' Elasticsearch snapshots, '${no_of_snapshots_to_delete}' need to be cleaned up"
            local snapshots_to_clean=$(echo "${snapshots}" | tail -${no_of_snapshots_to_delete})
            for snapshot in ${snapshots_to_clean}; do
                delete_es_snapshot "${snapshot}"
            done
        else
            debug "There are '${no_of_snapshots}' Elasticsearch snapshots, nothing to clean up"
        fi

        success "Elasticsearch snapshot cleanup successful"
    fi
}

function curl_elasticsearch {
    local http_method=$1
    local path=$2
    local data=$3

    if [ "${BACKUP_ELASTICSEARCH_TYPE}" = "amazon-es" ]; then
        local es_response=$(run python ${SCRIPT_DIR}/aws_request_signer.py "es" "${AWS_REGION}" "${ELASTICSEARCH_HOST}" "${http_method}" "${path}" "${data}")
    else
        local es_response=$(run curl -s -u "${ELASTICSEARCH_USERNAME}:${ELASTICSEARCH_PASSWORD}" -X ${http_method} "http://${ELASTICSEARCH_HOST}${path}" -d "${data}")
    fi

    echo "${es_response}"
}