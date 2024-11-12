#!/bin/bash
# Syncing sequences in target db

sync_sequences() {
    log_warn "Advancing sequences in target database..."
    
    PGPASSWORD=${DB_PASSWORD} psql -h ${SOURCE_HOST} -p ${SOURCE_PORT} -U ${DB_USER} -d ${DB_NAME} -tAc "
        SELECT schemaname || '.' || sequencename 
        FROM pg_sequences;" | while read seq_name; do
        if [ -n "$seq_name" ]; then
            echo "Advancing sequence $seq_name"
            local curr_val=$(PGPASSWORD=${DB_PASSWORD} psql -h ${SOURCE_HOST} -p ${SOURCE_PORT} -U ${DB_USER} -d ${DB_NAME} -tAc "
                SELECT last_value FROM $seq_name;")
            
            PGPASSWORD=${DB_PASSWORD} psql -h ${TARGET_HOST} -p ${TARGET_PORT} -U ${DB_USER} -d ${DB_NAME} -c "
                SELECT setval('$seq_name', $curr_val + ${SEQUENCE_GAP:-100000}, true);"
        fi
    done
}