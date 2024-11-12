#!/bin/bash

# Replication management functions

create_new_replication_slots() {
    log_warn "Creating replication slots and publications..."
   
    local slots=($(printf "%s\n" "${REPLICATION_INFO[@]}" | cut -d: -f1 | sort -u))
    local publications=($(printf "%s\n" "${REPLICATION_INFO[@]}" | cut -d: -f3 | sort -u))
   
    for slot in "${slots[@]}"; do
        log_warn "Creating slot $slot..."
        PGPASSWORD=$DB_PASSWORD psql -h "$TARGET_HOST" -p "$TARGET_PORT" -U "$DB_USER" -d "$DB_NAME" -c \
            "SELECT pg_create_logical_replication_slot('$slot', 'pgoutput');" 2>/dev/null || {
            log_error "Failed to create slot $slot"
            return 1
        }
    done
   
    for publication in "${publications[@]}"; do
        log_warn "Creating publication $publication..."
        local tables=$(PGPASSWORD=$DB_PASSWORD psql -h "$SOURCE_HOST" -p "$SOURCE_PORT" -U "$DB_USER" -d "$DB_NAME" -tAc \
            "SELECT string_agg(schemaname || '.' || tablename, ',') FROM pg_publication_tables WHERE pubname = '$publication';")
           
        [ -z "$tables" ] && log_error "No tables found for publication $publication" && return 1
           
        PGPASSWORD=$DB_PASSWORD psql -h "$TARGET_HOST" -p "$TARGET_PORT" -U "$DB_USER" -d "$DB_NAME" -c \
            "DROP PUBLICATION IF EXISTS $publication;
            CREATE PUBLICATION $publication FOR TABLE $tables;" 2>/dev/null || {
            log_error "Failed to create publication $publication"
            return 1
        }
    done

    log_info "Slots and publications created"
}

drop_old_replication_slots() {
    log_warn "Dropping old slots and publications..."
   
    local slots=($(printf "%s\n" "${REPLICATION_INFO[@]}" | cut -d: -f1 | sort -u))
    local publications=($(printf "%s\n" "${REPLICATION_INFO[@]}" | cut -d: -f3 | sort -u))
   
    for publication in "${publications[@]}"; do
        log_warn "Dropping publication $publication..."
        PGPASSWORD=$DB_PASSWORD psql -h "$SOURCE_HOST" -p "$SOURCE_PORT" -U "$DB_USER" -d "$DB_NAME" -c \
            "DROP PUBLICATION IF EXISTS $publication;" 2>/dev/null || {
            log_error "Failed to drop publication $publication"
            return 1
        }
    done
   
    for slot in "${slots[@]}"; do
        log_warn "Dropping slot $slot..."
        PGPASSWORD=$DB_PASSWORD psql -h "$SOURCE_HOST" -p "$SOURCE_PORT" -U "$DB_USER" -d "$DB_NAME" -c \
            "SELECT pg_drop_replication_slot('$slot') FROM pg_replication_slots WHERE slot_name = '$slot';" 2>/dev/null || {
            log_error "Failed to drop slot $slot"
            return 1
        }
    done

    log_info "Old slots and publications dropped"
}

# Reverse replication direction from target to old source
switch_replication_direction() {
    log_warn "Switching logical replication direction..."
    
    # Drop subscription in target (old subscriber)
    PGPASSWORD=$DB_PASSWORD psql -h "$TARGET_HOST" -p "$TARGET_PORT" -U "$DB_USER" -d "$DB_NAME" -c \
        "DROP SUBSCRIPTION IF EXISTS dms_sub;"

    PGPASSWORD=$DB_PASSWORD psql -h "$TARGET_HOST" -p "$TARGET_PORT" -U "$DB_USER" -d "$DB_NAME" -c \
        "SELECT pg_create_logical_replication_slot('dms_slot', 'pgoutput');"
    
    # Create publication in target (new publisher)
    PGPASSWORD=$DB_PASSWORD psql -h "$TARGET_HOST" -p "$TARGET_PORT" -U "$DB_USER" -d "$DB_NAME" -c "
        DROP PUBLICATION IF EXISTS dms_pub;
        CREATE PUBLICATION dms_pub FOR ALL TABLES;"
    
    # Drop old publication in source
    PGPASSWORD=$DB_PASSWORD psql -h "$SOURCE_HOST" -p "$SOURCE_PORT" -U "$DB_USER" -d "$DB_NAME" -c "
        DROP PUBLICATION IF EXISTS dms_pub;"
    
    # Create subscription in source (new subscriber)
    PGPASSWORD=$DB_PASSWORD psql -h "$SOURCE_HOST" -p "$SOURCE_PORT" -U "$DB_USER" -d "$DB_NAME" -c "
        CREATE SUBSCRIPTION dms_sub 
        CONNECTION 'host=${TARGET_INTERNAL_NAME} port=5432 dbname=${DB_NAME} user=${DB_USER} password=${DB_PASSWORD}'
        PUBLICATION dms_pub 
        WITH (copy_data = false, create_slot = false, slot_name = 'dms_slot');"
}

wait_for_slots_catchup() {
    local pids=""
    local slots_to_migrate=()
    
    for map in "${REPLICATION_INFO[@]}"; do
        IFS=':' read -r slot_name _ _ _ _ <<< "$map"
        slots_to_migrate+=("$slot_name")
    done
    
    log_warn "Checking replication slots: ${slots_to_migrate[*]}"
    
    if [ "$DBZ_HANDLING" = "no-wait" ]; then
        log_info "No-wait mode: waiting 5 seconds for slots catchup..."
        sleep 5
        return 0
    fi
    
    # Start checks in parallel
    for slot in "${slots_to_migrate[@]}"; do
        check_slot_lag "$slot" &
        pids="$pids $!"
    done
    
    # Wait for all checks to complete
    local failed=0
    for pid in $pids; do
        if ! wait $pid; then
            failed=1
            log_error "Slot check failed for pid $pid"
        fi
    done
    
    return $failed
}

check_slot_lag() {
    local slot=$1
    local attempt=1
    
    while [ $attempt -le $CATCHUP_TIMEOUT ]; do
        local slot_info=$(PGPASSWORD=$DB_PASSWORD psql -h "$SOURCE_HOST" -p "$SOURCE_PORT" -U "$DB_USER" -d "$DB_NAME" -tAc "
            SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn) as lag_bytes,
                   confirmed_flush_lsn,
                   pg_current_wal_lsn()
            FROM pg_replication_slots 
            WHERE slot_name = '$slot';")
            
        local lag_bytes=$(echo "$slot_info" | cut -d'|' -f1)
        local confirmed_lsn=$(echo "$slot_info" | cut -d'|' -f2)
        local current_lsn=$(echo "$slot_info" | cut -d'|' -f3)
            
        log_warn "Slot $slot lag: $lag_bytes bytes (confirmed_lsn: $confirmed_lsn, current_lsn: $current_lsn)"
        
        if [ "$lag_bytes" -lt "$MAX_LAG_BYTES" ]; then
            log_info "Slot $slot caught up"
            return 0
        fi
        
        ((attempt++))
        sleep 1
    done
    
    log_error "Slot $slot failed to catch up"
    return 1
}

get_active_slots() {
    PGPASSWORD=$DB_PASSWORD psql -h "$SOURCE_HOST" -p "$SOURCE_PORT" -U "$DB_USER" -d "$DB_NAME" -tAc "
        SELECT slot_name, 
               pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)) as lag
        FROM pg_replication_slots 
        WHERE plugin = 'pgoutput' AND active = 't';"
}

discover_replication_mappings() {
    local mappings=()
    local unmapped=()
    
    while IFS='|' read -r slot lag; do
        slot=$(echo "$slot" | xargs)
        lag=$(echo "$lag" | xargs)
        local found=false
        
        # Read clusters directly with yq
        while IFS=: read -r name url; do
            name=$(echo "$name" | xargs)
            url=$(echo "$url" | xargs)
            
            # Skip empty or malformed entries
            [ -z "$name" ] || [ -z "$url" ] && continue
            
            for connector in $(curl -s "$url/connectors" | jq -r '.[]'); do
                local config=$(curl -s "$url/connectors/$connector/config")
                local slot_name=$(echo "$config" | jq -r '.["slot.name"] // empty')
                
                if [ "$slot_name" = "$slot" ]; then
                    local pub=$(echo "$config" | jq -r '.["publication.name"] // empty')
                    mappings+=("$slot:$connector:$pub:$name:$url")
                    found=true
                    break 2
                fi
            done
        done < <(yq e '.kafka.connect_clusters[] | [.name, .url] | join(":")' "$CONFIG_FILE")
        
        [ "$found" = false ] && unmapped+=("$slot ($lag behind)")
    done < <(get_active_slots)
    
    # Display results
    echo -e "\nReplication Slot Mappings:"
    printf "%-20s %-25s %-25s %-15s\n" "Slot" "Connector" "Publication" "Cluster"
    echo "--------------------------------------------------------------------------------"
    
    for m in "${mappings[@]}"; do
        IFS=':' read -r s c p n u <<< "$m"
        printf "%-20s %-25s %-25s %-15s\n" "$s" "$c" "$p" "$n"
    done
    
    if [ ${#unmapped[@]} -gt 0 ]; then
        echo -e "\nUnmapped Slots:"
        printf '%s\n' "${unmapped[@]}"
    fi
    
    echo -e "\nProceed with these mappings? [y/N] "
    read -r response
    
    if [[ "$response" =~ ^[Yy]$ ]]; then
        REPLICATION_INFO=("${mappings[@]}")
        return 0
    fi
    
    return 1
}

get_replication_info() {
    discover_replication_mappings || exit 1
}