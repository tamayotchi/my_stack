defmodule TamayotchiStack.Sync do
  @moduledoc false

  alias TamayotchiStack.Features.GoatCounter
  alias TamayotchiStack.Manifest
  alias TamayotchiStack.Setup

  @spec run(Igniter.t()) :: Igniter.t()
  def run(igniter) do
    case Manifest.read(igniter) do
      {:ok, manifest} -> sync_manifest(igniter, manifest)
      {:error, reason} -> Igniter.add_issue(igniter, reason)
    end
  end

  defp sync_manifest(igniter, manifest) do
    app_name = Keyword.fetch!(manifest, :app)
    features = Keyword.fetch!(manifest, :features)
    phoenix? = Keyword.has_key?(features, :phoenix)
    kamal_config = Keyword.get(features, :kamal)
    kamal? = is_list(kamal_config)

    options =
      [phoenix: phoenix?, kamal: kamal?]
      |> maybe_put_goatcounter_endpoint(app_name, phoenix?)
      |> maybe_put_kamal_proxy(kamal_config, kamal?)

    Setup.configure(igniter, options)
  end

  defp maybe_put_goatcounter_endpoint(options, app_name, true) do
    Keyword.put(options, :goatcounter_endpoint, GoatCounter.endpoint_for_app(app_name))
  end

  defp maybe_put_goatcounter_endpoint(options, _app_name, false), do: options

  defp maybe_put_kamal_proxy(options, kamal_config, true) do
    Keyword.put(options, :kamal_proxy, Keyword.get(kamal_config, :proxy, true))
  end

  defp maybe_put_kamal_proxy(options, _kamal_config, false), do: options
end
