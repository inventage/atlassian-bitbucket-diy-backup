#!/bin/bash

# This script is meant to be used when the database data directory is collocated in the same volume
# as the home directory. In that scenario 'stash.diy-backup.ebs-home.sh' should be enough to backup / restore a Stash instance.

function no_op {
    echo > /dev/null
}

function stash_backup_db {
   no_op
}

function stash_restore_db {
    no_op
}