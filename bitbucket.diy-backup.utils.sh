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
        echo "ERROR: HipChat notification message is missing." > /dev/stderr
        return 1
    fi

    local COLOR="gray"
    if [ -n "$2" ]; then
        COLOR=$2
    fi
    local NOTIFY="false"
    if [ "1" == "$3" ]; then
        NOTIFY="true"
    fi

    local MESSAGE=`echo "$1" | sed -e 's|"|\\\"|g'`
    curl -s -S -X POST -H "Content-Type: application/json" -d "{\"message\":\"${MESSAGE}\",\"color\":\"${COLOR}\",\"notify\":${NOTIFY}}" "${HIPCHAT_URL}/v2/room/${HIPCHAT_ROOM}/notification?auth_token=${HIPCHAT_TOKEN}"
}

function info {
    if [ "${BITBUCKET_VERBOSE_BACKUP}" == "TRUE" ]; then
        echo "[${BITBUCKET_URL}]  INFO: $*" > /dev/stderr
        hc_announce "[${BITBUCKET_URL}]  INFO: $*" "gray"
    fi
}

function print {
    if [ "${BITBUCKET_VERBOSE_BACKUP}" == "TRUE" ]; then
        echo "$@" > /dev/stderr
    fi
}

function success {
    echo "[${BITBUCKET_URL}]  SUCC: $*" > /dev/stderr
    hc_announce "[${BITBUCKET_URL}]  SUCC: $*" "green"
}

function no_op {
    echo > /dev/null
}