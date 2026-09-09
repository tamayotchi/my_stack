defmodule TamayotchiStack.TaskInfo do
  @moduledoc false

  @spec setup(keyword()) :: Igniter.Mix.Task.Info.t()
  def setup(overrides \\ []) do
    struct!(
      Igniter.Mix.Task.Info,
      Keyword.merge(
        [
          group: :tamayotchi,
          schema: [
            phoenix: :boolean,
            r2: :boolean,
            proxy: :boolean,
            secrets: :boolean
          ],
          defaults: [],
          aliases: [],
          positional: [],
          example: "mix tamayotchi.setup"
        ],
        overrides
      )
    )
  end
end
