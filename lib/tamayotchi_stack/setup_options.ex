defmodule TamayotchiStack.SetupOptions do
  @moduledoc false

  alias TamayotchiStack.Manifest
  alias TamayotchiStack.Project
  alias TamayotchiStack.Prompt

  @spec resolve(Igniter.t(), keyword()) :: keyword()
  def resolve(igniter, cli_options) do
    yes? = Keyword.get(cli_options, :yes, false)

    phoenix? =
      Prompt.confirm("Include Phoenix configuration?", Project.phoenix?(igniter),
        value: fetch_optional(cli_options, :phoenix),
        yes: yes?
      )

    r2? =
      Prompt.confirm("Include Cloudflare R2 storage?", r2_enabled?(igniter),
        value: fetch_optional(cli_options, :r2),
        yes: yes?
      )

    kamal? = resolve_kamal(cli_options, phoenix?, yes?)

    options =
      [phoenix: phoenix?, r2: r2?, kamal: kamal?]
      |> maybe_put_kamal_proxy(igniter, cli_options, kamal?, yes?)

    backups? =
      if kamal? and Project.sqlite?(igniter) do
        Prompt.confirm("Include daily SQLite backups?", feature_enabled?(igniter, :backups),
          value: fetch_optional(cli_options, :backups),
          yes: yes?
        )
      else
        Keyword.get(cli_options, :backups, feature_enabled?(igniter, :backups))
      end

    Keyword.put(options, :backups, backups?)
  end

  defp r2_enabled?(igniter), do: feature_enabled?(igniter, :r2)

  defp feature_enabled?(igniter, feature) do
    case Manifest.read(igniter) do
      {:ok, manifest} -> Keyword.has_key?(manifest[:features], feature)
      {:error, _} -> false
    end
  end

  defp resolve_kamal(cli_options, true, yes?) do
    Prompt.confirm("Include Kamal deployment?", true,
      value: fetch_optional(cli_options, :kamal),
      yes: yes?
    )
  end

  defp resolve_kamal(cli_options, false, _yes?) do
    fetch_optional(cli_options, :kamal) == true
  end

  defp maybe_put_kamal_proxy(options, igniter, cli_options, true, yes?) do
    default = if Project.kamal?(igniter), do: Project.kamal_proxy?(igniter), else: true

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
