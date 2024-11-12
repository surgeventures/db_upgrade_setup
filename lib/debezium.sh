#!/bin/bash

handle_connector_switch() {
    log_warn "Switching connectors to target database..."
    
    for info in "${REPLICATION_INFO[@]}"; do
        IFS=':' read -r slot connector publication cluster_name cluster_url <<< "$info"
        log_warn "Processing connector=$connector slot=$slot publication=$publication on cluster=$cluster_name"
        
        # Get current config
        local config=$(curl -s "$cluster_url/connectors/$connector/config")
        if [ -z "$config" ]; then
            log_error "Failed to get config for $connector on $cluster_name"
            return 1
        fi
        
        # Stop and delete connector
        curl -s -X PUT "$cluster_url/connectors/$connector/stop"
        curl -s -X DELETE "$cluster_url/connectors/$connector/offsets"
        curl -s -X DELETE "$cluster_url/connectors/$connector"
        
        if [ "$(curl -s -o /dev/null -w "%{http_code}" "$cluster_url/connectors/$connector")" == "404" ]; then
            log_info "Connector deleted from $cluster_name"
        fi
        
        # Create new connector with config
        local new_config=$(echo "$config" | jq --arg host "$TARGET_INTERNAL_NAME" \
            --arg slot "$slot" \
            --arg pub "$publication" \
            '. + {
                "database.hostname": $host,
                "database.port": "5432",
                "slot.name": $slot,
                "publication.name": $pub,
                "snapshot.mode": "never"
            }')
            
        if ! curl -s -X POST "$cluster_url/connectors" -H "Content-Type: application/json" \
            -d "{\"name\": \"$connector\", \"config\": $new_config}" > /dev/null; then
            log_error "Failed to create new connector on $cluster_name"
            return 1
        fi
        
        local status=$(curl -s "$cluster_url/connectors/$connector/status")
        if echo "$status" | jq -e '.connector.state == "RUNNING"' > /dev/null; then
            log_info "Connector started successfully on $cluster_name"
        fi
    done
    log_info "All connectors switched successfully"
}