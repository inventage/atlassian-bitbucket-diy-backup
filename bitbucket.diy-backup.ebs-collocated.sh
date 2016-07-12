#!/bin/bash

# This script is meant to be used when the database data directory is collocated in the same volume
# as the home directory. In that scenario 'bitbucket.diy-backup.ebs-home.sh' should be enough to backup / restore a Bitbucket instance.

source ${SCRIPT_DIR}/bitbucket.diy-backup.ec2-common.sh

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
