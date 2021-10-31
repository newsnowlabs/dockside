#!/bin/bash

SCRIPT_PATH=$(dirname $(realpath $0))

. $SCRIPT_PATH/log_do-20180301

log_do -x -v --silent $SCRIPT_PATH/dehydrated -t dns-01 --cron --hook $SCRIPT_PATH/hook.sh
