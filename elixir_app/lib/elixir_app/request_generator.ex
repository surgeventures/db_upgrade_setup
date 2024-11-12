# lib/elixir_app/request_generator.ex
defmodule ElixirApp.RequestGenerator do
  use GenServer
  require Logger
  alias ElixirApp.{Customer, WriteRepo, ReadRepo}
  import Ecto.Query

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  def init(_) do
    schedule_requests()
    {:ok, %{counter: 1}}
  end

  def handle_info(:generate_requests, %{counter: counter} = state) do
    # Spawn write requests
    Task.async_stream(1..5, fn _ ->
      customer = %Customer{
        name: "User #{counter}_#{:rand.uniform(1000)}",
        email: "user#{counter}_#{:rand.uniform(1000)}@example.com"
      }
      
      case WriteRepo.insert(customer) do
        {:ok, _} -> Logger.info("Successfully wrote customer")
        {:error, error} -> Logger.error("Failed to write customer: #{inspect(error)}")
      end
    end, max_concurrency: 5, timeout: 50_000,) |> Stream.run()

    # Spawn read requests
    Task.async_stream(1..5, fn _ ->
      case ReadRepo.one(from c in Customer, order_by: fragment("RANDOM()"), limit: 1) do
        nil -> Logger.info("No customers found")
        customer -> Logger.info("Read customer: #{customer.name}")
      end
    end, max_concurrency: 5) |> Stream.run()

    schedule_requests()
    {:noreply, %{state | counter: counter + 1}}
  end

  defp schedule_requests do
    Process.send_after(self(), :generate_requests, 1_000)
  end
end