#!/bin/bash

# Create output directory
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CDC_OUTPUT_DIR="${PROJECT_ROOT}/cdc_output"
rm -rf "$CDC_OUTPUT_DIR"
mkdir -p "$CDC_OUTPUT_DIR"

# Store the main script's PID
echo $$ > "$CDC_OUTPUT_DIR/continuous_cdc.pid"

start_consumers() {
    echo "Starting Kafka consumers..."
    # CDC events consumer
    docker-compose exec -T kafka kafka-console-consumer \
        --bootstrap-server kafka:29092 \
        --topic postgres-cdc.public.customers \
        --group cdc-consumer-group \
        --consumer-property client.id=cdc_script_consumer \
        --from-beginning 2>&1 > "$CDC_OUTPUT_DIR/cdc_events.log" &
    
    # Outbox events consumer
    docker-compose exec -T kafka kafka-console-consumer \
        --bootstrap-server kafka:29092 \
        --topic customer \
        --group outbox-consumer-group \
        --consumer-property client.id=outbox_script_consumer \
        --from-beginning 2>&1 > "$CDC_OUTPUT_DIR/outbox_events.log" &
}

cleanup() {
    echo "Cleaning up..."
    
        docker-compose exec -T kafka pkill -f "client.id=cdc_script_consumer"
    docker-compose exec -T kafka pkill -f "client.id=outbox_script_consumer"
    
    # Kill all child processes
    pkill -P $$
    
    # Remove PID files
    rm -f "$CDC_OUTPUT_DIR"/*.pid
    
    exit 0
}

# Generate continuous changes with logging
generate_changes() {
    local generator_id=$1
    local counter=1
    
    while true; do
        if PGPASSWORD=testpass psql -h localhost -p 6433 -U testuser -d testdb_rw -c \
            "BEGIN;
             INSERT INTO customers (name, email) 
             VALUES ('User ${generator_id}_${counter}', 'user${generator_id}_${counter}@example.com');
             
             INSERT INTO outbox (aggregatetype, aggregateid, type, payload) 
             VALUES (
                'customer', 
                '${generator_id}_${counter}', 
                'CustomerCreated', 
                json_build_object(
                    'customerId', '${generator_id}_${counter}',
                    'name', 'User ${generator_id}_${counter}',
                    'email', 'user${generator_id}_${counter}@example.com'
                )
             );
             COMMIT;" > /dev/null 2>&1; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') - Generator $generator_id: Inserted customer record $counter with outbox event" >> "$CDC_OUTPUT_DIR/generation_${generator_id}.log"
        else
            echo "$(date '+%Y-%m-%d %H:%M:%S') - Generator $generator_id: Failed to insert record $counter" >> "$CDC_OUTPUT_DIR/generation_${generator_id}.log"
        fi
        
        counter=$((counter + 1))
        sleep 2
    done
}

# Perform read operations on readonly database
perform_reads() {
    local reader_id=$1
    local counter=1
    
    while true; do
        if PGPASSWORD=testpass psql -h localhost -p 6433 -U testuser -d testdb_ro -c \
            "SELECT * FROM customers 
             WHERE id = (SELECT floor(random() * (SELECT MAX(id) FROM customers) + 1));" > /dev/null 2>&1; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') - Reader $reader_id: Executed read query $counter" >> "$CDC_OUTPUT_DIR/reads_${reader_id}.log"
        else
            echo "$(date '+%Y-%m-%d %H:%M:%S') - Reader $reader_id: Failed to execute read query $counter" >> "$CDC_OUTPUT_DIR/reads_${reader_id}.log"
        fi
        
        counter=$((counter + 1))
        sleep 1
    done
}

# Set up cleanup trap
trap cleanup SIGINT SIGTERM EXIT

# If running in background, detach from TTY
[[ $- != *i* ]] && exec 0</dev/null

# Main execution
echo "Setting up continuous CDC testing with parallel operations..."

# Start consumers
start_consumers

sleep 5

# Start generators and readers
for ((i=1; i<=3; i++)); do
    generate_changes $i &
done

for ((i=1; i<=2; i++)); do
    perform_reads $i &
done

echo -e "\nProcesses started. To monitor:"
echo "  tail -f $CDC_OUTPUT_DIR/generation_*.log  # To see data generation activity"
echo "  tail -f $CDC_OUTPUT_DIR/reads_*.log      # To see read operations"
echo "  tail -f $CDC_OUTPUT_DIR/cdc_events.log   # To see CDC events"
echo "  tail -f $CDC_OUTPUT_DIR/outbox_events.log # To see outbox events"
echo -e "\nTo stop all processes:"
echo "  kill $(cat $CDC_OUTPUT_DIR/continuous_cdc.pid)"

# Wait for all background processes
wait