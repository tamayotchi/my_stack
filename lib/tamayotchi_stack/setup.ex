defmodule TamayotchiStack.Setup do
  @moduledoc false

  alias TamayotchiStack.Features.Backups
  alias TamayotchiStack.Features.GoatCounter
  alias TamayotchiStack.Features.Kamal
  alias TamayotchiStack.Features.Phoenix
  alias TamayotchiStack.Features.R2
  alias TamayotchiStack.Project

  @spec configure(Igniter.t(), keyword()) :: Igniter.t()
  def configure(igniter, options) do
    app_name = Project.app_name(igniter)
    phoenix? = Keyword.fetch!(options, :phoenix)
    igniter = Phoenix.configure(igniter, app_name, phoenix?)

    igniter =
      if phoenix? do
        GoatCounter.configure(igniter, app_name)
      else
        igniter
      end

    igniter = R2.configure(igniter, app_name, Keyword.get(options, :r2, false))

    # Kamal follows Phoenix; only its proxy is a separate choice.
    kamal_options =
      if phoenix?,
        do: [proxy: Keyword.get(options, :kamal_proxy, Project.kamal_proxy?(igniter, true))],
        else: []

    igniter
    |> Kamal.configure(app_name, phoenix?, kamal_options)
    |> Backups.configure(app_name, phoenix?)
  end
end
