defmodule TamayotchiStack.Setup do
  @moduledoc false

  alias TamayotchiStack.Features.GoatCounter
  alias TamayotchiStack.Features.Kamal
  alias TamayotchiStack.Features.Phoenix
  alias TamayotchiStack.Project

  @spec configure(Igniter.t(), keyword()) :: Igniter.t()
  def configure(igniter, options) do
    app_name = Project.app_name(igniter)
    phoenix? = Keyword.fetch!(options, :phoenix)
    igniter = Phoenix.configure(igniter, app_name, phoenix?)

    igniter =
      if phoenix? do
        GoatCounter.configure(igniter, Keyword.fetch!(options, :goatcounter_endpoint))
      else
        igniter
      end

    kamal? = Keyword.get(options, :kamal, false)
    kamal_options = if kamal?, do: [proxy: Keyword.fetch!(options, :kamal_proxy)], else: []
    Kamal.configure(igniter, app_name, kamal?, kamal_options)
  end
end
