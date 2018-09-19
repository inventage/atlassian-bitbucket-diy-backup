#!/bin/bash

# -------------------------------------------------------------------------------------
# The home replication script, invoked on the primary Bitbucket Data Center file server
# to replicate the file system to the standby.
#
# Ensure you are using this script in accordance with the following document:
# https://confluence.atlassian.com/display/BitbucketServer/Bitbucket+Data+Center+disaster+recovery
#
# It requires a properly configured bitbucket.diy-backup.vars.sh file,
# which can be copied and customized from bitbucket.diy-backup.vars.sh.example.
# -------------------------------------------------------------------------------------

# Ensure the script terminates whenever a required operation encounters an error
set -e

SCRIPT_DIR=$(dirname "$0")
source "${SCRIPT_DIR}/utils.sh"
source "${SCRIPT_DIR}/common.sh"
source_disaster_recovery_disk_strategy

##########################################################
REPLICATE_LOCK_FILE="/tmp/replicate-lock.pid"

function acquire_replicate_lock {
    set -o noclobber
    if ! echo "$$" > "${REPLICATE_LOCK_FILE}"; then
        local other_pid=$(cat "${REPLICATE_LOCK_FILE}")
        # Check if the other process is alive
        if run kill -0 "${other_pid}" 2>/dev/null; then
            bail "Replication is currently in progress by process with PID '${other_pid}', cannot continue."
        else
            debug "Lock file is held by process with PID '${other_pid}', but it is not running. Taking lock."
            set +o noclobber
            echo "$$" > "${REPLICATE_LOCK_FILE}"
        fi
    fi
    set +o noclobber
}

function release_replicate_lock {
    rm -f "${REPLICATE_LOCK_FILE}"
}

acquire_replicate_lock
add_cleanup_routine release_replicate_lock

replicate_disk
