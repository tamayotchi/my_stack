defmodule Mix.Tasks.Tamayotchi.Doctor do
  @shortdoc "Reports Tamayotchi Stack configuration health"
  @moduledoc """
  Inspects the current repository without changing files.

      mix tamayotchi.doctor
      mix tamayotchi.doctor --format json --check

  `--check` exits unsuccessfully when the manifest is invalid or a managed
  feature is inconsistent.
  """

  use Mix.Task

  @switches [format: :string, check: :boolean]

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("compile")
    {options, positional} = OptionParser.parse!(argv, strict: @switches)

    if positional != [] do
      Mix.raise("Unexpected arguments: #{Enum.join(positional, " ")}")
    end

    report = TamayotchiStack.Doctor.report()

    case Keyword.get(options, :format, "text") do
      "text" -> Mix.shell().info(TamayotchiStack.Doctor.format(report))
      "json" -> Mix.shell().info(Jason.encode!(report, pretty: true))
      format -> Mix.raise("Unsupported format #{inspect(format)}; expected text or json")
    end

    if Keyword.get(options, :check, false) and not TamayotchiStack.Doctor.healthy?(report) do
      Mix.raise("Tamayotchi Stack configuration is not healthy")
    end
  end
end
