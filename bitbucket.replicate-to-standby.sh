#!/bin/bash

# -------------------------------------------------------------------------------------
# The replicate-to-standby script, invoked on the primary Bitbucket Data Center instance to replicate
# the file system and database to the standby.
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

##########################################################

replicate_home
