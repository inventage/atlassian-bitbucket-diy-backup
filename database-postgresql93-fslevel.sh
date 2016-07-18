#!/bin/bash

# Strategy for backing up and restoring a PostgreSQL 9.3 database whose data directory (i.e., ${PGDATA}) is inside the
# same file system volume as Bitbucket's home directory. In this configuration the whole database is backed up and
# restored implicitly as part of the bitbucket_backup_home and bitbucket_restore_home functions. So the functions
# implementing this strategy need to do little or no actual work.
#
# Note that recovery time after restoring a PostgreSQL database from a file system level backup may depend on the
# configuration of the PostgreSQL "hot_standby" and "wal_level" options.
#
# Refer to https://www.postgresql.org/docs/9.3/static/backup-file.html for more information.

SCRIPT_DIR=$(dirname $0)
source ${SCRIPT_DIR}/common.sh

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
    # Since the whole database is restored implicitly as part of the file system volume, this function doesn't need
    # to do any work.  All we need to do is stop the service beforehand.
    sudo service postgresql93 stop
}

function restore_db {
    # Since the whole database is restored implicitly as part of the file system volume, this function doesn't need
    # to do any work.  All we need to do is start the service back up again.
    sudo service postgresql93 start
}
