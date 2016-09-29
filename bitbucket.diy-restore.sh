#!/bin/bash

# -------------------------------------------------------------------------------------
# The DIY restore script.
#
# This script is invoked to perform a restore of a Bitbucket Server,
# or Bitbucket Data Center instance. It requires a properly configured
# bitbucket.diy-backup.vars.sh file, which can be copied from
# bitbucket.diy-backup.vars.sh.example and customized.
# -------------------------------------------------------------------------------------

# Ensure the script terminates whenever a required operation encounters an error
set -e

SCRIPT_DIR=$(dirname "$0")
source "${SCRIPT_DIR}/utils.sh"
source "${SCRIPT_DIR}/common.sh"
source_archive_strategy
source_database_strategy
source_home_strategy
source_elasticsearch_strategy

# Ensure we know which user:group things should be owned as
if [ -z "${BITBUCKET_UID}" -o -z "${BITBUCKET_GID}" ]; then
    error "Both BITBUCKET_UID and BITBUCKET_GID must be set in '${BACKUP_VARS_FILE}'"
    bail "See 'bitbucket.diy-backup.vars.sh.example' for the defaults."
fi

check_command "jq"

##########################################################

# Prepare for restore process
if [ -n "${BACKUP_ARCHIVE_TYPE}" ]; then
    prepare_restore_archive "${1}"
fi

info "Preparing for restore"

prepare_restore_home "${1}"
prepare_restore_db "${1}"
prepare_restore_elasticsearch "${1}"

if [ -n "${BACKUP_ARCHIVE_TYPE}" ]; then
    restore_archive
fi

info "Restoring home directory and database"

# Restore the filesystem
restore_home

# Restore the database
restore_db

# Restore Elasticsearch data
restore_elasticsearch

success "Successfully completed the restore of your ${PRODUCT} instance"

if [ -n "${FINAL_MESSAGE}" ]; then
    echo "${FINAL_MESSAGE}"
fi
