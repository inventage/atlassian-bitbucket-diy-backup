# ---------------------------------------------------------------------------
# A backup and restore strategy for PostgreSQL running in a Docker container.
# ---------------------------------------------------------------------------

check_command "docker"

DB_BACKUP_FILENAME="bitbucket.dump"

function prepare_backup_db {
    check_config_var "BITBUCKET_BACKUP_DB"
    check_config_var "POSTGRES_USERNAME"
    check_config_var "POSTGRES_CONTAINER"
    check_config_var "BITBUCKET_DB"
}

function backup_db {
    DB_BACKUP_FILE="${BITBUCKET_BACKUP_DB}/${DB_BACKUP_FILENAME}"

    mkdir -p "${BITBUCKET_BACKUP_DB}"
    rm -f "${DB_BACKUP_FILE}"

    run postgres_command pg_dump -U "${POSTGRES_USERNAME}" -Fc \
        "${BITBUCKET_DB}" > "${DB_BACKUP_FILE}"
}

function prepare_restore_db {
    check_config_var "POSTGRES_USERNAME"
    check_config_var "POSTGRES_CONTAINER"
    check_var "BITBUCKET_RESTORE_DB"

    if run postgres_command psql -U "${POSTGRES_USERNAME}" -d "${BITBUCKET_DB}" -c "" ; then
        local table_count=$(postgres_command psql -U "${POSTGRES_USERNAME}" -d "${BITBUCKET_DB}" -tqc '\dt' | grep -v "^$" | wc -l)
        if [ "${table_count}" -gt 0 ]; then
            error "Database '${BITBUCKET_DB}' already contains ${table_count} tables"
            bail "Cannot restore over existing tables in database '${BITBUCKET_DB}', please ensure it is empty before restoring"
        fi
    fi
}

function restore_db {
    run postgres_command pg_restore -U "${POSTGRES_USERNAME}" -d "${BITBUCKET_DB}" \
        --no-privileges --no-owner --exit-on-error < "${BITBUCKET_RESTORE_DB}/${DB_BACKUP_FILENAME}"
}

function cleanup_incomplete_db_backup {
    info "Cleaning up DB backup created as part of failed/incomplete backup"
    rm -r "${BITBUCKET_BACKUP_DB}"
}

function cleanup_old_db_backups {
    # Not required as old backups with this strategy are typically cleaned up in the archiving strategy.
    no_op
}

#-----------------------------------------------------------------------------------------------------------------------
# Private functions
#-----------------------------------------------------------------------------------------------------------------------

function postgres_command {
    docker exec -i "$POSTGRES_CONTAINER" "$@"
}
