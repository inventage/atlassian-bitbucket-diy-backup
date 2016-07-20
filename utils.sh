#!/bin/bash

# -------------------------------------------------------------------------------------
# Common utilities for logging, terminating script execution and Hipchat integration.
# -------------------------------------------------------------------------------------

# Terminate script execution with error message
function bail {
    error "$*"
    exit 99
}

# Test for the presence of the specified command and terminate script execution if not found
function check_command {
    type -P "$1" &> /dev/null || bail "Unable to find $1, please install it and run this script again"
}

# Log an debug message to standard error
function debug {
    if [ "${BITBUCKET_VERBOSE_BACKUP}" = true ]; then
        echo "[${BITBUCKET_URL}] DEBUG: $*" > /dev/stderr
    fi
}

# Log an error message to standard error and publish it to Hipchat
function error {
    echo "[${BITBUCKET_URL}] ERROR: $*" > /dev/stderr
    hc_announce "[${BITBUCKET_URL}] ERROR: $*" "red" 1
}

# Log an info message to standard error and publish it to Hipchat
function info {
    echo "[${BITBUCKET_URL}]  INFO: $*" > /dev/stderr
    hc_announce "[${BITBUCKET_URL}]  INFO: $*" "gray"
}

# A function with no side effects. Normally called when a callback does not need to do any work
function no_op {
    echo > /dev/null
}

# Log a message to standard error without adding standard logging markup
function print {
    echo "$@" > /dev/stderr
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
        debug "Running${cmdline}" >/dev/stderr
    fi
    "$@"
}

# Log a success message to standard error and publish it to Hipchat
function success {
    print "[${BITBUCKET_URL}]  SUCC: $*"
    hc_announce "[${BITBUCKET_URL}]  SUCC: $*" "green"
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
