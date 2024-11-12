#!/bin/bash

# Exit on error
set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Function to wait for PostgreSQL to be ready
wait_for_postgres() {
    local host=$1
    local port=$2
    echo -e "${YELLOW}Waiting for PostgreSQL at $host:$port...${NC}"
    while ! PGPASSWORD=testpass psql -h "$host" -p "$port" -U testuser -d testdb -c "SELECT 1" >/dev/null 2>&1; do
        sleep 1
    done
    echo -e "${GREEN}PostgreSQL at $host:$port is ready${NC}"
}

# Create test table and data in source database
setup_source_db() {
    echo -e "${YELLOW}Setting up source database...${NC}"
    PGPASSWORD=testpass psql -h localhost -p 5433 -U testuser -d testdb << EOF
    CREATE TABLE IF NOT EXISTS customers (
        id SERIAL PRIMARY KEY,
        name VARCHAR(100),
        email VARCHAR(200),
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    );
EOF
}

# Copy schema to target database
copy_schema() {
    echo -e "${YELLOW}Copying schema to target database...${NC}"
    PGPASSWORD=testpass pg_dump -h localhost -p 5433 -U testuser -d testdb --schema-only | \
    PGPASSWORD=testpass psql -h localhost -p 5434 -U testuser -d testdb
}

# Create replication slot and return initial LSN
create_replication_slot() {
    # Completely silence the drop operation
    PGPASSWORD=testpass psql -h localhost -p 5433 -U testuser -d testdb -qAtc "
        SELECT pg_drop_replication_slot('dms_slot') 
        FROM pg_replication_slots 
        WHERE slot_name = 'dms_slot';" > /dev/null 2>&1

    # Only get the LSN value, nothing else
    PGPASSWORD=testpass psql -h localhost -p 5433 -U testuser -d testdb -qAtc "
        SELECT lsn FROM pg_create_logical_replication_slot('dms_slot', 'pgoutput', false);"
}

# Create publication in source database
create_publication() {
    echo -e "${YELLOW}Creating publication...${NC}"
    PGPASSWORD=testpass psql -h localhost -p 5433 -U testuser -d testdb -c "
        DROP PUBLICATION IF EXISTS dms_pub;
        CREATE PUBLICATION dms_pub FOR TABLE customers;"
}

# Copy initial data to target database
copy_data() {
    echo -e "${YELLOW}Copying data to target database...${NC}"
    PGPASSWORD=testpass pg_dump -h localhost -p 5433 -U testuser -d testdb --data-only | \
    PGPASSWORD=testpass psql -h localhost -p 5434 -U testuser -d testdb
}

# Create subscription without enabling
create_initial_subscription() {
    local initial_lsn="$1"
    echo -e "${YELLOW}Using LSN: $initial_lsn${NC}"
    
    # Drop existing subscription if exists
    PGPASSWORD=testpass psql -h localhost -p 5434 -U testuser -d testdb -c "
        DROP SUBSCRIPTION IF EXISTS dms_sub;" 2>/dev/null || true
    
    # Create new subscription
    PGPASSWORD=testpass psql -h localhost -p 5434 -U testuser -d testdb -c "
        CREATE SUBSCRIPTION dms_sub 
        CONNECTION 'host=postgres_source port=5432 dbname=testdb user=testuser password=testpass' 
        PUBLICATION dms_pub 
        WITH (copy_data = false, enabled = false, create_slot = false, slot_name = 'dms_slot');"

    echo -e "${YELLOW}Getting replication origin name...${NC}"
    local origin_name=$(PGPASSWORD=testpass psql -h localhost -p 5434 -U testuser -d testdb -tAc "
        SELECT roname FROM pg_replication_origin WHERE roname LIKE 'pg_%';")
    
    if [ -n "$origin_name" ]; then
        echo -e "${GREEN}Setting initial replication position for origin $origin_name with LSN $initial_lsn...${NC}"
        PGPASSWORD=testpass psql -h localhost -p 5434 -U testuser -d testdb -c "
            SELECT pg_replication_origin_advance('$origin_name', '$initial_lsn');"
    else
        echo -e "${RED}Error: Could not find replication origin name${NC}"
        return 1
    fi
}

# Enable subscription
enable_subscription() {
    echo -e "${YELLOW}Enabling subscription...${NC}"
    PGPASSWORD=testpass psql -h localhost -p 5434 -U testuser -d testdb -c "
        ALTER SUBSCRIPTION dms_sub ENABLE;"
}

# Upgrade target database
upgrade_target_db() {
    echo -e "${YELLOW}Running upgrade in target container...${NC}"
    docker-compose exec -T postgres_target bash /upgrade_pg.sh
}

# Function to monitor replication lag
monitor_replication() {
    local max_attempts=${1:-60}
    local attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        echo -e "${YELLOW}Checking replication status (attempt $((attempt + 1))/$max_attempts)...${NC}"
        
        # Count records in both databases
        source_count=$(PGPASSWORD=testpass psql -h localhost -p 5433 -U testuser -d testdb -tAc "
            SELECT COUNT(*) FROM customers;")
        target_count=$(PGPASSWORD=testpass psql -h localhost -p 5434 -U testuser -d testdb -tAc "
            SELECT COUNT(*) FROM customers;")
        
        echo "Source records: $source_count"
        echo "Target records: $target_count"
        echo "Difference: $((source_count - target_count))"
        
        # Check subscription status
        PGPASSWORD=testpass psql -h localhost -p 5434 -U testuser -d testdb -c "
            SELECT s.subname, 
                   CASE WHEN s.subenabled THEN 'ACTIVE' ELSE 'INACTIVE' END as status,
                   ss.received_lsn,
                   ss.latest_end_lsn,
                   pg_size_pretty(pg_wal_lsn_diff(ss.latest_end_lsn, ss.received_lsn)) as lag
            FROM pg_subscription s
            JOIN pg_stat_subscription ss ON s.oid = ss.subid;"
        
        if [ "$source_count" = "$target_count" ]; then
            echo -e "${GREEN}Replication caught up!${NC}"
            return 0
        fi
        
        attempt=$((attempt + 1))
        sleep 5
    done
    
    echo -e "${RED}Warning: Replication monitoring timed out after $max_attempts attempts${NC}"
    return 1
}

# Main execution
echo -e "${YELLOW}Starting DMS-like replication setup...${NC}"

# Wait for both databases to be ready
wait_for_postgres "localhost" "5433"
wait_for_postgres "localhost" "5434"

# Setup source database
setup_source_db

# Copy schema to target first
copy_schema

# Create replication slot and capture LSN
INITIAL_LSN=$(create_replication_slot)
echo -e "${GREEN}Captured LSN: $INITIAL_LSN${NC}"

# Create publication
create_publication

# Copy existing data
copy_data

# Do the upgrade
upgrade_target_db

# Create subscription but don't enable yet
create_initial_subscription "$INITIAL_LSN"

# Enable subscription
enable_subscription

# Monitor replication
monitor_replication 30

echo -e "${GREEN}Setup complete!${NC}"