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

BACKUP_VARS_FILE=${BACKUP_VARS_FILE:-"${SCRIPT_DIR}"/bitbucket.diy-backup.vars.sh}

if [ -f "${BACKUP_VARS_FILE}" ]; then
    source "${BACKUP_VARS_FILE}"
    info "Using vars file: '${BACKUP_VARS_FILE}'"
else
    error "'${BACKUP_VARS_FILE}' not found"
    bail "You should create it using '${SCRIPT_DIR}/bitbucket.diy-backup.vars.sh.example' as a template"
fi

# Ensure we know which user:group things should be owned as
if [ -z "${BITBUCKET_UID}" -o -z "${BITBUCKET_GID}" ]; then
    error "Both BITBUCKET_UID and BITBUCKET_GID must be set in '${BACKUP_VARS_FILE}'"
    bail "See 'bitbucket.diy-backup.vars.sh.example' for the defaults."
fi

if [ -e "${SCRIPT_DIR}/home-${BACKUP_HOME_TYPE}.sh" ]; then
    source "${SCRIPT_DIR}/home-${BACKUP_HOME_TYPE}.sh"
else
    error "BACKUP_HOME_TYPE=${BACKUP_HOME_TYPE} is not implemented, '${SCRIPT_DIR}/home-${BACKUP_HOME_TYPE}.sh' does not exist"
    bail "Please update BACKUP_HOME_TYPE in '${BACKUP_VARS_FILE}'"
fi

if [ -e "${SCRIPT_DIR}/database-${BACKUP_DATABASE_TYPE}.sh" ]; then
    source "${SCRIPT_DIR}/database-${BACKUP_DATABASE_TYPE}.sh"
else
    error "BACKUP_DATABASE_TYPE=${BACKUP_DATABASE_TYPE} is not implemented, '${SCRIPT_DIR}/database-${BACKUP_DATABASE_TYPE}.sh' does not exist"
    bail "Please update BACKUP_DATABASE_TYPE in '${BACKUP_VARS_FILE}'"
fi

if [ -e "${SCRIPT_DIR}/archive-${BACKUP_ARCHIVE_TYPE}.sh" ]; then
    source "${SCRIPT_DIR}/archive-${BACKUP_ARCHIVE_TYPE}.sh"
fi

##########################################################

# Prepare for restore process
if [ -n "${BACKUP_ARCHIVE_TYPE}" ]; then
    prepare_restore_archive "${1}"
fi

info "Preparing for home and database restore"

prepare_restore_home
prepare_restore_db "${1}"

if [ -n "${BACKUP_ARCHIVE_TYPE}" ]; then
    restore_archive "${1}"
fi

info "Restoring home directory and database"

# Restore the filesystem
restore_home

# Restore the database
restore_db

success "Successfully completed the restore of your ${PRODUCT} instance"
