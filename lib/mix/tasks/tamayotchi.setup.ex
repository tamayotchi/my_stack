defmodule Mix.Tasks.Tamayotchi.Setup do
  @shortdoc "Configures Tamayotchi Stack in an existing repository"
  @moduledoc """
  Detects the current project, asks which supported features to manage, and
  presents an Igniter diff before writing app-owned implementation.

      mix tamayotchi.setup
      mix tamayotchi.setup --phoenix

  ## Options

    * `--phoenix` / `--no-phoenix` - choose Phoenix; GoatCounter is automatic
    * `--kamal` / `--no-kamal` - choose Kamal deployment
    * `--proxy` / `--no-proxy` - choose kamal-proxy when using Kamal
    * `--yes` - accept defaults and the resulting Igniter changes
  """

  use Igniter.Mix.Task

  @impl Igniter.Mix.Task
  def info(_argv, _composing_task), do: TamayotchiStack.TaskInfo.setup()

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    options = TamayotchiStack.SetupOptions.resolve(igniter, igniter.args.options)
    TamayotchiStack.Setup.configure(igniter, options)
  end
end
