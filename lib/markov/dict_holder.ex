defmodule Markov.DictionaryHolder do
  use GenServer
  @moduledoc """
  Loads the dictionary for prompt generation into a ets table
  """

  require Logger

  def start_link(init_args) do
    GenServer.start_link(__MODULE__, [init_args], name: __MODULE__)
  end

  def init(_args) do
    path = :code.priv_dir(:markov)
    {:ok, dets} = :dets.open_file(Path.join(path, "dict.dets") |> :erlang.binary_to_list)
    ets = :ets.new(Markov.Dictionary, [:set, :public, :named_table])
    :dets.to_ets(dets, ets)
    :dets.close(dets)

    Logger.debug("loaded dictionary")

    {:ok, nil}
  end
end
