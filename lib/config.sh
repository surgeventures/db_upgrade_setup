#!/bin/bash
# Configuration management

# Load configuration
load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        log_error "Config file $CONFIG_FILE not found"
        exit 1
    fi
    
    # Load main configuration sections
    SOURCE_HOST=$(yq e '.source.host' "$CONFIG_FILE")
    SOURCE_PORT=$(yq e '.source.port' "$CONFIG_FILE")
    TARGET_HOST=$(yq e '.target.host' "$CONFIG_FILE")
    TARGET_PORT=$(yq e '.target.port' "$CONFIG_FILE")
    SOURCE_INTERNAL_NAME=$(yq e '.source.internal_name' "$CONFIG_FILE")
    TARGET_INTERNAL_NAME=$(yq e '.target.internal_name' "$CONFIG_FILE")

    # Load replicas if configured
    SOURCE_REPLICAS=($(yq e '.source.replicas[].name' "$CONFIG_FILE" 2>/dev/null || echo ""))
    TARGET_REPLICAS=($(yq e '.target.replicas[].name' "$CONFIG_FILE" 2>/dev/null || echo ""))

    # Validate replicas configuration
    if [ ${#SOURCE_REPLICAS[@]} -ne ${#TARGET_REPLICAS[@]} ]; then
        log_error "Number of replicas doesn't match: source=${#SOURCE_REPLICAS[@]}, target=${#TARGET_REPLICAS[@]}"
        exit 1
    fi

    # Set flag if we need to handle replicas
    HANDLE_REPLICAS=0
    if [ ${#SOURCE_REPLICAS[@]} -gt 0 ] && [ ${#TARGET_REPLICAS[@]} -gt 0 ]; then
        HANDLE_REPLICAS=1
    fi

    DB_NAME=$(yq e '.database.name' "$CONFIG_FILE")
    DB_USER=$(yq e '.database.user' "$CONFIG_FILE")
    DB_PASSWORD=$(yq e '.database.password' "$CONFIG_FILE")

    DB_LOGICAL_SLOT=$(yq e '.database.logical_slot' "$CONFIG_FILE")
    DB_LOGICAL_SUB=$(yq e '.database.logical_subscription' "$CONFIG_FILE")
    DB_LOGICAL_PUB=$(yq e '.database.logical_publication' "$CONFIG_FILE")
    
    KAFKA_CONNECT_URL=($(yq e '.kafka.connect_url' "$CONFIG_FILE"))
    CONNECTORS=($(yq e '.connectors[].name' "$CONFIG_FILE"))
    
    PGBOUNCER_CONFIG=$(yq e '.pgbouncer.config_file' "$CONFIG_FILE")
    PGBOUNCER_SWITCHOVER_CONFIG=$(yq e '.pgbouncer.switchover_config_file' "$CONFIG_FILE")

    PGBOUNCER_PORT=$(yq e '.pgbouncer.admin_port' "$CONFIG_FILE")
    PGBOUNCER_ADMIN_USER=$(yq e '.pgbouncer.admin_user' "$CONFIG_FILE")
    PGBOUNCER_ADMIN_PASSWORD=$(yq e '.pgbouncer.admin_password' "$CONFIG_FILE")
    PGBOUNCER_ADMIN_DB=$(yq e '.pgbouncer.admin_database' "$CONFIG_FILE")
    
    MAX_LAG_BYTES=$(yq e '.replication.max_lag_bytes' "$CONFIG_FILE")
    CATCHUP_TIMEOUT=$(yq e '.replication.catchup_timeout' "$CONFIG_FILE")
    SEQUENCE_GAP=$(yq e '.replication.sync_sequences_gap' "$CONFIG_FILE")
}