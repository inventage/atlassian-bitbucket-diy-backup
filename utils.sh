# -------------------------------------------------------------------------------------
# Common utilities for logging, terminating script execution and Hipchat integration.
# -------------------------------------------------------------------------------------

# Terminate script execution with error message
function bail {
    error "$*"
    print_stack_trace
    exit 99
}

# Test for the presence of the specified command and terminate script execution if not found
function check_command {
    type -P "$1" &> /dev/null || bail "Unable to find $1, please install it and run this script again"
}

# Log an debug message to the console if BITBUCKET_VERBOSE_BACKUP=true
function debug {
    if [ "${BITBUCKET_VERBOSE_BACKUP}" = "true" ]; then
        print "$(script_ctx)[$(hostname)] DEBUG: $*"
    fi
}

# Log an error message to the console and publish it to Hipchat
function error {
    # Set the following to have log statements print contextual information
    echo "$(script_ctx)[$(hostname)] ERROR: $*" > /dev/stderr
    hc_announce "[$(hostname)] ERROR: $*" "red" 1
}

# Log an info message to the console and publish it to Hipchat
function info {
    # Set the following to have log statements print contextual information
    print "$(script_ctx)[$(hostname)]  INFO: $*"
    hc_announce "[$(hostname)]  INFO: $*" "gray"
}

# Checks if a variable is zero length, if so it prints the supplied error message and bails
function check_config_var {
    local conf_var_name="$1"
    local conf_error_message="$2"
    local conf_bail_message="$3"

    if [ -z "${conf_error_message}" ]; then
        conf_error_message="The configuration var '${conf_var_name}' is required, please update '${BACKUP_VARS_FILE}'."
    fi
    if [ -z "${conf_bail_message}" ]; then
        conf_bail_message="See bitbucket.diy-backup.vars.sh.example for the defaults and instructions."
    fi

    check_var "${conf_var_name}" "${conf_error_message}" "${conf_bail_message}"
}

# Similar to check_config_var but does does not print the extra message about consulting the vars file
function check_var {
    local set_var_name="$1"
    local set_error_message="$2"
    local set_bail_message="$3"

    if [ -z "${!set_var_name}" ]; then
        if [ -z "${set_error_message}" ]; then
            set_error_message="Fatal error '${set_var_name}' has not been set"
        fi
        if [ -z "${set_bail_message}" ]; then
            bail "${set_error_message}"
        else
            error "${set_error_message}"
            bail "${set_bail_message}"
        fi
    fi
}

# A function with no side effects. Normally called when a callback does not need to do any work
function no_op {
    echo > /dev/null
}

# Log a message to the console without adding standard logging markup
function print {
    echo "$@"
}

function script_ctx {
    if [ -n "${BASH_VERSION}" ]; then
        local depth=0
        for func in ${FUNCNAME[@]}; do
            case "${func}" in
                debug|info|error|bail|check_config_var|check_var|run|script_ctx|print_stack_trace)
                    depth=$((${depth}+1))
                ;;
            esac
        done
        echo "[$(basename ${BASH_SOURCE[${depth}]}):${BASH_LINENO[${depth}]} -> ${FUNCNAME[${depth}]}]"
    fi
}

function print_stack_trace {
    if [ -n "${BASH_VERSION}" ]; then
        local idx=0
        local depth=" "
        echo "Stack trace:" > /dev/stderr
        for func in ${FUNCNAME[@]}; do
            case "${func}" in
                debug|info|error|bail|check_config_var|check_var|run|script_ctx|print_stack_trace)
                ;;
            *)
                echo "${depth}[${BASH_SOURCE[${idx}]}:${BASH_LINENO[${idx}]} -> ${FUNCNAME[${idx}]}]" > /dev/stderr
                ;;
            esac
            depth="${depth} "
            idx=$((${idx}+1))
        done
    fi
}

# Log then execute the provided command
function run {
    if [ "${BITBUCKET_VERBOSE_BACKUP}" = "true" ]; then
        local cmdline=
        for arg in "$@"; do
            case "${arg}" in
                *\ * | *\"*)
                    cmdline="${cmdline} '${arg}'"
                    ;;
                *)
                    cmdline="${cmdline} ${arg}"
                    ;;
            esac
        done
        case "${cmdline}" in
            *curl*)
                cmdline=$(echo "${cmdline}" | sed -e 's/-u .* /-u ******:****** /g')
                ;;
            *PGPASSWORD=*)
                cmdline=$(echo "${cmdline}" | sed -e 's/PGPASSWORD=".*" /PGPASSWORD="**********" /g')
                ;;
        esac
        debug "Running${cmdline}" > /dev/stderr
    fi
    "$@"
}

# Log a success message to the console and publish it to Hipchat
function success {
    print "[$(hostname)]  SUCC: $*"
    hc_announce "[$(hostname)]  SUCC: $*" "green"
}

# -------------------------------------------------------------------------------------
# Internal methods
# -------------------------------------------------------------------------------------

# Publish a message to Hipchat using the REST API
#
#   $1: string: message
#   $2: string: color (yellow/green/red/purple/gray/random)
#   $3: integer: notify (0/1)
#
function hc_announce {
    if [ -z "${HIPCHAT_ROOM}" ]; then
        return 0
    fi
    if [ -z "${HIPCHAT_TOKEN}" ]; then
        return 0
    fi

    if [ -z "$1" ]; then
        print "ERROR: HipChat notification message is missing."
        return 1
    fi

    local hc_color="gray"
    if [ -n "$2" ]; then
        hc_color=$2
    fi
    local hc_notify="false"
    if [ "1" = "$3" ]; then
        hc_notify="true"
    fi

    local hc_message=$(echo "$1" | sed -e 's|"|\\\"|g')
    local hipchat_payload="{\"message\":\"${hc_message}\",\"color\":\"${hc_color}\",\"notify\":\"${hc_notify}\"}"
    local hipchat_url="${HIPCHAT_URL}/v2/room/${HIPCHAT_ROOM}/notification?auth_token=${HIPCHAT_TOKEN}"
    ! curl ${CURL_OPTIONS} -X POST -H "Content-Type: application/json" -d "${hipchat_payload}" "${hipchat_url}"
    true
}
