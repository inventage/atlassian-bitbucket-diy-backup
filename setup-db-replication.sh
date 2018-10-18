#!/bin/bash

# -------------------------------------------------------------------------------------
# The Disaster Recovery script to configure Bitbucket Data Center database replication for DR
#
# Ensure you are using this script in accordance with the following document:
# https://confluence.atlassian.com/display/BitbucketServer/Disaster+recovery+guide+for+Bitbucket+Data+Center
#
# It requires the following configuration file:
#   bitbucket.diy-backup.vars.sh
#   which can be copied from bitbucket.diy-backup.vars.sh.example and customized.
# -------------------------------------------------------------------------------------

# Ensure the script terminates whenever a required operation encounters an error
set -e

SCRIPT_DIR=$(dirname "$0")
source "${SCRIPT_DIR}/utils.sh"
source "${SCRIPT_DIR}/common.sh"
source_disaster_recovery_database_strategy

##########################################################
setup_db_replication
