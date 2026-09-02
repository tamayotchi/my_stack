defmodule TamayotchiStack.TaskInfo do
  @moduledoc false

  @spec setup(keyword()) :: Igniter.Mix.Task.Info.t()
  def setup(overrides \\ []) do
    struct!(
      Igniter.Mix.Task.Info,
      Keyword.merge(
        [
          group: :tamayotchi,
          schema: [phoenix: :boolean, kamal: :boolean, proxy: :boolean],
          defaults: [],
          aliases: [],
          positional: [],
          example: "mix tamayotchi.setup --phoenix"
        ],
        overrides
      )
    )
  end
end
