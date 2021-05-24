#!/bin/bash
# -------------------------------------------------------------------------------------
# A backup and restore strategy for MySQL
# -------------------------------------------------------------------------------------

check_command "mysqldump"
#check_command "mysqlshow"
check_command "mysql"

#Check if BITBUCKET_BACKUP_DB is a file or directory
if [ "${BITBUCKET_BACKUP_DB: -1}" == '/' ]; then
  BITBUCKET_BACKUP_DB_FILE=${BITBUCKET_BACKUP_DB}backup-db.sql
else
  BITBUCKET_BACKUP_DB_FILE=${BITBUCKET_BACKUP_DB}/backup-db.sql
fi

# Use -h option if MYSQL_HOST is set
if [ -n ${MYSQL_HOST} ]; then
  MYSQL_HOST_CMD="-h ${MYSQL_HOST}"
fi

function prepare_backup_db {
  check_config_var "BITBUCKET_DB"
  check_config_var "BITBUCKET_BACKUP_DB"
  check_config_var "MYSQL_USERNAME"
  check_config_var "MYSQL_PASSWORD"
  info "Prepared backup of DB ${BITBUCKET_DB} in ${BITBUCKET_BACKUP_DB}"
}

function backup_db {
  if [ -f "${BITBUCKET_BACKUP_DB_FILE}" ]; then
    rm "${BITBUCKET_BACKUP_DB_FILE}"
  fi
  run mysqldump --no-tablespaces ${MYSQL_HOST_CMD} ${MYSQL_BACKUP_OPTIONS} -u "${MYSQL_USERNAME}" -p"${MYSQL_PASSWORD}" \
    --databases "${BITBUCKET_DB}" >"${BITBUCKET_BACKUP_DB_FILE}"
}

function prepare_restore_db {
  check_config_var "BITBUCKET_DB"
  check_var "BITBUCKET_RESTORE_DB"
  check_config_var "MYSQL_USERNAME"
  check_config_var "MYSQL_PASSWORD"
  #run mysqlshow "${MYSQL_HOST_CMD}" -u "${MYSQL_USERNAME}" -p"${MYSQL_PASSWORD}" "${BITBUCKET_DB}"
  info "Prepared restore of ${BITBUCKET_DB}"
}

function restore_db {
  BITBUCKET_RESTORE_DB_FILE=${BITBUCKET_RESTORE_DB}/backup-db.sql
  run mysql ${MYSQL_HOST_CMD} -u "${MYSQL_USERNAME}" -p"${MYSQL_PASSWORD}" <"${BITBUCKET_RESTORE_DB_FILE}"
}

function cleanup_incomplete_db_backup {
  info "Cleaning up DB backup created as part of failed/incomplete backup"
  if [ -f "${BITBUCKET_BACKUP_DB_FILE}" ]; then
    rm "${BITBUCKET_BACKUP_DB_FILE}"
  fi
}

function cleanup_old_db_backups {
  # Not required as old backups with this strategy are typically cleaned up in the archiving strategy.
  no_op
}

# ----------------------------------------------------------------------------------------------------------------------
# Disaster recovery functions
# ----------------------------------------------------------------------------------------------------------------------

function promote_db {
  bail "Disaster recovery is not available with this database strategy"
}

function setup_db_replication {
  bail "Disaster recovery is not available with this database strategy"
}

