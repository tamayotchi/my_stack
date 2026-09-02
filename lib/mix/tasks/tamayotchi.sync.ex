defmodule Mix.Tasks.Tamayotchi.Sync do
  @shortdoc "Synchronizes app-owned files with current Tamayotchi conventions"
  @moduledoc """
  Reads `.tamayotchi.exs`, inspects the repository, and presents an Igniter
  diff for any required updates.

      mix tamayotchi.sync
  """

  use Igniter.Mix.Task

  @impl Igniter.Mix.Task
  def info(_argv, _composing_task) do
    %Igniter.Mix.Task.Info{group: :tamayotchi, example: "mix tamayotchi.sync"}
  end

  @impl Igniter.Mix.Task
  def igniter(igniter), do: TamayotchiStack.Sync.run(igniter)
end
