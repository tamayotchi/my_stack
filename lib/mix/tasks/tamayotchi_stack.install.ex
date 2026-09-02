defmodule Mix.Tasks.TamayotchiStack.Install do
  @shortdoc "Installs Tamayotchi Stack conventions"
  @moduledoc """
  Igniter installer used by `mix igniter.install tamayotchi_stack` and the
  `tamayotchi.new` archive.
  """

  use Igniter.Mix.Task

  @impl Igniter.Mix.Task
  def info(_argv, _composing_task) do
    TamayotchiStack.TaskInfo.setup(only: [:dev, :test], dep_opts: [runtime: false])
  end

  @impl Igniter.Mix.Task
  def igniter(igniter) do
    options = TamayotchiStack.SetupOptions.resolve(igniter, igniter.args.options)
    TamayotchiStack.Setup.configure(igniter, options)
  end
end
