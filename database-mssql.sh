#!/bin/bash

SCRIPT_DIR=$(dirname "$0")
source "${SCRIPT_DIR}/utils.sh"

# We assume that these scripts are running in cygwin so we need to transform from unix path to windows path
BITBUCKET_BACKUP_WIN_DB=$(cygpath -aw "${BITBUCKET_BACKUP_DB}")

function bitbucket_prepare_db {
    run sqlcmd -Q "BACKUP DATABASE ${BITBUCKET_DB} to disk='${BITBUCKET_BACKUP_WIN_DB}'"
}

function bitbucket_backup_db {
    run sqlcmd -Q "BACKUP DATABASE ${BITBUCKET_DB} to disk='${BITBUCKET_BACKUP_WIN_DB}' WITH DIFFERENTIAL"
}

function prepare_restore_db {
    no_op
}

function restore_db {
    no_op
}
