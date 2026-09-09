defmodule TamayotchiStack.SetupOptions do
  @moduledoc false

  alias TamayotchiStack.Manifest
  alias TamayotchiStack.Project
  alias TamayotchiStack.Prompt

  @spec resolve(Igniter.t(), keyword()) :: keyword()
  def resolve(igniter, cli_options) do
    # Igniter composition can discard unknown negated flags. Check raw flags too
    # so old opt-outs cannot silently enable database/deployment/provisioning work.
    obsolete_options? =
      Enum.any?([:sqlite, :kamal, :backups], &Keyword.has_key?(cli_options, &1)) or
        Enum.any?(
          igniter.args.argv_flags,
          &Regex.match?(~r/^--(?:tamayotchi\.)?(?:no-)?(?:sqlite|kamal|backups)(?:=|$)/, &1)
        )

    if obsolete_options? do
      Mix.raise(
        "SQLite, Kamal, and backups are automatic with Phoenix; remove their separate flags"
      )
    end

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

    [phoenix: phoenix?, r2: r2?]
    |> maybe_put_kamal_proxy(igniter, cli_options, phoenix?, yes?)
  end

  defp r2_enabled?(igniter), do: feature_enabled?(igniter, :r2)

  defp feature_enabled?(igniter, feature) do
    case Manifest.read(igniter) do
      {:ok, manifest} -> Keyword.has_key?(manifest[:features], feature)
      {:error, _} -> false
    end
  end

  defp maybe_put_kamal_proxy(options, igniter, cli_options, true, yes?) do
    default = Project.kamal_proxy?(igniter, true)

    proxy? =
      Prompt.confirm("Use kamal-proxy?", default,
        value: fetch_optional(cli_options, :proxy),
        yes: yes?
      )

    Keyword.put(options, :kamal_proxy, proxy?)
  end

  defp maybe_put_kamal_proxy(options, _igniter, cli_options, false, _yes?) do
    if Keyword.has_key?(cli_options, :proxy) do
      Mix.raise("--proxy/--no-proxy requires Phoenix; Kamal is only included with Phoenix")
    end

    options
  end

  defp fetch_optional(options, key) do
    if Keyword.has_key?(options, key), do: Keyword.fetch!(options, key)
  end
end
