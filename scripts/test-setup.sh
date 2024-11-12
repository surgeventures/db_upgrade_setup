#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../lib/logging.sh"

usage() {
    cat << EOF
Setup script

Usage: $0 [options]
Options:
  -f, --full           Recreate test setup from scratch
  -d, --destroy        Stop everything
  -r, --restart-target Restart target database
  -h, --help          Show this help message

NOTE: Don't forget to run --destroy after you're done to clean up background processes!
EOF
}

stop_target() {
    docker-compose stop postgres_target                                         
    docker-compose rm -f postgres_target
    docker volume rm db_upgrade_setup_pg_target_data 2>/dev/null || true
}

full() {
    log_info "Starting full setup..."
    destroy && docker-compose up -d
    ./scripts/seeds.sh
    ./scripts/continuous-cdc.sh &
    ./scripts/copy_db.sh
    
    log_info "Setup complete! CDC is running in background."
    log_info "⚠️  Don't forget to run './$(basename "$0") --destroy' when you're done to clean up background processes!"
}

destroy() {
    log_info "Cleaning up..."
    if [ -f "./cdc_output/continuous_cdc.pid" ]; then
        kill "$(cat ./cdc_output/continuous_cdc.pid)" || true
    fi
    stop_target
    docker-compose down -v
}

restart_target() {
    log_info "Restarting target database..."
    stop_target
    docker-compose up -d postgres_target
}

main() {
    if [[ $# -eq 0 ]]; then
        usage
        exit 1
    fi

    while [[ $# -gt 0 ]]; do
        case $1 in
            -f|--full)
                shift 1
                full
                ;;
            -d|--destroy)
                shift 1
                destroy
                ;;
            -r|--restart-target)
                shift 1
                restart_target
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done
}

main "$@"