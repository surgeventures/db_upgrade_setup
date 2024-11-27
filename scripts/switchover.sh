#!/bin/bash

# Exit on error, but allow custom error handling
set -eE

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/../configs/switchover-config.yaml"

REPLICATION_INFO=()
SWITCHOVER_MODE="readonly"
DBZ_HANDLING="no-wait" 

# Load all modules
source "${SCRIPT_DIR}/../lib/logging.sh"
source "${SCRIPT_DIR}/../lib/error_handler.sh"
source "${SCRIPT_DIR}/../lib/health_checks.sh"
source "${SCRIPT_DIR}/../lib/sequences.sh"
source "${SCRIPT_DIR}/../lib/config.sh"
source "${SCRIPT_DIR}/../lib/pgbouncer.sh"
source "${SCRIPT_DIR}/../lib/replication.sh"
source "${SCRIPT_DIR}/../lib/debezium.sh"

perform_switchover() {
    local direction=$1
    
    log_warn "Starting switchover process ($direction) in $SWITCHOVER_MODE mode..."
    load_config
    
    if [ "$direction" = "reverse" ]; then
        swap_roles
    fi

    get_replication_info

    check_dependencies
    check_service "$SOURCE_HOST" "$SOURCE_PORT" "Source PostgreSQL"
    check_service "$TARGET_HOST" "$TARGET_PORT" "Target PostgreSQL"
    check_service "localhost" "$PGBOUNCER_PORT" "PgBouncer"
    check_service "localhost" "8083" "Kafka Connect"

    if ! check_ro_pool_status; then
        log_warn "Switching read-only pool first..."
        switchover_ro_pool
    else
        log_info "Read-only pool already on target"
    fi
    
    if [ "$SWITCHOVER_MODE" = "readonly" ]; then
        log_info "Read-only switchover completed successfully"
        exit 0
    fi
    
    if [ ${#REPLICATION_INFO[@]} -eq 0 ]; then
        log_error "No replication configurations found"
        exit 1
    fi
    
    local rw_pool_name=$(yq e '.pgbouncer.pools.read_write.name' "$CONFIG_FILE")
    pause_pool "$rw_pool_name"
    wait_for_logical_replica_sync
    
    sync_sequences
    
    if ! wait_for_slots_catchup; then
        log_error "Some replication slots failed to catch up"
        resume_pool "$rw_pool_name"
        exit 1
    fi
    
    create_new_replication_slots
    handle_connector_switch
    switch_replication_direction
    update_pgbouncer_pool "$rw_pool_name" "$TARGET_INTERNAL_NAME"
    drop_old_replication_slots
    
    log_info "Switchover completed successfully"
}

# Function to swap roles in memory
swap_roles() {
    log_info "Swapping source and target roles..."
    # Save original source values
    local orig_source_host="$SOURCE_HOST"
    local orig_source_port="$SOURCE_PORT"
    local -a orig_source_replicas=("${SOURCE_REPLICAS[@]}")
    local orig_source_internal="$SOURCE_INTERNAL_NAME"
    local orig_pgb_config="$PGBOUNCER_CONFIG"
    
    # Swap source to target
    SOURCE_HOST="$TARGET_HOST"
    SOURCE_PORT="$TARGET_PORT"
    SOURCE_REPLICAS=("${TARGET_REPLICAS[@]}")
    SOURCE_INTERNAL_NAME="$TARGET_INTERNAL_NAME"
    PGBOUNCER_CONFIG="$PGBOUNCER_SWITCHOVER_CONFIG"
    
    # Swap target to original source
    TARGET_HOST="$orig_source_host"
    TARGET_PORT="$orig_source_port"
    TARGET_REPLICAS=("${orig_source_replicas[@]}")
    TARGET_INTERNAL_NAME="$orig_source_internal"
    PGBOUNCER_SWITCHOVER_CONFIG="$orig_pgb_config"
    
    log_info "Roles swapped: new source=${SOURCE_HOST}, new target=${orig_source_host}"
}

# Usage function
usage() {
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  -d,   --direction        Specify switchover direction (forward|reverse)"
    echo "  -m,   --mode             Specify switchover mode (full|readonly) [default: full]"
    echo "  -dbz, --debezium-mode    Specify debezium connectors handling during swtichover (catchup|no-wait) [default: no-wait]"
    echo "  -c,   --config           Specify config file (default: switchover-config.yaml)"
    echo "  -h,   --help             Show this help message"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -d|--direction)
            DIRECTION="$2"
            shift 2
            ;;
        -m|--mode)
            SWITCHOVER_MODE="$2"
            shift 2
            ;;
        -c|--config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        -dbz|--debezium-mode)
            DBZ_HANDLING="$2"
            shift 2
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

# Validate arguments
if [ -z "$DIRECTION" ] || [[ ! "$DIRECTION" =~ ^(forward|reverse)$ ]]; then
    log_error "Valid direction (forward|reverse) must be specified"
    usage
    exit 1
fi

if [[ ! "$SWITCHOVER_MODE" =~ ^(full|readonly)$ ]]; then
    log_error "Invalid mode. Must be 'full' or 'readonly'"
    usage
    exit 1
fi

if [[ ! "$DBZ_HANDLING" =~ ^(catchup|no-wait)$ ]]; then
    log_error "Invalid mode. Must be 'full' or 'readonly'"
    usage
    exit 1
fi

# Execute switchover
perform_switchover "$DIRECTION"