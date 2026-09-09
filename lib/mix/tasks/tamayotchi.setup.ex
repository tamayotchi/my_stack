defmodule Mix.Tasks.Tamayotchi.Setup do
  @shortdoc "Configures Tamayotchi Stack in an existing repository"
  @moduledoc """
  Detects the current project, asks which supported features to manage, and
  presents an Igniter diff before writing app-owned implementation.

      mix tamayotchi.setup
      mix tamayotchi.setup --phoenix

  Phoenix always includes Kamal deployment; --no-phoenix does not add Kamal.
  SQLite always includes backup scripts. With Phoenix, the daily Kamal backup
  role and deployment credentials are configured automatically.

  ## Options

    * `--phoenix` / `--no-phoenix` - choose Phoenix; GoatCounter and Kamal are automatic
    * `--r2` / `--no-r2` - choose Cloudflare R2 storage (default: no on first setup)
    * `--proxy` / `--no-proxy` - choose kamal-proxy when using Phoenix
    * `--secrets` / `--no-secrets` - set up missing credentials in 1Password after
      accepted file changes (default: yes); requires one-time bootstrap credentials
    * `--yes` - accept defaults, file changes, and automatic credential setup
  """

  use Igniter.Mix.Task

  @impl Igniter.Mix.Task
  def info(_argv, _composing_task), do: TamayotchiStack.TaskInfo.setup()

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    options = TamayotchiStack.SetupOptions.resolve(igniter, igniter.args.options)

    igniter
    |> TamayotchiStack.Setup.configure(options)
    |> TamayotchiStack.Secrets.queue_setup(igniter.args.options)
  end
end
