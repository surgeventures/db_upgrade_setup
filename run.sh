#!/bin/bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source common libraries
source "${SCRIPT_DIR}/lib/logging.sh"

# Command definitions
COMMANDS=(
    "switchover:Perform database switchover between primary and replica"
    "test-setup:Set up new environment"
    "help:Show this help message"
)

usage() {
    echo "Database Upgrade"
    echo
    echo "Usage: $0 <command> [options]"
    echo
    echo "Available commands:"
    for cmd in "${COMMANDS[@]}"; do
        IFS=':' read -r command description <<< "$cmd"
        printf "  %-15s %s\n" "$command" "$description"
    done
    echo
    echo "For command-specific help, run:"
    echo "  $0 <command> --help"
}

run_switchover() {
    log_info "Running switchover..."
    "${SCRIPT_DIR}/scripts/switchover.sh" "$@"
}

run_test-setup() {
    log_info "Running database setup..."
    "${SCRIPT_DIR}/scripts/test-setup.sh" "$@"
}

# Main execution
main() {
    # Check if no command provided
    if [ $# -eq 0 ]; then
        usage
        exit 1
    fi

    # Get the command
    CMD=$1
    shift  # Remove the command from arguments

    # Process the command
    case $CMD in
        switchover)
            run_switchover "$@"
            ;;
        test-setup)
            run_test-setup "$@"
            ;;
        help)
            usage
            ;;
        *)
            log_error "Unknown command: $CMD"
            usage
            exit 1
            ;;
    esac
}

main "$@"