# priv/repo/migrations/20240304000000_create_customers.exs
defmodule ElixirApp.Repo.Migrations.CreateCustomers do
  use Ecto.Migration

  def up do
    execute """
    CREATE TABLE IF NOT EXISTS customers (
      id SERIAL PRIMARY KEY,
      name VARCHAR(100),
      email VARCHAR(200),
      created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    )
    """
  end

  def down do
    execute "DROP TABLE IF EXISTS customers"
  end
end