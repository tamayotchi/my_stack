defmodule Mix.Tasks.Tamayotchi.Sync do
  @shortdoc "Synchronizes app-owned files with current Tamayotchi conventions"
  @moduledoc """
  Reads `.tamayotchi.exs`, inspects the repository, and presents an Igniter
  diff for any required updates.

      mix tamayotchi.sync
  """

  use Igniter.Mix.Task

  @impl Mix.Task
  def run(argv), do: argv |> super() |> TamayotchiStack.TaskInfo.ensure_success!()

  @impl Igniter.Mix.Task
  def info(argv, _composing_task) do
    TamayotchiStack.TaskInfo.reject_dry_run!(argv)
    %Igniter.Mix.Task.Info{group: :tamayotchi, example: "mix tamayotchi.sync"}
  end

  @impl Igniter.Mix.Task
  def igniter(igniter), do: TamayotchiStack.Sync.run(igniter)
end
