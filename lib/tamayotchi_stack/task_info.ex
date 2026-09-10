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

  # Igniter reports conflicts and write failures as :issues, but Mix otherwise
  # exits successfully. Do not let scripts mistake that result for applied setup.
  def ensure_success!(:issues) do
    Mix.raise(
      "Tamayotchi could not apply all changes. Resolve the reported issues before retrying; inspect repository files if a write failed."
    )
  end

  def ensure_success!(result), do: result

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
            host: :string,
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
