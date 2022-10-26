defmodule Markov.PartTimeout do
  @moduledoc """
  Asks the model server to unload a partition after some time of inactivity
  """

  defp loop(parent, timeout, num) do
    receive do
      :defer -> loop(parent, timeout, num)
    after timeout ->
      send(parent, {:unload_part, num})
    end
  end

  def start_link(parent, timeout, num) do
    spawn_link(fn -> loop(parent, timeout, num) end)
  end
end
