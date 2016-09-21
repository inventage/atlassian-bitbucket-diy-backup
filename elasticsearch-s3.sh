# ----------------------------------------------------------------------------------------------------------------------
# The Amazon S3 based Elasticsearch strategy for Backup and restore
#
# This script depends on elasticsearch-common.sh
# ----------------------------------------------------------------------------------------------------------------------

check_command "jq"
check_command "curl"

# ----------------------------------------------------------------------------------------------------------------------
# Backup and restore functions
# ----------------------------------------------------------------------------------------------------------------------

# See elasticsearch-common.sh for the implementation(s) of:
#  - backup_elasticsearch
#  - restore_elasticsearch

