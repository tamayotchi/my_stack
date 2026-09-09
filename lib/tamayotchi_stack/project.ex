defmodule TamayotchiStack.Project do
  @moduledoc false

  @kamal_files [
    "Dockerfile",
    ".dockerignore",
    "config/deploy.yml",
    ".kamal/secrets",
    "rel/overlays/bin/server"
  ]

  @kamal_sqlite_files [
    "rel/overlays/bin/migrate",
    "rel/overlays/bin/docker-entrypoint"
  ]

  @spec app_name(Igniter.t()) :: atom()
  def app_name(igniter), do: Igniter.Project.Application.app_name(igniter)

  @spec phoenix?(Igniter.t()) :: boolean()
  def phoenix?(igniter) do
    Igniter.exists?(igniter, "assets/js/app.js") and
      Igniter.exists?(igniter, "config/config.exs") and
      dependency?(igniter, :phoenix)
  end

  @spec phoenix_on_disk?() :: boolean()
  def phoenix_on_disk? do
    File.exists?("assets/js/app.js") and File.exists?("config/config.exs") and
      dependency_on_disk?(:phoenix)
  end

  @spec sqlite?(Igniter.t()) :: boolean()
  def sqlite?(igniter), do: dependency?(igniter, :ecto_sqlite3)

  @spec sqlite_on_disk?() :: boolean()
  def sqlite_on_disk?, do: dependency_on_disk?(:ecto_sqlite3)

  @spec kamal?(Igniter.t()) :: boolean()
  def kamal?(igniter), do: Enum.all?(@kamal_files, &Igniter.exists?(igniter, &1))

  @spec kamal_on_disk?() :: boolean()
  def kamal_on_disk? do
    Enum.all?(@kamal_files, &File.exists?/1) and sqlite_kamal_files_on_disk?()
  end

  @spec kamal_proxy?(Igniter.t(), boolean()) :: boolean()
  def kamal_proxy?(igniter, default \\ false) do
    if Igniter.exists?(igniter, "config/deploy.yml") do
      igniter
      |> source_content("config/deploy.yml")
      |> root_proxy?()
    else
      default
    end
  end

  @spec kamal_proxy_on_disk?(boolean()) :: boolean()
  def kamal_proxy_on_disk?(default \\ false) do
    case File.read("config/deploy.yml") do
      {:ok, contents} -> root_proxy?(contents)
      {:error, _reason} -> default
    end
  end

  @spec backups_on_disk?(boolean()) :: boolean()
  def backups_on_disk?(kamal? \\ false) do
    sqlite_on_disk?() and
      Enum.all?(TamayotchiStack.Features.Backups.paths(), &File.exists?/1) and
      file_contains?("rel/overlays/etc/backup.cron", ["/app/bin/litestream-backup"]) and
      file_contains?("rel/overlays/bin/litestream-backup", ["litestream replicate", "-once"]) and
      (not kamal? or backup_deployment_on_disk?())
  end

  defp backup_deployment_on_disk? do
    kamal_on_disk?() and backup_credentials_scoped_on_disk?() and
      file_contains?("config/deploy.yml", [
        "  backup:",
        "/app/etc/backup.cron",
        "LITESTREAM_BUCKET_NAME",
        "LITESTREAM_SECRET_ACCESS_KEY"
      ]) and
      file_contains?(".kamal/secrets", [
        "LITESTREAM_ENDPOINT",
        "LITESTREAM_ACCESS_KEY_ID",
        "LITESTREAM_SECRET_ACCESS_KEY"
      ]) and
      file_contains?("Dockerfile", ["/usr/local/bin/litestream", "/usr/local/bin/supercronic"])
  end

  defp backup_credentials_scoped_on_disk? do
    case File.read("config/deploy.yml") do
      {:ok, contents} -> TamayotchiStack.Features.Backups.credentials_scoped?(contents)
      _ -> false
    end
  end

  defp file_contains?(path, expected) do
    case File.read(path) do
      {:ok, text} -> Enum.all?(expected, &String.contains?(text, &1))
      {:error, _} -> false
    end
  end

  @spec r2_on_disk?() :: boolean()
  def r2_on_disk? do
    Enum.all?([:ex_aws, :ex_aws_s3, :req, :jason, :sweet_xml], &dependency_on_disk?/1) and
      r2_runtime_on_disk?() and
      Enum.any?(Path.wildcard("lib/**/storage.ex"), fn storage ->
        directory = Path.rootname(storage)
        File.exists?("#{directory}/r2.ex") and File.exists?("#{directory}/fake.ex")
      end)
  end

  defp r2_runtime_on_disk? do
    with {:ok, contents} <- File.read("config/runtime.exs"),
         {:ok, ast} <- Code.string_to_quoted(contents) do
      nodes =
        case ast do
          {:__block__, _, nodes} -> nodes
          node -> [node]
        end

      Enum.any?(nodes, &match?({:=, _, [{:tamayotchi_r2_storage, _, _}, _]}, &1))
    else
      _ -> false
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

  defp dependency?(igniter, dependency), do: Igniter.Project.Deps.has_dep?(igniter, dependency)

  defp dependency_on_disk?(dependency) do
    Mix.Project.config()
    |> Keyword.get(:deps, [])
    |> Enum.any?(fn
      {^dependency, _requirement_or_options} -> true
      {^dependency, _requirement, _options} -> true
      _other -> false
    end)
  end

  # Igniter normalizes module files by the Mix project's namespace, which need
  # not equal the OTP app name (for example, sample_123 becomes Sample123).
  def release_path(base_module), do: "lib/#{Macro.underscore(base_module)}/release.ex"

  defp sqlite_kamal_files_on_disk? do
    if sqlite_on_disk?() do
      base_module = Mix.Project.get() |> Module.split() |> Enum.drop(-1) |> Module.concat()
      Enum.all?([release_path(base_module) | @kamal_sqlite_files], &File.exists?/1)
    else
      true
    end
  end

  defp source_content(igniter, path) do
    igniter
    |> Igniter.include_existing_file(path, required?: true)
    |> Map.fetch!(:rewrite)
    |> Rewrite.source!(path)
    |> Rewrite.Source.get(:content)
  end

  defp root_proxy?(contents), do: Regex.match?(~r/^proxy:\s*$/m, contents)

  defp app_js_imports_goatcounter?({:ok, contents}) do
    String.contains?(contents, ~s(import "./goatcounter")) or
      String.contains?(contents, ~s(import './goatcounter'))
  end

  defp app_js_imports_goatcounter?({:error, _reason}), do: false
end
