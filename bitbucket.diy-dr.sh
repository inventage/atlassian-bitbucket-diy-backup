#!/bin/bash

# -------------------------------------------------------------------------------------
# The DIY DR script.
#
# This script is invoked on the Primary Bitbucket Data Center instance. It requires a properly configured
# bitbucket.diy-backup.vars.sh file, which can be copied from
# bitbucket.diy-backup.vars.sh.example and customized.
# -------------------------------------------------------------------------------------

# Ensure the script terminates whenever a required operation encounters an error
set -e

SCRIPT_DIR=$(dirname "$0")
source "${SCRIPT_DIR}/utils.sh"
source "${SCRIPT_DIR}/common.sh"

##########################################################
prepare_replicate_home

replicate_home