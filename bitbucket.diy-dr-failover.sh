#!/bin/bash

# -------------------------------------------------------------------------------------
# The DR DIY failover scripts.
#
# This script is invoked to perform a failover of a Bitbucket Data Center instance.
# It requires the following configuration files:
#   bitbucket.diy-dr.vars.sh file, which can be copied from
#   bitbucket.diy-dr.vars.sh.example and customized.
# -------------------------------------------------------------------------------------

# Ensure the script terminates whenever a required operation encounters an error
set -e

SCRIPT_DIR=$(dirname "$0")
source "${SCRIPT_DIR}/utils.sh"
source "${SCRIPT_DIR}/common.sh"

##########################################################

info "Preparing for failover"

prepare_failover_db
prepare_failover_home

failover_db
failover_home

success "Successfully completed failover"
