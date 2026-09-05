defmodule TamayotchiStack.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/tamayotchi/my_stack"

  def project do
    [
      app: :tamayotchi_stack,
      version: @version,
      elixir: "~> 1.17",
      deps: deps(),
      aliases: aliases(),
      description:
        "Opinionated, Igniter-powered setup and synchronization for Tamayotchi Phoenix apps",
      source_url: @source_url,
      package: package()
    ]
  end

  def application do
    [extra_applications: [:logger, :eex]]
  end

  def cli do
    [preferred_envs: [precommit: :test]]
  end

  defp deps do
    [
      {:igniter, "~> 0.8"},
      {:jason, "~> 1.4"}
    ]
  end

  defp aliases do
    [
      precommit: ["compile --warning-as-errors", "format --check-formatted", "test"]
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib priv docs .formatter.exs mix.exs README.md LICENSE)
    ]
  end
end
