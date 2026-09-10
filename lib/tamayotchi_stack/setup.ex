defmodule TamayotchiStack.Setup do
  @moduledoc false

  alias TamayotchiStack.Features.Backups
  alias TamayotchiStack.Features.GoatCounter
  alias TamayotchiStack.Features.Kamal
  alias TamayotchiStack.Features.Phoenix
  alias TamayotchiStack.Features.R2
  alias TamayotchiStack.Manifest
  alias TamayotchiStack.Project
  alias TamayotchiStack.PublicHost

  @spec configure(Igniter.t(), keyword()) :: Igniter.t()
  def configure(igniter, options) do
    phoenix? = Keyword.fetch!(options, :phoenix)

    cond do
      Keyword.has_key?(options, :host) and not phoenix? ->
        Igniter.add_issue(igniter, "--host requires Phoenix")

      Keyword.has_key?(options, :host) and not PublicHost.valid?(options[:host]) ->
        {:error, reason} = PublicHost.validate(options[:host])
        Igniter.add_issue(igniter, reason)

      phoenix? and not Project.sqlite?(igniter) ->
        Igniter.add_issue(
          igniter,
          "Phoenix requires SQLite. This repository has no ecto_sqlite3 dependency. " <>
            "Create a new app with mix tamayotchi.new, or explicitly configure/migrate this " <>
            "repository to SQLite before retrying. No database backend or data was changed."
        )

      true ->
        configure_supported(igniter, options, phoenix?)
    end
  end

  defp configure_supported(igniter, options, phoenix?) do
    app_name = Project.app_name(igniter)

    saved_host =
      case Manifest.read(igniter) do
        {:ok, manifest} -> PublicHost.from_manifest(manifest)
        _ -> nil
      end

    host = if phoenix?, do: Keyword.get(options, :host, saved_host)
    host_options = if host, do: [host: host], else: []
    igniter = Phoenix.configure(igniter, app_name, phoenix?, host_options)

    igniter =
      if phoenix? do
        GoatCounter.configure(igniter, app_name)
      else
        igniter
      end

    igniter = R2.configure(igniter, app_name, Keyword.get(options, :r2, false))

    # SQLite, Kamal, and backups follow Phoenix; only the proxy is a choice.
    kamal_options =
      if phoenix?,
        do: [proxy: Keyword.get(options, :kamal_proxy, Project.kamal_proxy?(igniter, true))],
        else: []

    igniter
    |> Kamal.configure(app_name, phoenix?, kamal_options ++ host_options)
    |> Backups.configure(app_name, phoenix?)
  end
end
