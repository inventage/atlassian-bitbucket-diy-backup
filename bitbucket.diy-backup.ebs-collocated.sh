#!/bin/bash

# This script is meant to be used when the database data directory is collocated in the same volume
# as the home directory. In that scenario 'bitbucket.diy-backup.ebs-home.sh' should be enough to backup / restore a Bitbucket instance.

SCRIPT_DIR=$(dirname $0)
source ${SCRIPT_DIR}/bitbucket.diy-backup.ec2-common.sh

function prepare_backup_db {
    no_op
}

function backup_db {
    no_op
}

function prepare_restore_db {
    # When PostgreSQL is running as a service with its data on the same volume as the home directory, all its data will
    # restored implicitly when the home volume is restored.  All we need to do is stop the service beforehand.
    sudo service postgresql93 stop
}

function restore_db {
    # All of PostgreSQL's data has already been restored with the home directory volume.  All we need to do is start
    # the service back up again.
    sudo service postgresql93 start
}
