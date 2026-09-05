defmodule TamayotchiStack.Sync do
  @moduledoc false

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
    features = Keyword.fetch!(manifest, :features)
    kamal_config = Keyword.get(features, :kamal)
    kamal? = is_list(kamal_config)

    options =
      [
        phoenix: Keyword.has_key?(features, :phoenix),
        r2: Keyword.has_key?(features, :r2),
        backups: Keyword.has_key?(features, :backups),
        kamal: kamal?
      ]
      |> maybe_put_kamal_proxy(kamal_config, kamal?)

    Setup.configure(igniter, options)
  end

  defp maybe_put_kamal_proxy(options, kamal_config, true) do
    Keyword.put(options, :kamal_proxy, Keyword.get(kamal_config, :proxy, true))
  end

  defp maybe_put_kamal_proxy(options, _kamal_config, false), do: options
end
