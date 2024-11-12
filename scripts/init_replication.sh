#!/bin/bash
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    ALTER USER testuser WITH REPLICATION;
EOSQL

# Add replication entry to pg_hba.conf
echo "host replication testuser all md5" >> /var/lib/postgresql/data/pg_hba.conf