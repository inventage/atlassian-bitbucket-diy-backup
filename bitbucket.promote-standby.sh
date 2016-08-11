#!/bin/bash

# -------------------------------------------------------------------------------------
# The Disaster Recovery script to promote a standby Bitbucket Data Center instance.
#
# Ensure you are using this script in accordance with the following document:
# https://confluence.atlassian.com/display/BitbucketServer/Bitbucket+Data+Center+disaster+recovery
#
# It requires the following configuration files:
#   bitbucket.diy-backup.vars.sh file, which can be copied from
#   bitbucket.diy-backup.vars.sh.example and customized.
# -------------------------------------------------------------------------------------

# Ensure the script terminates whenever a required operation encounters an error
set -e

SCRIPT_DIR=$(dirname "$0")
source "${SCRIPT_DIR}/utils.sh"
source "${SCRIPT_DIR}/common.sh"

##########################################################

info "Promoting standby Bitbucket Data Center"

promote_standby_db
promote_standby_home

success "Successfully promoted standby instance"

info "Ensure you continue the failover steps to successfully failover to your standby instance"
