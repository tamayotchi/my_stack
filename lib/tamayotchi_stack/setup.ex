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
        GoatCounter.configure(igniter, GoatCounter.endpoint_for_app(app_name))
      else
        igniter
      end

    igniter = R2.configure(igniter, app_name, Keyword.get(options, :r2, false))

    kamal? = Keyword.get(options, :kamal, false)
    kamal_options = if kamal?, do: [proxy: Keyword.fetch!(options, :kamal_proxy)], else: []

    igniter
    |> Kamal.configure(app_name, kamal?, kamal_options)
    |> Backups.configure(app_name, Keyword.get(options, :backups, false), kamal?)
  end
end
