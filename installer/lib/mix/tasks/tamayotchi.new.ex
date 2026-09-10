defmodule Mix.Tasks.Tamayotchi.New do
  @shortdoc "Creates a new app configured by Tamayotchi Stack"
  @moduledoc """
  Creates a new Mix or Phoenix application, installs Tamayotchi Stack, and runs
  its first configuration pass.

      mix tamayotchi.new my_app

  ## Options

    * `--phoenix` / `--no-phoenix` - choose Phoenix (default: yes)
    * `--r2` / `--no-r2` - choose Cloudflare R2 storage (default: no)
    * `--proxy` / `--no-proxy` - choose kamal-proxy (default: yes with Phoenix)
    * `--host HOST` - public DNS hostname (default: <app-slug>.tamayotchi.com);
      independent of the app name, GoatCounter collector, and storage identities
    * `--secrets` / `--no-secrets` - automatically create/save missing credentials
      in 1Password after configuration (default: yes)
    * `--yes` - accept defaults, including automatic credentials, without prompting

  The application name determines its directory, root module, and GoatCounter
  endpoint. Every generated project initializes a Git repository.
  Phoenix always includes SQLite, Kamal, GoatCounter, and daily database backups.
  Plain Mix applications include none of these. Only R2 and kamal-proxy are choices.
  """

  use Mix.Task

  alias TamayotchiStack.New

  @switches [
    phoenix: :boolean,
    r2: :boolean,
    proxy: :boolean,
    host: :string,
    secrets: :boolean,
    yes: :boolean
  ]

  @aliases [y: :yes]

  @impl Mix.Task
  def run(argv) do
    {options, positional} = OptionParser.parse!(argv, strict: @switches, aliases: @aliases)
    app_name = resolve_app_name(positional, options)
    validate_app_name!(app_name)

    phoenix? = resolve_boolean(options, :phoenix, "Include Phoenix?", true)
    r2? = resolve_boolean(options, :r2, "Include Cloudflare R2 storage?", false)
    proxy? = resolve_proxy(options, phoenix?)
    host = resolve_host(options, phoenix?)

    announce_goatcounter_endpoint(app_name, phoenix?)
    target = Path.expand(app_name)

    if File.exists?(target) do
      Mix.raise("Target directory already exists: #{target}")
    end

    generate_project!(target, phoenix?)
    install_stack!(target)
    init_git!(target)
    configure_stack!(target, phoenix?, r2?, proxy?, Keyword.get(options, :secrets, true), host)

    Mix.shell().info([
      :green,
      "\nCreated #{app_name} at #{target}\n",
      :reset,
      "Next: cd #{target} && mix tamayotchi.doctor"
    ])
  end

  defp resolve_app_name([], options) do
    if Keyword.get(options, :yes, false) do
      Mix.raise("Application name is required when --yes is used")
    else
      Mix.shell().prompt("Application name") |> String.trim()
    end
  end

  defp resolve_app_name([app_name], _options), do: app_name

  defp resolve_app_name(positional, _options) do
    Mix.raise("Expected one application name, got: #{Enum.join(positional, " ")}")
  end

  defp resolve_boolean(options, key, prompt, default) do
    case Keyword.fetch(options, key) do
      {:ok, value} -> value
      :error -> if(Keyword.get(options, :yes, false), do: default, else: confirm(prompt, default))
    end
  end

  defp confirm(prompt, default) do
    suffix = if default, do: "[Y/n]", else: "[y/N]"

    case Mix.shell().prompt("#{prompt} #{suffix}") |> String.trim() |> String.downcase() do
      "" ->
        default

      answer when answer in ["y", "yes"] ->
        true

      answer when answer in ["n", "no"] ->
        false

      _ ->
        Mix.shell().error("Please answer yes or no.")
        confirm(prompt, default)
    end
  end

  defp announce_goatcounter_endpoint(_app_name, false), do: :ok

  defp announce_goatcounter_endpoint(app_name, true) do
    Mix.shell().info("GoatCounter endpoint: #{New.goatcounter_endpoint_for_app(app_name)}")
  end

  defp validate_app_name!(app_name) do
    case New.validate_app_name(app_name) do
      :ok -> :ok
      {:error, reason} -> Mix.raise(reason)
    end
  end

  defp resolve_proxy(options, true) do
    resolve_boolean(options, :proxy, "Use kamal-proxy?", true)
  end

  defp resolve_proxy(options, false) do
    if Keyword.has_key?(options, :proxy) do
      Mix.raise("--proxy/--no-proxy requires Phoenix; Kamal is only included with Phoenix")
    end

    false
  end

  defp resolve_host(options, phoenix?) do
    if host = options[:host] do
      unless phoenix?, do: Mix.raise("--host requires Phoenix")

      case New.validate_host(host) do
        :ok -> host
        {:error, reason} -> Mix.raise(reason)
      end
    end
  end

  defp generate_project!(target, true) do
    New.run_command!("mix", ["phx.new", target, "--no-install", "--database", "sqlite3"])
  end

  defp generate_project!(target, false) do
    New.run_command!("mix", ["new", target, "--sup"])
  end

  defp install_stack!(target) do
    mix_path = Path.join(target, "mix.exs")
    dependency = New.dependency()

    updated =
      mix_path
      |> File.read!()
      |> New.inject_dependency(dependency)
      |> case do
        {:ok, contents} -> contents
        {:error, reason} -> Mix.raise(reason)
      end

    File.write!(mix_path, updated)
    New.run_command!("mix", ["deps.get"], cd: target)
  end

  defp configure_stack!(target, phoenix?, r2?, proxy?, secrets?, host) do
    arguments = New.setup_arguments(phoenix?, r2?, proxy?, secrets?, host)

    New.run_command!("mix", arguments, cd: target)
    New.run_command!("mix", ["deps.get"], cd: target)
    New.run_command!("mix", ["format"], cd: target)
  end

  defp init_git!(target) do
    unless File.dir?(Path.join(target, ".git")) do
      New.run_command!("git", ["init", "-b", "main"], cd: target)
    end
  end
end
