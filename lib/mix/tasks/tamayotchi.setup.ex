defmodule Mix.Tasks.Tamayotchi.Setup do
  @shortdoc "Configures Tamayotchi Stack in an existing repository"
  @moduledoc """
  Detects the current project, asks which supported features to manage, and
  presents an Igniter diff before writing app-owned implementation.

      mix tamayotchi.setup
      mix tamayotchi.setup --phoenix

  Phoenix always includes SQLite, Kamal, GoatCounter, and daily backups.
  Existing Phoenix repositories must already use SQLite; setup never silently
  changes database backends or migrates data. --no-phoenix adds none of these.

  ## Options

    * `--phoenix` / `--no-phoenix` - choose the Phoenix + SQLite + Kamal + backups stack
    * `--r2` / `--no-r2` - choose Cloudflare R2 storage (default: no on first setup)
    * `--proxy` / `--no-proxy` - choose kamal-proxy when using Phoenix
    * `--host HOST` - persist Phoenix's PHX_HOST and Kamal's proxy host;
      does not rename the app, resources, or change existing GoatCounter settings
    * `--secrets` / `--no-secrets` - set up missing credentials in 1Password after
      accepted file changes (default: yes); requires one-time bootstrap credentials
    * `--yes` - accept defaults, file changes, and automatic credential setup
  """

  use Igniter.Mix.Task

  @impl Mix.Task
  def run(argv), do: argv |> super() |> TamayotchiStack.TaskInfo.ensure_success!()

  @impl Igniter.Mix.Task
  def info(argv, _composing_task) do
    TamayotchiStack.TaskInfo.reject_dry_run!(argv)
    TamayotchiStack.TaskInfo.setup()
  end

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    options = TamayotchiStack.SetupOptions.resolve(igniter, igniter.args.options)

    igniter
    |> TamayotchiStack.Setup.configure(options)
    |> TamayotchiStack.Secrets.queue_setup(igniter.args.options)
  end
end
