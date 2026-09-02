defmodule TamayotchiStack.SetupOptions do
  @moduledoc false

  alias TamayotchiStack.Features.GoatCounter
  alias TamayotchiStack.Features.Kamal
  alias TamayotchiStack.Project
  alias TamayotchiStack.Prompt

  @spec resolve(Igniter.t(), keyword()) :: keyword()
  def resolve(igniter, cli_options) do
    app_name = Project.app_name(igniter)
    yes? = Keyword.get(cli_options, :yes, false)

    phoenix? =
      Prompt.confirm("Include Phoenix configuration?", Project.phoenix?(igniter),
        value: fetch_optional(cli_options, :phoenix),
        yes: yes?
      )

    kamal? = resolve_kamal(igniter, cli_options, phoenix?, yes?)

    [phoenix: phoenix?, kamal: kamal?]
    |> maybe_put_goatcounter_endpoint(app_name, phoenix?)
    |> maybe_put_kamal_proxy(igniter, cli_options, kamal?, yes?)
  end

  defp resolve_kamal(_igniter, cli_options, true, yes?) do
    Prompt.confirm("Include Kamal deployment?", true,
      value: fetch_optional(cli_options, :kamal),
      yes: yes?
    )
  end

  defp resolve_kamal(_igniter, cli_options, false, _yes?) do
    fetch_optional(cli_options, :kamal) == true
  end

  defp maybe_put_goatcounter_endpoint(options, app_name, true) do
    Keyword.put(options, :goatcounter_endpoint, GoatCounter.endpoint_for_app(app_name))
  end

  defp maybe_put_goatcounter_endpoint(options, _app_name, false), do: options

  defp maybe_put_kamal_proxy(options, igniter, cli_options, true, yes?) do
    default = if Project.kamal?(igniter), do: Kamal.proxy?(igniter), else: true

    proxy? =
      Prompt.confirm("Use kamal-proxy?", default,
        value: fetch_optional(cli_options, :proxy),
        yes: yes?
      )

    Keyword.put(options, :kamal_proxy, proxy?)
  end

  defp maybe_put_kamal_proxy(options, _igniter, _cli_options, false, _yes?), do: options

  defp fetch_optional(options, key) do
    if Keyword.has_key?(options, key), do: Keyword.fetch!(options, key)
  end
end
