# -------------------------------------------------------------------------------------
# A backup and restore strategy for PostgreSQL whose data directory (i.e., ${PGDATA}) resides on the same file
# system volume as Bitbucket's home directory. In this configuration the whole database is backed up and restored
# implicitly as part of the bitbucket_backup_home and bitbucket_restore_home functions. So the functions
# implementing this strategy need to do little or no actual work.
#
# Note that recovery time after restoring a PostgreSQL database from a file system level backup may depend on the
# configuration of the PostgreSQL "hot_standby" and "wal_level" options.
#
# Refer to https://www.postgresql.org/docs/9.5/static/backup-file.html for more information.
# -------------------------------------------------------------------------------------

function prepare_backup_db {
    # Since the whole database is backed up implicitly as part of the file system volume, this function doesn't need
    # to do any work.
    no_op
}

function backup_db {
    # Since the whole database is backed up implicitly as part of the file system volume, this function doesn't need
    # to do any work.
    no_op
}

function prepare_restore_db {
    check_config_var "POSTGRESQL_SERVICE_NAME"
    # Since the whole database is restored implicitly as part of the file system volume, this function doesn't need
    # to do any work.  All we need to do is stop the service beforehand.
    run sudo service "${POSTGRESQL_SERVICE_NAME}" stop

    # Add a clean up routine to ensure we always start the PostgreSQL service back up again
    add_cleanup_routine restore_db
}

function restore_db {
    remove_cleanup_routine restore_db

    # Since the whole database is restored implicitly as part of the file system volume, this function doesn't need
    # to do any work.  All we need to do is start the service back up again.
    run sudo service "${POSTGRESQL_SERVICE_NAME}" start
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

function cleanup_incomplete_db_backup {
    # Not required as the database is backed up implicitly as part of the file system volume.
    no_op
}

function cleanup_old_db_backups {
    # Not required as the database is backed up implicitly as part of the file system volume.
    no_op
}
