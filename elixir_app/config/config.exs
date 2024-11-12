# config/config.exs
import Config

config :elixir_app, ElixirApp.WriteRepo,
  username: System.get_env("POSTGRES_USER", "testuser"),
  password: System.get_env("POSTGRES_PASSWORD", "testpass"),
  hostname: System.get_env("PGBOUNCER_HOST", "pgbouncer"),
  port: String.to_integer(System.get_env("PGBOUNCER_PORT", "6432")),
  database: System.get_env("POSTGRES_DB", "testdb_rw"),
  show_sensitive_data_on_connection_error: true,
  queue_target: 2000,
  queue_interval: 10000, 
  timeout: 50000,
  pool_size: 50

config :elixir_app, ElixirApp.ReadRepo,
  username: System.get_env("POSTGRES_USER", "testuser"),
  password: System.get_env("POSTGRES_PASSWORD", "testpass"),
  hostname: System.get_env("PGBOUNCER_HOST", "pgbouncer"),
  port: String.to_integer(System.get_env("PGBOUNCER_PORT", "6432")),
  database: System.get_env("POSTGRES_DB", "testdb_ro"),
  show_sensitive_data_on_connection_error: true,
  pool_size: 50

config :logger,
  level: :debug