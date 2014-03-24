#!/bin/bash

# We assume that these scripts are running in cygwin so we need to transfrom from unix path to windows path
STASH_BACKUP_WIN_DB=`cygpath -aw "${STASH_BACKUP_DB}"`

function stash_prepare_db {
    sqlcmd -Q "BACKUP DATABASE ${STASH_DB} to disk='${STASH_BACKUP_WIN_DB}'"
}

function stash_backup_db {
    sqlcmd -Q "BACKUP DATABASE ${STASH_DB} to disk='${STASH_BACKUP_WIN_DB}' WITH DIFFERENTIAL"
}

