defmodule TamayotchiStack.Project do
  @moduledoc false

  @spec app_name(Igniter.t()) :: atom()
  def app_name(igniter), do: Igniter.Project.Application.app_name(igniter)

  @spec phoenix?(Igniter.t()) :: boolean()
  def phoenix?(igniter) do
    Igniter.exists?(igniter, "assets/js/app.js") and
      Igniter.exists?(igniter, "config/config.exs") and
      phoenix_dependency?(igniter)
  end

  @spec phoenix_on_disk?() :: boolean()
  def phoenix_on_disk? do
    File.exists?("assets/js/app.js") and File.exists?("config/config.exs") and
      dependency_on_disk?(:phoenix)
  end

  @spec sqlite?(Igniter.t()) :: boolean()
  def sqlite?(igniter), do: dependency?(igniter, :ecto_sqlite3)

  @spec kamal?(Igniter.t()) :: boolean()
  def kamal?(igniter) do
    Enum.all?(
      [
        "Dockerfile",
        ".dockerignore",
        "config/deploy.yml",
        ".kamal/secrets",
        "rel/overlays/bin/server"
      ],
      &Igniter.exists?(igniter, &1)
    )
  end

  @spec kamal_on_disk?() :: boolean()
  def kamal_on_disk? do
    Enum.all?(
      [
        "Dockerfile",
        ".dockerignore",
        "config/deploy.yml",
        ".kamal/secrets",
        "rel/overlays/bin/server"
      ],
      &File.exists?/1
    )
  end

  @spec kamal_proxy_on_disk?() :: boolean()
  def kamal_proxy_on_disk? do
    case File.read("config/deploy.yml") do
      {:ok, contents} -> String.contains?(contents, "\nproxy:\n")
      {:error, _reason} -> false
    end
  end

  @spec goatcounter_on_disk?() :: boolean()
  def goatcounter_on_disk? do
    File.exists?("assets/js/goatcounter.js") and
      File.exists?("assets/vendor/goatcounter.js") and
      app_js_imports_goatcounter?(File.read("assets/js/app.js"))
  end

  @spec goatcounter_endpoint_on_disk() :: String.t() | nil
  def goatcounter_endpoint_on_disk do
    with {:ok, contents} <- File.read("assets/js/goatcounter.js"),
         [_match, endpoint] <-
           Regex.run(~r/window\.goatcounter\.endpoint\s*=\s*["']([^"']+)["']/, contents) do
      endpoint
    else
      _ -> nil
    end
  end

  defp phoenix_dependency?(igniter), do: dependency?(igniter, :phoenix)

  defp dependency?(igniter, dependency) do
    igniter
    |> Igniter.include_existing_file("mix.exs", required?: true)
    |> Map.fetch!(:rewrite)
    |> Rewrite.source!("mix.exs")
    |> Rewrite.Source.get(:content)
    |> String.contains?("{#{inspect(dependency)},")
  end

  defp dependency_on_disk?(dependency) do
    case File.read("mix.exs") do
      {:ok, contents} -> String.contains?(contents, "{#{inspect(dependency)},")
      {:error, _reason} -> false
    end
  end

  defp app_js_imports_goatcounter?({:ok, contents}) do
    String.contains?(contents, ~s(import "./goatcounter")) or
      String.contains?(contents, ~s(import './goatcounter'))
  end

  defp app_js_imports_goatcounter?({:error, _reason}), do: false
end
