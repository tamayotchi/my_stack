defmodule Mix.Tasks.Tamayotchi.New do
  @shortdoc "Creates a new app configured by Tamayotchi Stack"
  @moduledoc """
  Creates a new Mix or Phoenix application, installs Tamayotchi Stack, and runs
  its first configuration pass.

      mix tamayotchi.new my_app

  ## Options

    * `--phoenix` / `--no-phoenix` - choose Phoenix (default: yes)
    * `--sqlite` / `--no-sqlite` - choose SQLite when using Phoenix (default: yes)
    * `--kamal` / `--no-kamal` - choose Kamal deployment (default: yes with Phoenix)
    * `--proxy` / `--no-proxy` - choose kamal-proxy (default: yes with Kamal)
    * `--yes` - accept defaults without prompting

  The application name determines its directory, root module, and GoatCounter
  endpoint. Every generated project initializes a Git repository.
  """

  use Mix.Task

  alias TamayotchiStack.New

  @switches [phoenix: :boolean, sqlite: :boolean, kamal: :boolean, proxy: :boolean, yes: :boolean]

  @aliases [y: :yes]

  @impl Mix.Task
  def run(argv) do
    {options, positional} = OptionParser.parse!(argv, strict: @switches, aliases: @aliases)
    app_name = resolve_app_name(positional, options)
    validate_app_name!(app_name)

    phoenix? = resolve_boolean(options, :phoenix, "Include Phoenix?", true)
    sqlite? = resolve_sqlite(options, phoenix?)
    kamal? = resolve_kamal(options, phoenix?)
    proxy? = resolve_proxy(options, kamal?)

    announce_goatcounter_endpoint(app_name, phoenix?)
    target = Path.expand(app_name)

    if File.exists?(target) do
      Mix.raise("Target directory already exists: #{target}")
    end

    generate_project!(target, phoenix?, sqlite?)
    install_stack!(target)
    configure_stack!(target, phoenix?, kamal?, proxy?)
    init_git!(target)

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

  defp resolve_sqlite(options, true) do
    resolve_boolean(options, :sqlite, "Include SQLite database?", true)
  end

  defp resolve_sqlite(options, false) do
    if Keyword.get(options, :sqlite, false) do
      Mix.raise("--sqlite requires Phoenix; enable --phoenix or remove it")
    end

    false
  end

  defp resolve_kamal(options, true) do
    resolve_boolean(options, :kamal, "Include Kamal deployment?", true)
  end

  defp resolve_kamal(options, false) do
    if Keyword.get(options, :kamal, false) do
      Mix.raise("--kamal requires Phoenix; enable --phoenix or remove it")
    end

    false
  end

  defp resolve_proxy(options, true) do
    resolve_boolean(options, :proxy, "Use kamal-proxy?", true)
  end

  defp resolve_proxy(options, false) do
    if Keyword.has_key?(options, :proxy) do
      Mix.raise("--proxy/--no-proxy requires Kamal")
    end

    false
  end

  defp generate_project!(target, true, sqlite?) do
    database_args = if sqlite?, do: ["--database", "sqlite3"], else: ["--no-ecto"]
    New.run_command!("mix", ["phx.new", target, "--no-install"] ++ database_args)
  end

  defp generate_project!(target, false, _sqlite?) do
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

  defp configure_stack!(target, phoenix?, kamal?, proxy?) do
    arguments = [
      "tamayotchi_stack.install",
      "--yes",
      if(phoenix?, do: "--phoenix", else: "--no-phoenix"),
      if(kamal?, do: "--kamal", else: "--no-kamal")
    ]

    arguments =
      if kamal?, do: arguments ++ [if(proxy?, do: "--proxy", else: "--no-proxy")], else: arguments

    New.run_command!("mix", arguments, cd: target)
    New.run_command!("mix", ["format"], cd: target)
  end

  defp init_git!(target) do
    unless File.dir?(Path.join(target, ".git")) do
      New.run_command!("git", ["init", "-b", "main"], cd: target)
    end
  end
end
