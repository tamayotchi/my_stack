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
    phoenix? = Keyword.has_key?(features, :phoenix)
    kamal_config = Keyword.get(features, :kamal, [])

    options =
      [phoenix: phoenix?, r2: Keyword.has_key?(features, :r2)]
      |> maybe_put_kamal_proxy(kamal_config, phoenix?)

    Setup.configure(igniter, options)
  end

  defp maybe_put_kamal_proxy(options, kamal_config, true) do
    case Keyword.fetch(kamal_config, :proxy) do
      {:ok, proxy?} -> Keyword.put(options, :kamal_proxy, proxy?)
      :error -> options
    end
  end

  defp maybe_put_kamal_proxy(options, _kamal_config, false), do: options
end
