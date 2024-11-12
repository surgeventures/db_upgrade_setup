#!/bin/bash

# Function to wait for Kafka Connect to be fully ready
wait_for_kafka_connect() {
    local port=$1
    echo "Waiting for Kafka Connect on port $port to be ready..."
    while true; do
        if curl -s -f "http://localhost:$port/" > /dev/null; then
            echo "Kafka Connect on port $port is ready"
            return 0
        fi
        echo "Waiting for Kafka Connect..."
        sleep 5
    done
}

# Function to create or update CDC connector
setup_cdc_connector() {
    # Delete connector if exists
    curl -X DELETE http://localhost:8083/connectors/postgres-connector 2>/dev/null
    sleep 5

    echo "Creating CDC Debezium connector..."
    curl -X POST http://localhost:8083/connectors \
         -H "Content-Type: application/json" \
         -d '{
           "name": "postgres-connector",
           "config": {
             "connector.class": "io.debezium.connector.postgresql.PostgresConnector",
             "database.hostname": "postgres_source",
             "database.port": "5432",
             "database.user": "testuser",
             "database.password": "testpass",
             "database.dbname": "testdb",
             "topic.prefix": "postgres-cdc",
             "database.server.name": "postgres-cdc",
             "schema.include.list": "public",
             "table.include.list": "public.customers,public.heartbeat",
             "plugin.name": "pgoutput",
             "slot.name": "debezium",
             "publication.name": "dbz_publication",
             "heartbeat.interval.ms": "1000",
             "heartbeat.action.query": "INSERT INTO heartbeat (id, ts) VALUES (1, NOW()) ON CONFLICT (id) DO UPDATE SET ts = NOW()",
             "poll.interval.ms": "500",
             "flush.ms": "100",
             "producer.linger.ms": "0",
             "status.update.interval.ms": "100",
             "logging.level": "DEBUG",
             "snapshot.mode": "never"
           }
         }'
}

# Function to create or update outbox connector
setup_outbox_connector() {
    # Delete connector if exists
    curl -X DELETE http://localhost:8084/connectors/outbox-connector 2>/dev/null
    sleep 5

    echo "Creating Outbox Debezium connector..."
    curl -X POST http://localhost:8084/connectors \
         -H "Content-Type: application/json" \
         -d '{
           "name": "outbox-connector",
           "config": {
             "connector.class": "io.debezium.connector.postgresql.PostgresConnector",
             "database.hostname": "postgres_source",
             "database.port": "5432",
             "database.user": "testuser",
             "database.password": "testpass",
             "database.dbname": "testdb",
             "topic.prefix": "outbox",
             "database.server.name": "outbox",
             "schema.include.list": "public",
             "table.include.list": "public.outbox",
             "plugin.name": "pgoutput",
             "slot.name": "debezium_outbox",
             "publication.name": "dbz_publication_outbox",
             "transforms": "outbox",
             "transforms.outbox.type": "io.debezium.transforms.outbox.EventRouter",
             "transforms.outbox.table.fields.additional.placement": "type:header:eventType",
             "transforms.outbox.route.topic.replacement": "${routedByValue}",
             "transforms.outbox.table.field.event.id": "id",
             "transforms.outbox.table.field.event.key": "aggregateid",
             "transforms.outbox.table.field.event.type": "type",
             "transforms.outbox.table.field.event.payload": "payload",
             "transforms.outbox.route.by.field": "aggregatetype",
             "poll.interval.ms": "500",
             "flush.ms": "100",
             "producer.linger.ms": "0",
             "status.update.interval.ms": "100",
             "logging.level": "DEBUG",
             "snapshot.mode": "never"
           }
         }'
}

# Function to check connector status
check_connector() {
    local connector_name=$1
    local port=$2
    local connect_url="http://localhost:$port"
    
    for i in {1..30}; do
        STATUS=$(curl -s "$connect_url/connectors/${connector_name}/status")
        if echo $STATUS | grep -q '"state":"RUNNING"'; then
            echo "Connector ${connector_name} is running on port $port"
            return 0
        elif echo $STATUS | grep -q "FAILED"; then
            echo "Connector ${connector_name} failed on port $port. Status: $STATUS"
            return 1
        fi
        echo "Waiting for connector ${connector_name} to start on port $port... ($i/30)"
        sleep 2
    done
    echo "Connector ${connector_name} did not start within timeout on port $port"
    return 1
}

echo "Waiting for all services..."
sleep 5  # Initial wait for services to start

# Wait for both Kafka Connect clusters
wait_for_kafka_connect 8083
wait_for_kafka_connect 8084

# Set up database
echo "Setting up database..."
PGPASSWORD=testpass psql -h localhost -U testuser -d testdb -p 5433 << EOF
-- Enable UUID extension
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Create customers table
DROP TABLE IF EXISTS customers;
CREATE TABLE customers (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100),
    email VARCHAR(200),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Create heartbeat table
DROP TABLE IF EXISTS heartbeat;
CREATE TABLE heartbeat (
    id INTEGER PRIMARY KEY,
    ts TIMESTAMP WITH TIME ZONE NOT NULL
);

-- Create outbox table
DROP TABLE IF EXISTS outbox;
CREATE TABLE outbox (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    aggregatetype VARCHAR(255) NOT NULL,
    aggregateid VARCHAR(255) NOT NULL,
    type VARCHAR(255) NOT NULL,
    payload JSONB NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    processed_at TIMESTAMP WITH TIME ZONE
);

-- Create index for better performance
CREATE INDEX outbox_processed_at_idx ON outbox(processed_at);

-- Create publications for CDC
DROP PUBLICATION IF EXISTS dbz_publication;
CREATE PUBLICATION dbz_publication FOR TABLE customers, heartbeat;

DROP PUBLICATION IF EXISTS dbz_publication_outbox;
CREATE PUBLICATION dbz_publication_outbox FOR TABLE outbox;
EOF

# Set up and verify connectors
setup_cdc_connector
if ! check_connector "postgres-connector" 8083; then
    echo "Failed to start CDC connector. Checking Kafka Connect logs..."
    docker-compose logs kafka-connect-cdc
    exit 1
fi

setup_outbox_connector
if ! check_connector "outbox-connector" 8084; then
    echo "Failed to start outbox connector. Checking Kafka Connect logs..."
    docker-compose logs kafka-connect-outbox
    exit 1
fi

# Generate test data
echo "Inserting test data..."
for i in {1..10}; do
    if PGPASSWORD=testpass psql -h localhost -U testuser -d testdb_rw -p 6433 -c \
        "BEGIN;
         INSERT INTO customers (name, email) 
         VALUES ('User $i', 'user$i@example.com');
         
         INSERT INTO outbox (aggregatetype, aggregateid, type, payload) 
         VALUES (
            'customer', 
            '$i', 
            'CustomerCreated', 
            json_build_object(
                'customerId', $i,
                'name', 'User $i',
                'email', 'user$i@example.com'
            )
         );
         COMMIT;" > /dev/null; then
        echo "Inserted record $i with outbox event"
    else
        echo "Failed to insert record $i"
    fi
    sleep 1
done

echo -e "\nSetup complete! To monitor events, run:"
echo "# For CDC events:"
echo "docker-compose exec kafka kafka-console-consumer --bootstrap-server kafka:29092 --topic postgres-cdc.public.customers --from-beginning"
echo -e "\n# For Outbox events:"
echo "docker-compose exec kafka kafka-console-consumer --bootstrap-server kafka:29092 --topic customer --from-beginning"

# Show connector statuses at the end
echo -e "\nFinal connector statuses:"
echo -e "\nCDC Connector:"
curl -s http://localhost:8083/connectors/postgres-connector/status
echo -e "\n\nOutbox Connector:"
curl -s http://localhost:8084/connectors/outbox-connector/status