defmodule Markov.App do
  use Application
  @moduledoc "Markov OTP app"

  @impl true
  def start(_type, _args) do
    Markov.Sup.start_link([])
  end
end
