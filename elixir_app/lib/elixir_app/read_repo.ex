defmodule ElixirApp.ReadRepo do
  use Ecto.Repo,
    otp_app: :elixir_app,
    adapter: Ecto.Adapters.Postgres
end