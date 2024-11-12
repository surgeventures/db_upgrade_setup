# lib/elixir_app/schemas/customer.ex
defmodule ElixirApp.Customer do
  use Ecto.Schema
  import Ecto.Changeset

  schema "customers" do
    field :name, :string
    field :email, :string
    field :created_at, :naive_datetime, default: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
  end

  def changeset(customer, attrs) do
    customer
    |> cast(attrs, [:name, :email])
    |> validate_required([:name, :email])
  end
end