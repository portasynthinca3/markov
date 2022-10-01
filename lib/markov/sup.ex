defmodule Markov.Sup do
  use Supervisor
  @moduledoc "Main supervisor"

  require Logger

  def start_link(args) do
    Supervisor.start_link(__MODULE__, args, name: __MODULE__)
  end

  def stop do
    Supervisor.stop(__MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      {DynamicSupervisor, name: Markov.ModelSup},
      {Registry, keys: :unique, name: Markov.ModelServers},
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
