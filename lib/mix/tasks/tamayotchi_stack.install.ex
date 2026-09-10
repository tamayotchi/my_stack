defmodule Mix.Tasks.TamayotchiStack.Install do
  @shortdoc "Installs Tamayotchi Stack conventions"
  @moduledoc """
  Igniter installer used by `mix igniter.install tamayotchi_stack` and the
  `tamayotchi.new` archive.
  """

  use Igniter.Mix.Task

  @impl Mix.Task
  def run(argv), do: argv |> super() |> TamayotchiStack.TaskInfo.ensure_success!()

  @impl Igniter.Mix.Task
  def info(argv, _composing_task) do
    TamayotchiStack.TaskInfo.reject_dry_run!(argv)
    TamayotchiStack.TaskInfo.setup(only: [:dev, :test], dep_opts: [runtime: false])
  end

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    options = TamayotchiStack.SetupOptions.resolve(igniter, igniter.args.options)

    igniter
    |> TamayotchiStack.Setup.configure(options)
    |> TamayotchiStack.Secrets.queue_setup(igniter.args.options)
  end
end
