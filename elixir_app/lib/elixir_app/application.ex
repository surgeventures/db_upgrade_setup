# lib/elixir_app/application.ex
defmodule ElixirApp.Application do
  use Application
  require Logger

  def start(_type, _args) do
    children = [
      ElixirApp.WriteRepo,
      ElixirApp.ReadRepo,
      ElixirApp.RequestGenerator
    ]

    # Run migrations before starting the application
    migrate_database()

    opts = [strategy: :one_for_one, name: ElixirApp.Supervisor]
    Supervisor.start_link(children, opts)
  end


  defp migrate_database do
    Logger.info("Running database migrations...")
    
    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = ElixirApp.WriteRepo.start_link([])

    # Run migrations (this will create schema_migrations table automatically)
    path = Application.app_dir(:elixir_app, "priv/repo/migrations")
    Ecto.Migrator.run(ElixirApp.WriteRepo, path, :up, all: true)

    # Stop temporary repo connection
    ElixirApp.WriteRepo.stop()
    
    :ok
  end
end