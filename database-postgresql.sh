# -------------------------------------------------------------------------------------
# A backup and restore strategy for PostgreSQL with "pg_dump" and "pg_restore" commands.
# -------------------------------------------------------------------------------------

check_command "pg_dump"
check_command "psql"
check_command "pg_restore"

# Make use of PostgreSQL 9.3+ options if available
if [[ ${psql_majorminor} -ge 9003 ]]; then
    PG_PARALLEL="-j 5"
    PG_SNAPSHOT_OPT="--no-synchronized-snapshots"
fi

function prepare_backup_db {
    check_config_var "BITBUCKET_BACKUP_DB"
    check_config_var "POSTGRES_USERNAME"
    check_config_var "POSTGRES_HOST"
    check_config_var "POSTGRES_PORT"
    check_config_var "BITBUCKET_DB"
}

function backup_db {
    rm -r "${BITBUCKET_BACKUP_DB}"
    run pg_dump -U "${POSTGRES_USERNAME}" -h "${POSTGRES_HOST}" --port=${POSTGRES_PORT} ${PG_PARALLEL} -Fd \
        "${BITBUCKET_DB}" ${PG_SNAPSHOT_OPT} -f "${BITBUCKET_BACKUP_DB}"
}

function prepare_restore_db {
    check_config_var "POSTGRES_USERNAME"
    check_config_var "POSTGRES_HOST"
    check_config_var "POSTGRES_PORT"
    check_var "BITBUCKET_RESTORE_DB"

    if ! run psql -U "${POSTGRES_USERNAME}" -h "${POSTGRES_HOST}" --port=${POSTGRES_PORT} --list > /dev/null 2>&1; then
        bail "Unable to get a list of databases from database server '${POSTGRES_HOST}'"
    fi

    local db_exists=$(run psql -U "${POSTGRES_USERNAME}" -h "${POSTGRES_HOST}" --port=${POSTGRES_PORT} -qlt 2> /dev/null | grep -w "${BITBUCKET_DB}")
    if [ -n "${db_exists}" ]; then
        local table_count=$(psql -U "${POSTGRES_USERNAME}" -h "${POSTGRES_HOST}" --port=${POSTGRES_PORT} -d "${BITBUCKET_DB}" -tqc '\dt' | grep -v "^$" | wc -l)
        if [ "${table_count}" -gt 0 ]; then
            error "Database '${BITBUCKET_DB}' already exists and contains ${table_count} tables"
        else
            error "Database '${BITBUCKET_DB}' already exists"
        fi
        bail "Cannot restore over existing database '${BITBUCKET_DB}', please ensure it does not exist before restoring"
    fi
}

function restore_db {
    run pg_restore -U "${POSTGRES_USERNAME}" -h "${POSTGRES_HOST}" --port=${POSTGRES_PORT} ${PG_PARALLEL} \
        -d postgres -C -Fd "${BITBUCKET_RESTORE_DB}"
}

function cleanup_db_backups {
    # Not required as old backups with this strategy are typically cleaned up in the archiving strategy.
    no_op
}

# ----------------------------------------------------------------------------------------------------------------------
# Disaster recovery functions
# ----------------------------------------------------------------------------------------------------------------------

# Promote a standby database to take over from the primary, as part of a disaster recovery failover process
function promote_db {
    check_command "pg_ctl"

    check_config_var "STANDBY_DATABASE_SERVICE_USER"
    check_config_var "STANDBY_DATABASE_REPLICATION_USER_USERNAME"
    check_config_var "STANDBY_DATABASE_REPLICATION_USER_PASSWORD"
    check_config_var "STANDBY_DATABASE_DATA_DIR"

    local is_in_recovery=$(PGPASSWORD="${STANDBY_DATABASE_REPLICATION_USER_PASSWORD}" \
            run psql -U "${STANDBY_DATABASE_REPLICATION_USER_USERNAME}" -d "${BITBUCKET_DB}" -tqc "SELECT pg_is_in_recovery()")
    case "${is_in_recovery/ }" in
        "t")
            ;;
        "f")
            bail "Cannot promote standby PostgreSQL database, because it is already running as a primary database."
            ;;
        "")
            bail "Cannot promote standby PostgreSQL database."
            ;;
        *)
            bail "Cannot promote standby PostgreSQL database, got unexpected result '${is_in_recovery}'."
            ;;
    esac

    info "Promoting standby database instance"
    # Run pg_ctl in the root ( / ) folder to avoid warnings about user directory permissions.
    # Also ensure the command is run as the same user that is running the PostgreSQL service.
    # Because we have password-less sudo, we use su to execute the pg_ctl command
    run sudo su "${STANDBY_DATABASE_SERVICE_USER}" -c "cd / ; pg_ctl -D '${STANDBY_DATABASE_DATA_DIR}' promote"

    success "Promoted PostgreSQL standby instance"
}

# Configures a standby PostgreSQL database (which must be accessible locally by the "pg_basebackup" command) to
# replicate from the primary PostgreSQL database specified by the POSTGRES_HOST, POSTGRES_DB, etc. variables.
function setup_db_replication {
    check_command "pg_basebackup"

    check_config_var "POSTGRES_HOST"
    # Checks to see if the primary instance is set up for replication
    info "Checking primary PostgreSQL server '${POSTGRES_HOST}'"
    validate_primary_db
    debug "Primary checks were successful"

    # Checks and configures standby instance for replication
    info "Setting up standby PostgreSQL instance"
    check_config_var "STANDBY_DATABASE_SERVICE_NAME"
    check_config_var "STANDBY_DATABASE_SERVICE_USER"
    check_config_var "STANDBY_DATABASE_REPLICATION_USER_USERNAME"
    check_config_var "STANDBY_DATABASE_REPLICATION_USER_PASSWORD"
    check_config_var "STANDBY_DATABASE_DATA_DIR"

    # Run command from the root ( / ) folder and ensure the command is run as the same user that is running the
    # PostgreSQL service. Because we have password-less sudo, we use su to execute the pg_basebackup command, and
    # ensure we pass the correct password to the shell that is executing it.
    info "Transferring base backup from primary to standby PostgreSQL, this could take a while depending on database size and bandwidth available"
    run sudo su "${STANDBY_DATABASE_SERVICE_USER}" -c "cd / ; PGPASSWORD='${STANDBY_DATABASE_REPLICATION_USER_PASSWORD}' \
        pg_basebackup -D '${STANDBY_DATABASE_DATA_DIR}' -R -P -x -h '${POSTGRES_HOST}' -U '${STANDBY_DATABASE_REPLICATION_USER_USERNAME}'"

    local slot_config="primary_slot_name = '${STANDBY_DATABASE_REPLICATION_SLOT_NAME}'"
    debug "Appending '${slot_config}' to '${STANDBY_DATABASE_DATA_DIR}/recovery.conf'"
    sudo su "${STANDBY_DATABASE_SERVICE_USER}" -c "echo '${slot_config}' >> '${STANDBY_DATABASE_DATA_DIR}/recovery.conf'"

    run sudo service "${STANDBY_DATABASE_SERVICE_NAME}" start
    success "Standby setup was successful"
}

#-----------------------------------------------------------------------------------------------------------------------
# Private functions
#-----------------------------------------------------------------------------------------------------------------------

function get_config_setting {
    local var_name="$1"
    local var_value=$(run psql -U "${POSTGRES_USERNAME}" -h "${POSTGRES_HOST}" --port=${POSTGRES_PORT} \
        -d "${BITBUCKET_DB}" -tqc "SHOW ${var_name}")
    echo "${var_value/ }"
}

function validate_primary_db {
    if [ "$(get_config_setting wal_level)" != "hot_standby" ]; then
        bail "Primary instance is not configured correctly. Update postgresql.conf, set 'wal_level' to 'hot_standby'"
    fi

    if [ "$(get_config_setting max_wal_senders)" -lt 1 ]; then
        bail "Primary instance is not configured correctly. Update postgresql.conf with valid 'max_wal_senders'"
    fi

    if [ "$(get_config_setting wal_keep_segments)" -lt 1 ]; then
        bail "Primary instance is not configured correctly. Update postgresql.conf with valid 'wal_keep_segments'"
    fi

    if [ "$(get_config_setting max_replication_slots)" -lt 1 ]; then
        bail "Primary instance is not configured correctly. Update postgresql.conf with valid 'max_replication_slots'"
    fi

    local replication_slot=$(run psql -U "${POSTGRES_USERNAME}" -h "${POSTGRES_HOST}" --port=${POSTGRES_PORT} -d "${BITBUCKET_DB}" -tqc \
        "SELECT * FROM pg_create_physical_replication_slot('${STANDBY_DATABASE_REPLICATION_SLOT_NAME}')")

    if [[ "${replication_slot}" =~ "already exists" ]]; then
        info "Replication slot '${STANDBY_DATABASE_REPLICATION_SLOT_NAME}' created successfully"
    else
        info "Replication slot '${STANDBY_DATABASE_REPLICATION_SLOT_NAME}' already exists, skipping creation"
    fi

    local replication_user=$(run psql -U "${POSTGRES_USERNAME}" -h "${POSTGRES_HOST}" --port=${POSTGRES_PORT} -d "${BITBUCKET_DB}" -tqc \
        "\du ${STANDBY_DATABASE_REPLICATION_USER_USERNAME}")

    if [ -z "${replication_user}" ]; then
        run psql -U "${POSTGRES_USERNAME}" -h "${POSTGRES_HOST}" --port=${POSTGRES_PORT} -d "${BITBUCKET_DB}" -tqc \
            "CREATE USER ${STANDBY_DATABASE_REPLICATION_USER_USERNAME} REPLICATION LOGIN CONNECTION \
                LIMIT 1 ENCRYPTED PASSWORD '${STANDBY_DATABASE_REPLICATION_USER_PASSWORD}'"
        info "Replication user '${STANDBY_DATABASE_REPLICATION_USER_USERNAME}' has been created"
    else
        info "Replication user '${STANDBY_DATABASE_REPLICATION_USER_USERNAME}' already exists, skipping creation"
    fi
}
