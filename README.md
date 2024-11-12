# Zero-Downtime Database Switchover Tool

Zero-downtime PostgreSQL database switchover with physical replicas and Debezium CDC connectors support. Handles read-only and read-write traffic separately via PgBouncer for minimal application disruption.

## Features

- Zero-downtime switchover using PgBouncer
- Multiple physical replicas support
- Debezium CDC connector management
- Replication lag monitoring
- Sequence synchronization
- Separate read-only/read-write traffic handling
- Forward and reverse switchover
- Test environment with sample Elixir app
- Continuous CDC monitoring
- Read/write load simulation

## Prerequisites

- Docker and Docker Compose
- PostgreSQL with logical replication
- PgBouncer
- Kafka Connect with Debezium
- `yq` tool for YAML processing
- `psql` client
- Elixir (for test app)

## Project Structure

```
db_upgrade_setup/
├── cdc_output/           # CDC and test load output logs
├── configs/
│   ├── pgbouncer.ini    # PgBouncer configuration  
│   ├── switchover-config.yaml # Main switchover configuration
│   └── userlist.txt     # PgBouncer user credentials
├── docker/              # Docker-related files
├── elixir_app/          # Sample Elixir application for testing
├── lib/                 # Core library functions
│   ├── config.sh
│   ├── debezium.sh 
│   ├── error_handler.sh
│   ├── health_checks.sh
│   ├── logging.sh
│   ├── pgbouncer.sh
│   ├── replication.sh
│   └── sequences.sh
└── scripts/
    ├── continuous-cdc.sh    # CDC monitoring script
    ├── copy_db.sh          # Database copy utility
    ├── init_replication.sh # Replication setup
    ├── seeds.sh           # Database seeding
    ├── switchover.sh      # Main switchover script
    ├── test-setup.sh      # Test environment setup
    ├── upgrade_pg.sh      # Database upgrade script
    └── run.sh            # Main wrapper script
```

## Configuration

Configuration file `switchover-config.yaml`:

```yaml
source:
  internal_name: postgres_source
  host: localhost
  port: 5433
  replicas:
    - name: postgres_source_ro_1
    - name: postgres_source_ro_2

target:
  internal_name: postgres_target
  host: localhost
  port: 5434
  replicas:
    - name: postgres_target_ro_1
    - name: postgres_target_ro_2

database:
  name: testdb
  user: testuser
  password: testpass

connectors:
  - name: postgres-connector
    slot_name: debezium
    publication_name: dbz_publication

pgbouncer:
  config_file: pgbouncer.ini
  admin_port: 6433
  admin_user: testuser
  admin_password: testpass
  admin_database: pgbouncer
  pools:
    read_write:
      name: testdb_rw
    read_only:
      name: testdb_ro

kafka:
  connect_clusters:
    - name: cdc
      url: http://localhost:8083
    - name: outbox
      url: http://localhost:8084

replication:
  max_lag_bytes: 20000
  catchup_timeout: 60
  sync_sequences_gap: 100000
```

## Quick Start

### Main Commands

```bash
./run.sh <command> [options]

Commands:
  switchover      # Run database switchover
  test-setup      # Set up test environment
  help           # Show help message
```

### Test Environment Setup

```bash
# Full setup with sample app and CDC monitoring
./run.sh test-setup --full

# Clean up everything
./run.sh test-setup --destroy

# Restart only target database
./run.sh test-setup --restart-target
```

The `--full` setup:

1. Starts Docker containers (databases, Kafka)
2. Seeds database with test data
3. Launches Elixir test application
4. Starts CDC monitoring
5. Sets up read/write load simulation
6. Initializes logging

### Running Switchover

```bash
./run.sh switchover [options]

Options:
  -d, --direction        # forward|reverse
  -m, --mode            # full|readonly (default: full)
  -dbz, --debezium-mode # catchup|no-wait (default: no-wait)
  -c, --config          # config file path
  -h, --help           # show help
```

## Switchover Modes

### Full Switchover (`-m full`)

- Switches all traffic
- Manages replication slots and CDC
- Syncs sequences

### Read-only Switchover (`-m readonly`)

- Switches only read traffic
- For testing/gradual migration
- No write impact

## Monitoring

### CDC Output

All monitoring data in `cdc_output/`:
- CDC events
- Read/write load stats
- App metrics
- Replication status

### Test Application

Sample Elixir app helps verify:
- Connection handling
- Data consistency
- Performance impact

## Cleanup

```bash
./run.sh test-setup --destroy
```

Stops:
- Docker containers
- CDC monitoring
- Load simulation
- Test application

## Troubleshooting

### Common Issues

**High Replication Lag**
- Check `cdc_output` logs
- Adjust `max_lag_bytes`
- Verify load settings

**CDC Issues**
- Check `continuous-cdc.sh` logs
- Verify Kafka Connect
- Check Debezium config

**App Errors**
- Check Elixir app logs
- Verify connectivity
- Check PgBouncer status

## Support

For issues provide:
- Error messages
- Relevant logs
- Reproduction steps
- Environment details
