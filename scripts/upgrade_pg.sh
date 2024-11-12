#!/bin/bash
set -e

# Install PG15
DEBIAN_FRONTEND=noninteractive apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y postgresql-15


# Get current database settings
ENCODING=$(PGPASSWORD=testpass psql -U testuser -d template1 -t -c "SHOW server_encoding;" | tr -d ' ')
LC_COLLATE=$(PGPASSWORD=testpass psql -U testuser -d template1 -t -c "SHOW lc_collate;" | tr -d ' ')
LC_CTYPE=$(PGPASSWORD=testpass psql -U testuser -d template1 -t -c "SHOW lc_ctype;" | tr -d ' ')

echo "Current settings:"
echo "Encoding: $ENCODING"
echo "LC_COLLATE: $LC_COLLATE"
echo "LC_CTYPE: $LC_CTYPE"

su - postgres -c "/usr/lib/postgresql/12/bin/pg_ctl -D /var/lib/postgresql/data stop -m fast"

# Create system user and set up directories(pesky initdb thing)
useradd -m testuser || true
mkdir -p /var/lib/postgresql/data_15
mkdir -p /var/run/postgresql
chown -R testuser:testuser /var/lib/postgresql/data_15
chown -R testuser:testuser /var/lib/postgresql/data
chown -R testuser:testuser /var/run/postgresql
chmod 2775 /var/run/postgresql

# Initialize new cluster with testuser
su - testuser -c "/usr/lib/postgresql/15/bin/initdb -D /var/lib/postgresql/data_15 -U testuser  --encoding=$ENCODING --lc-collate=$LC_COLLATE --lc-ctype=$LC_CTYPE"

# Run upgrade as testuser
su - testuser -c "/usr/lib/postgresql/15/bin/pg_upgrade \
  --old-datadir=/var/lib/postgresql/data \
  --new-datadir=/var/lib/postgresql/data_15 \
  --old-bindir=/usr/lib/postgresql/12/bin \
  --new-bindir=/usr/lib/postgresql/15/bin"

echo "Updating PostgreSQL 15 configuration..."
cat >> /var/lib/postgresql/data_15/postgresql.conf << EOF

# Added configuration for network and replication
listen_addresses = '*'
wal_level = logical
max_wal_senders = 10
max_replication_slots = 4
wal_sender_timeout=0
wal_writer_delay=1ms
wal_writer_flush_after=32kB
max_wal_size=4GB
EOF

# Update pg_hba.conf to allow connections
echo "Updating pg_hba.conf..."
cat > /var/lib/postgresql/data_15/pg_hba.conf << EOF
# TYPE  DATABASE        USER            ADDRESS                 METHOD
local   all            all                                     trust
host    all            all             127.0.0.1/32            trust
host    all            all             ::1/128                 trust
host    all            all             0.0.0.0/0               trust
host    replication    all             0.0.0.0/0               trust
EOF

# Start PostgreSQL 15 with the new directory
su - testuser -c "/usr/lib/postgresql/15/bin/pg_ctl -D /var/lib/postgresql/data_15 start -w"

