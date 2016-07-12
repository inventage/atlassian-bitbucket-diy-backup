#!/bin/bash

# We assume that these scripts are running in cygwin so we need to transfrom from unix path to windows path
BITBUCKET_BACKUP_WIN_DB=`cygpath -aw "${BITBUCKET_BACKUP_DB}"`

function bitbucket_prepare_db {
    sqlcmd -Q "BACKUP DATABASE ${BITBUCKET_DB} to disk='${BITBUCKET_BACKUP_WIN_DB}'"
}

function bitbucket_backup_db {
    sqlcmd -Q "BACKUP DATABASE ${BITBUCKET_DB} to disk='${BITBUCKET_BACKUP_WIN_DB}' WITH DIFFERENTIAL"
}

function bitbucket_cleanup_db_backups {
    no_op
}

