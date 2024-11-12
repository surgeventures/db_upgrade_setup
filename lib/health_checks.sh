#!/bin/bash
# Health check functionality

source "$(dirname "${BASH_SOURCE[0]}")/logging.sh"

check_dependencies() {
    local missing_deps=()
    
    for cmd in jq yq nc psql; do
        if ! command -v $cmd >/dev/null 2>&1; then
            missing_deps+=($cmd)
        fi
    done
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        log_error "Missing required dependencies: ${missing_deps[*]}"
        exit 1
    fi
}

check_service() {
    local service=$1
    local port=$2
    local desc=$3

    log_warn "Checking $service $desc on port $port..."
    while ! nc -z localhost $port; do
        echo "Waiting for $service..."
        sleep 1
    done
}

check_connectors_status() {
    for connector in "${CONNECTORS[@]}"; do
        log_info "Checking connector: $connector"
        local status=$(curl -s "$KAFKA_CONNECT_URL/connectors/$connector/status")
        
        if ! echo "$status" | jq -e '.connector.state == "RUNNING" and .tasks[0].state == "RUNNING"' > /dev/null; then
            log_error "Connector $connector not fully running"
            log_error "Status: $status"
            return 1
        fi
        log_info "$connector is available and running"
    done
    return 0
}