# ----------------------------------------------------------------------------------------------------------------------
# The AWS Elasticsearch service strategy for Backup and restore
# ----------------------------------------------------------------------------------------------------------------------

check_config_var "ELASTICSEARCH_HOST"
check_config_var "ELASTICSEARCH_REPOSITORY_NAME"

# ----------------------------------------------------------------------------------------------------------------------
# Backup and restore functions
# ----------------------------------------------------------------------------------------------------------------------

function prepare_backup_elasticsearch {
    ensure_aws_es_snapshot_repo_configured
}

function backup_elasticsearch {
    create_aws_es_snapshot
}

function prepare_restore_elasticsearch {
    check_config_var "ELASTICSEARCH_INDEX_NAME"

    ensure_aws_es_missing_index
    ensure_aws_es_snapshot_repo_configured
    validate_aws_es_snapshot "$1"
}

function restore_elasticsearch {
    check_var "RESTORE_ELASTICSEARCH_SNAPSHOT"

    restore_aws_es_snapshot
}

function cleanup_elasticsearch_backups {
    if [ "${KEEP_BACKUPS}" -gt 0 ]; then
        get_aws_es_snapshots

        local no_of_snapshots=$(echo "${ES_SNAPSHOTS}" | wc -l)
        local no_of_snapshots_to_delete=$((no_of_snapshots-${KEEP_BACKUPS}))

        if [ ${no_of_snapshots_to_delete} -gt 0 ]; then
            debug "There are '${no_of_snapshots}' Elasticsearch snapshots, '${no_of_snapshots_to_delete}' need to be cleaned up"
            local snapshots_to_clean=$(echo "${ES_SNAPSHOTS}" | tail -${no_of_snapshots_to_delete})

            for snapshot in ${snapshots_to_clean}; do
                delete_aws_es_snapshot "${snapshot}"
            done
        else
            debug "There are '${no_of_snapshots}' Elasticsearch snapshots, nothing to clean up"
        fi

        success "Elasticsearch snapshot cleanup successful"
    fi
}

# ----------------------------------------------------------------------------------------------------------------------
# Private Functions
# ----------------------------------------------------------------------------------------------------------------------

# Configures the AWS Elasticsearch domain to use a specified S3 bucket as the snapshot repository
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
    info "Creating Elasticsearch S3 snapshot repository with name '${ELASTICSEARCH_REPOSITORY_NAME}' on server '${ELASTICSEARCH_HOST}'"

    curl_aws_es "POST" "/_snapshot/${ELASTICSEARCH_REPOSITORY_NAME}" "${data}"

    success "Created Elasticsearch S3 snapshot repository '${ELASTICSEARCH_REPOSITORY_NAME}' on server '${ELASTICSEARCH_HOST}'."
}

# Creates an AWS Elasticsearch snapshot
function create_aws_es_snapshot {
    check_config_var "ELASTICSEARCH_INDEX_NAME"
    check_var "SNAPSHOT_TAG_VALUE"

    local snapshot_name="${SNAPSHOT_TAG_VALUE}"
    local data=$(cat << EOF
{
   "indices": "${ELASTICSEARCH_INDEX_NAME}",
   "ignore_unavailable": "true",
   "include_global_state": false
}
EOF
)
    curl_aws_es "PUT" "/_snapshot/${ELASTICSEARCH_REPOSITORY_NAME}/${snapshot_name}" "${data}"
}

# Sets environmental variables then executes a python script that will sign a AWS ES request
function curl_aws_es {
    local http_method=$1
    local path=$2
    local data=$3

    export ES_AWS_REGION=$AWS_REGION
    export ES_HOST=$ELASTICSEARCH_HOST
    export ES_HTTP_METHOD=$http_method
    export ES_PATH=$path
    export ES_DATA=$data

    debug "Signing request to '${ELASTICSEARCH_HOST}'"
    debug "${http_method} ${path} '${data}'"

    ES_RESPONSE=$(python ./es_aws_request_signer.py)

    debug "AWS request returned: '${ES_RESPONSE}'"
}

# Deletes an AWS Elasticsearch snapshot
function delete_aws_es_snapshot {
    local snapshot_name="$1"

    debug "Deleting Elasticsearch snapshot '${snapshot_name}' on server '${ELASTICSEARCH_HOST}'"

    curl_aws_es "DELETE" "/_snapshot/${ELASTICSEARCH_REPOSITORY_NAME}/${snapshot_name}"

    if [ "$(echo ${ES_RESPONSE} | jq -r '.acknowledged')" = "true" ]; then
        debug "Successfully deleted snapshot '${snapshot_name}'"
    else
        info "Failed to delete snapshot '${snapshot_name}', Elasticsearch responded with ${ES_RESPONSE}"
    fi
}

# Ensures that the Elasticsearch domain doesn't contain an index called ELASTICSEARCH_INDEX_NAME
function ensure_aws_es_missing_index {
    info "Checking whether index with name '${ELASTICSEARCH_INDEX_NAME}' exists on server '${ELASTICSEARCH_HOST}'"

    curl_aws_es "GET" "/${ELASTICSEARCH_INDEX_NAME}"

    if [ "$(echo ${ES_RESPONSE} | jq -r '.error .type')" != "index_not_found_exception" ]; then
        bail "An index with name '${ELASTICSEARCH_INDEX_NAME}' exists on server '${ELASTICSEARCH_HOST}', please remove it before restoring"
    fi
}

# Ensure AWS Elasticsearch snapshot repository is correctly configured
function ensure_aws_es_snapshot_repo_configured {
    curl_aws_es "GET" "/_snapshot/${ELASTICSEARCH_REPOSITORY_NAME}"

    if [ "$(echo ${ES_RESPONSE} | jq -r '.error .type')" = "repository_missing_exception" ]; then
        configure_aws_es_snapshot_repository
    elif [[ "${ES_RESPONSE}" == *"${ELASTICSEARCH_REPOSITORY_NAME}"* ]]; then
        debug "The snapshot repository '${ELASTICSEARCH_REPOSITORY_NAME}' already exists on server '${ELASTICSEARCH_HOST}'"
    else
        bail "Elasticsearch snapshot repository configuration failed with ${ES_RESPONSE}"
    fi
}

# Queries the AWS Elasticsearch domain for available snapshots
function get_aws_es_snapshots {
    curl_aws_es "GET" "/_snapshot/${ELASTICSEARCH_REPOSITORY_NAME}/_all" '{"ignore_unavailable": "true"}'

    local snapshots=$(echo ${ES_RESPONSE} | jq -r '.[] | sort_by(.start_time_in_millis) | reverse | .[]  | .snapshot')

    if [  -z "${snapshots}" ]; then
        bail "No snapshots were found on server '${ELASTICSEARCH_HOST}'. Elasticsearch returned: ${ES_RESPONSE}"
    fi

    ES_SNAPSHOTS="${snapshots}"
}

# Restore the Elasticsearch domain using RESTORE_ELASTICSEARCH_SNAPSHOT
function restore_aws_es_snapshot {
    local data=$(cat << EOF
{
  "indices": "${ELASTICSEARCH_INDEX_NAME}",
  "ignore_unavailable": true,
  "include_global_state": false,
  "include_aliases": true
}
EOF
)
    debug "Restoring Elasticsearch snapshot '${RESTORE_ELASTICSEARCH_SNAPSHOT}' on server '${ELASTICSEARCH_HOST}'"

    curl_aws_es "POST" "/_snapshot/${ELASTICSEARCH_REPOSITORY_NAME}/${RESTORE_ELASTICSEARCH_SNAPSHOT}/_restore" "${data}"

    if [ "$(echo ${ES_RESPONSE} | jq -r '.snapshot.snapshot')" != "${RESTORE_ELASTICSEARCH_SNAPSHOT}" ]; then
        if [ "$(echo ${ES_RESPONSE} | jq -r '.accepted')" != "true" ]; then
            bail "Unable to restore snapshot '${RESTORE_ELASTICSEARCH_SNAPSHOT}' on ${server_type} server '${ELASTICSEARCH_HOST}'. Elasticsearch returned: ${ES_RESPONSE}"
        fi
    fi

    success "Elasticsearch index '${ELASTICSEARCH_INDEX_NAME}' has been restored from snapshot '${RESTORE_ELASTICSEARCH_SNAPSHOT}' on server '${ELASTICSEARCH_HOST}'."
    info "The index will be available as soon as index recovery completes, it might take a little while."
}

# Validates the user input snapshot_tag to ensure it exists in the snapshot repository
function validate_aws_es_snapshot {
    local snapshot_tag="$1"

    debug "Getting snapshot list from Elasticsearch server '${ELASTICSEARCH_HOST}'"
    get_aws_es_snapshots

    if [ -z "${snapshot_tag}" ]; then
        info "Available Snapshots:"
        echo "${ES_SNAPSHOTS}"
        bail "Please select a snapshot to restore"
    fi

    debug "Validating Elasticsearch snapshot '${snapshot_tag}'"
    local has_snapshot=$(echo "${ES_SNAPSHOTS}" | grep "${snapshot_tag}")
    if [ -z "${has_snapshot}" ]; then
        error "Unable to find snapshot '${snapshot_tag}' in the list of Elasticsearch snapshots:"
        info "Available Snapshots:"
        echo "${snapshot_list}"
        bail "Please select a snapshot to restore"
    fi

    RESTORE_ELASTICSEARCH_SNAPSHOT=${snapshot_tag}
}
