#!/bin/bash

function error {
    echo "[${STASH_URL}] ERROR:" $*
}

function bail {
    error $*
    exit 99
}

function info {
    if [ "${STASH_VERBOSE_BACKUP}" == "TRUE" ]; then
        echo "[${STASH_URL}]  INFO:" $*
    fi
}

function print {
    if [ "${STASH_VERBOSE_BACKUP}" == "TRUE" ]; then
        echo $*
    fi
}
