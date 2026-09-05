defmodule TamayotchiStack.New.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/tamayotchi/my_stack"

  def project do
    [
      app: :tamayotchi_stack_new,
      version: @version,
      elixir: "~> 1.17",
      deps: [],
      aliases: aliases(),
      description: "Create a new application and configure it with Tamayotchi Stack",
      source_url: @source_url,
      package: [
        licenses: ["MIT"],
        links: %{"GitHub" => @source_url},
        files: ~w(lib mix.exs README.md LICENSE)
      ]
    ]
  end

  def application do
    [extra_applications: [:eex, :logger]]
  end

  def cli do
    [preferred_envs: [precommit: :test]]
  end

  defp aliases do
    [
      precommit: ["compile --warning-as-errors", "format --check-formatted", "test"]
    ]
  end
end
