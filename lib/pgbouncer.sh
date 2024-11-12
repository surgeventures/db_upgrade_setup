#!/bin/bash

# PgBouncer control functions

pause_pool() {
    local pool_name=$1
    log_warn "Pausing PgBouncer pool ${pool_name}..."
    PGPASSWORD=${PGBOUNCER_ADMIN_PASSWORD} psql -h localhost \
        -p ${PGBOUNCER_PORT} \
        -U ${PGBOUNCER_ADMIN_USER} \
        -d ${PGBOUNCER_ADMIN_DB} \
        -c "PAUSE ${pool_name};"
        
    local max_wait=30
    local counter=0
    
    log_warn "Waiting for active transactions to complete on pool ${pool_name}..."
    while [ $counter -lt $max_wait ]; do
        local active_count=$(PGPASSWORD=${PGBOUNCER_ADMIN_PASSWORD} psql -h localhost \
            -p ${PGBOUNCER_PORT} \
            -U ${PGBOUNCER_ADMIN_USER} \
            -d ${PGBOUNCER_ADMIN_DB} \
            -tAc "SHOW POOLS" | grep "^${pool_name}" | awk '{print $3}')
            
        if [ "${active_count:-0}" -eq 0 ]; then
            log_info "Pool ${pool_name} is now idle"
            return 0
        fi
        
        log_info "Still waiting... ${active_count} active connections"
        sleep 1
        ((counter++))
    done
    
    log_error "Timeout waiting for pool ${pool_name} to become idle"
    return 1
}

resume_pool() {
    local pool_name=$1
    log_warn "Resuming PgBouncer pool ${pool_name}..."
    PGPASSWORD=${PGBOUNCER_ADMIN_PASSWORD} psql -h localhost \
        -p ${PGBOUNCER_PORT} \
        -U ${PGBOUNCER_ADMIN_USER} \
        -d ${PGBOUNCER_ADMIN_DB} \
        -c "RESUME ${pool_name};"
}

update_pgbouncer_pool() {
    local pool_name=$1
    local new_host=$2
    
    log_warn "Updating PgBouncer pool ${pool_name} to point to ${new_host}..."
    pause_pool "$pool_name"
    
    awk -v pool="$pool_name" -v host="$new_host" '
        $1 == pool {sub(/host=[^ ]*/, "host=" host)} 1
    ' "$PGBOUNCER_CONFIG" > "$PGBOUNCER_CONFIG.new" && \
    mv "$PGBOUNCER_CONFIG.new" "$PGBOUNCER_CONFIG"
    
    PGPASSWORD=${PGBOUNCER_ADMIN_PASSWORD} psql -h localhost \
        -p ${PGBOUNCER_PORT} \
        -U ${PGBOUNCER_ADMIN_USER} \
        -d ${PGBOUNCER_ADMIN_DB} \
        -c "RELOAD;"
    
    resume_pool "$pool_name"
}

switchover_ro_pool() {
    local ro_pool=$(yq e '.pgbouncer.pools.read_only.name' "$CONFIG_FILE")
    local target_host=$(get_target_ro_pool_host)
    
    log_warn "Switching read-only pool to target..."
    update_pgbouncer_pool "$ro_pool" "$target_host"
}

check_ro_pool_status() {
    local ro_pool=$(yq e '.pgbouncer.pools.read_only.name' "$CONFIG_FILE")
    local current_host=$(get_current_pool_host "$ro_pool")
    local target_host=$(get_target_ro_pool_host)
    
    if [ "$current_host" = "$target_host" ]; then
        log_warn "Read-only pool is already pointing to target"
        return 0
    fi
    return 1
}

get_current_pool_host() {
    local pool_name=$1
    PGPASSWORD=${PGBOUNCER_ADMIN_PASSWORD} psql -h localhost \
        -p ${PGBOUNCER_PORT} \
        -U ${PGBOUNCER_ADMIN_USER} \
        -d ${PGBOUNCER_ADMIN_DB} \
        -tAc "SHOW DATABASES" | grep "^${pool_name}" | awk -F '|' '{print $2}'
}

get_target_ro_pool_host() {
    if [ $HANDLE_REPLICAS -eq 1 ]; then
        local hosts="${TARGET_REPLICAS[0]}"
        for ((i=1; i<${#TARGET_REPLICAS[@]}; i++)); do
            hosts="${hosts},${TARGET_REPLICAS[$i]}"
        done
        echo "$hosts"
    else
        echo "$TARGET_INTERNAL_NAME"
    fi
}