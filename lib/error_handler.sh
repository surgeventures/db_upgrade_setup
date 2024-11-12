#!/bin/bash
# Error handling functionality

source "$(dirname "${BASH_SOURCE[0]}")/logging.sh"

trap 'handle_error $? $LINENO $BASH_COMMAND' ERR

handle_error() {
    local exit_code=$1
    local line_no=$2
    local command=$3
    
    log_error "Error occurred at line $line_no"
    log_error "Command: $command"
    resume_pgbouncer || true
    exit $exit_code
}