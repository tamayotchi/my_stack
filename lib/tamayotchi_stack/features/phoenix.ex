defmodule TamayotchiStack.Features.Phoenix do
  @moduledoc false

  alias TamayotchiStack.Manifest
  alias TamayotchiStack.Project

  @spec configure(Igniter.t(), atom(), boolean()) :: Igniter.t()
  def configure(igniter, app_name, enabled?) do
    igniter = Manifest.set_feature(igniter, app_name, :phoenix, enabled?)

    cond do
      not enabled? ->
        igniter

      Project.phoenix?(igniter) ->
        Igniter.add_notice(igniter, "Phoenix configuration detected and adopted.")

      true ->
        Igniter.add_issue(
          igniter,
          "Phoenix was selected, but this repository does not have a standard Phoenix dependency and assets/js/app.js"
        )
    end
  end
end
