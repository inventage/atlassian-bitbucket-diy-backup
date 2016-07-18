#!/bin/bash

# Contains util functions (bail, info, print)

function bail {
    error $*
    exit 99
}

function check_command {
    type -P $1 &> /dev/null || bail "Unable to find $1, please install it and run this script again"
}

function error {
    echo "[${BITBUCKET_URL}] ERROR: $*" > /dev/stderr
    hc_announce "[${BITBUCKET_URL}] ERROR: $*" "red" 1
}

# $1 = message, $2 = color (yellow/green/red/purple/gray/random), $3 = notify (0/1)
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
    ! curl -s -S -X POST -H "Content-Type: application/json" -d "${hipchat_payload}" "${hipchat_url}"
    true
}

function info {
    if [ "${BITBUCKET_VERBOSE_BACKUP}" = "TRUE" ]; then
        echo "[${BITBUCKET_URL}]  INFO: $*" > /dev/stderr
        hc_announce "[${BITBUCKET_URL}]  INFO: $*" "gray"
    fi
}

function print {
    if [ "${BITBUCKET_VERBOSE_BACKUP}" = "TRUE" ]; then
        echo "$@" > /dev/stderr
    fi
}

function run {
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
    info "Running${cmdline}" >/dev/stderr
    "$@"
}

function success {
    print "[${BITBUCKET_URL}]  SUCC: $*"
    hc_announce "[${BITBUCKET_URL}]  SUCC: $*" "green"
}

function no_op {
    echo > /dev/null
}
