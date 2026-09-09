defmodule TamayotchiStack.TaskInfo do
  @moduledoc false

  # Igniter supplies --dry-run globally. Reject it here rather than silently
  # ignoring a removed safety flag and applying changes, including in composition.
  def reject_dry_run!(argv) do
    if Enum.any?(argv, &Regex.match?(~r/^--(?:tamayotchi\.)?(?:no-)?dry-run(?:=|$)/, &1)) do
      Mix.raise(
        "Tamayotchi commands no longer support --dry-run; changes still use the normal confirmation flow."
      )
    end
  end

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
