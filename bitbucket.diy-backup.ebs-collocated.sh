#!/bin/bash

# This script is meant to be used when the database data directory is collocated in the same volume
# as the home directory. In that scenario 'bitbucket.diy-backup.ebs-home.sh' should be enough to backup / restore a Bitbucket instance.

function no_op {
    echo > /dev/null
}

function bitbucket_prepare_db {
    no_op
}

function bitbucket_backup_db {
   no_op
}

function bitbucket_prepare_db_restore {
    no_op
}

function bitbucket_restore_db {
    no_op
}

function cleanup_old_db_snapshots {
    no_op
}
