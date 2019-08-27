# -------------------------------------------------------------------------------------
# A backup and restore strategy for Microsoft SQL Server
# -------------------------------------------------------------------------------------

# We assume that these scripts are running in cygwin so we need to transform from unix path to windows path
BITBUCKET_BACKUP_WIN_DB=$(cygpath -aw "${BITBUCKET_BACKUP_DB}")

function bitbucket_prepare_db {
    run sqlcmd -Q "BACKUP DATABASE ${BITBUCKET_DB} to disk='${BITBUCKET_BACKUP_WIN_DB}'"
}

function bitbucket_backup_db {
    run sqlcmd -Q "BACKUP DATABASE ${BITBUCKET_DB} to disk='${BITBUCKET_BACKUP_WIN_DB}' WITH DIFFERENTIAL"
}

function prepare_restore_db {
    # This method has not yet been implemented
    no_op
}

function restore_db {
    # This method has not yet been implemented
    no_op
}

function cleanup_incomplete_db_backup {
    # Not required as old backups with this strategy are typically cleaned up in the archiving strategy.
    no_op
}

function cleanup_old_db_backups {
    # Not required as old backups with this strategy are typically cleaned up in the archiving strategy.
    no_op
}

# ----------------------------------------------------------------------------------------------------------------------
# Disaster recovery functions
# ----------------------------------------------------------------------------------------------------------------------

function promote_db {
    bail "Disaster recovery is not available with this database strategy"
}

function setup_db_replication {
    bail "Disaster recovery is not available with this database strategy"
}
