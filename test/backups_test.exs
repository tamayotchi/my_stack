defmodule TamayotchiStack.BackupsTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  alias TamayotchiStack.Doctor
  alias TamayotchiStack.Features.Backups
  alias TamayotchiStack.Manifest
  alias TamayotchiStack.Setup
  alias TamayotchiStack.SetupOptions
  alias TamayotchiStack.Sync

  test "backups default off and require SQLite plus Kamal" do
    refute SetupOptions.resolve(project(), yes: true)[:backups]
    disabled = Setup.configure(project(), phoenix: true, kamal: true, kamal_proxy: true)
    refute Igniter.exists?(disabled, "rel/overlays/etc/backup.cron")
    refute content(disabled, "config/deploy.yml") =~ "LITESTREAM"
    refute content(disabled, "Dockerfile") =~ "litestream"

    for {sqlite?, kamal?} <- [{false, true}, {true, false}, {false, false}] do
      invalid =
        project(sqlite?)
        |> Setup.configure(phoenix: true, kamal: kamal?, kamal_proxy: true, backups: true)

      assert Enum.any?(
               Igniter.prepare_for_write(invalid).issues,
               &String.contains?(to_string(&1), "--backups requires")
             )

      refute Igniter.exists?(invalid, "rel/overlays/etc/backup.cron")
    end
  end

  test "generates a daily non-proxied backup role with independent credentials" do
    igniter = configured()
    assert Igniter.prepare_for_write(igniter).issues == []
    assert {:ok, manifest} = Manifest.read(igniter)
    assert manifest[:features][:backups] == []
    refute Keyword.has_key?(manifest[:features], :r2)
    refute Igniter.Project.Deps.has_dep?(igniter, :ex_aws)

    deploy = content(igniter, "config/deploy.yml")
    assert deploy =~ "  backup:\n    hosts:\n      - 192.168.1.39\n    proxy: false"
    assert deploy =~ "LITESTREAM_BUCKET_NAME: sample-db-backups"
    assert deploy =~ "LITESTREAM_BUCKET_PATH: sample-production-v0.5"
    assert deploy =~ "LITESTREAM_REGION: auto"
    assert deploy =~ "TZ: UTC"
    assert deploy =~ "backup-restore:"

    assert content(igniter, "rel/overlays/etc/backup.cron") =~
             "0 15 * * * /app/bin/litestream-backup"

    assert content(igniter, "rel/overlays/etc/litestream.yml") =~ "retention: 168h"
    assert content(igniter, ".kamal/secrets") =~ "BACKUP_SECRETS=$(kamal secrets fetch"
    assert content(igniter, "Dockerfile") =~ "sha256sum -c -"
    refute content(igniter, "rel/overlays/bin/docker-entrypoint") =~ "restore"

    assert content(igniter, "rel/overlays/bin/litestream-backup") =~
             "-once -force-snapshot -enforce-retention"
  end

  test "setup and sync are idempotent with and without R2 and proxy" do
    for r2? <- [false, true], proxy? <- [false, true] do
      initial = configured(r2: r2?, kamal_proxy: proxy?) |> materialize()
      assert SetupOptions.resolve(initial, yes: true)[:backups]
      synced = Sync.run(initial)
      assert Igniter.prepare_for_write(synced).issues == []
      refute Igniter.changed?(synced)
    end
  end

  test "adopts an existing managed deployment and preserves app-owned changes" do
    initial = project() |> Setup.configure(phoenix: true, kamal: true, kamal_proxy: true)

    initial =
      initial
      |> change("config/deploy.yml", &String.replace(&1, "192.168.1.39", "192.168.1.50"))
      |> materialize()

    enabled =
      initial |> Setup.configure(phoenix: true, kamal: true, kamal_proxy: true, backups: true)

    assert Igniter.prepare_for_write(enabled).issues == []
    assert content(enabled, "config/deploy.yml") =~ "  backup:\n    hosts:\n      - 192.168.1.50"

    customized =
      enabled
      |> change("rel/overlays/etc/backup.cron", &String.replace(&1, "0 15", "0 3"))
      |> change("Dockerfile", &(&1 <> "\n# user Docker customization\n"))
      |> change(
        "config/deploy.yml",
        &String.replace(&1, "sample-db-backups", "custom-private-bucket")
      )
      |> materialize()

    synced = Sync.run(customized)
    assert Igniter.prepare_for_write(synced).issues == []
    refute Igniter.changed?(synced)
    assert content(synced, "rel/overlays/etc/backup.cron") =~ "0 3 * * *"
  end

  test "R2 can be added after backups without erasing the backup integration" do
    enabled =
      configured()
      |> materialize()
      |> Setup.configure(phoenix: true, r2: true, kamal: true, kamal_proxy: true, backups: true)

    assert Igniter.prepare_for_write(enabled).issues == []
    assert content(enabled, "config/deploy.yml") =~ "R2_ACCESS_KEY_ID"
    assert content(enabled, "config/deploy.yml") =~ "LITESTREAM_ACCESS_KEY_ID"
    refute Igniter.changed?(enabled |> materialize() |> Sync.run())
  end

  test "does not overwrite manual backup files or unsafe deployment layouts" do
    manual =
      project()
      |> Igniter.create_new_file("rel/overlays/etc/litestream.yml", "# my manual replica\n")
      |> Setup.configure(phoenix: true, kamal: true, kamal_proxy: true, backups: true)

    assert issues(manual) =~ "Refusing to overwrite unmanaged rel/overlays/etc/litestream.yml"

    initial = project() |> Setup.configure(phoenix: true, kamal: true, kamal_proxy: true)

    for {path, update} <- [
          {"config/deploy.yml",
           &String.replace(&1, "    - 192.168.1.39", "    - 192.168.1.39\n    - 192.168.1.40")},
          {"config/deploy.yml",
           &String.replace(&1, "  web:", "  backup:\n    - other.example.com\n  web:")},
          {"Dockerfile", &String.replace(&1, "USER nobody", "USER app")},
          {"Dockerfile", &(&1 <> "\n# Existing manual litestream install\n")},
          {"config/deploy.yml", &String.replace(&1, "arch: amd64", "arch: arm64")},
          {"config/deploy.yml",
           &String.replace(
             &1,
             "DATABASE_PATH: /app/storage/sample.db",
             "DATABASE_PATH: /other/sample.db"
           )}
        ] do
      conflict = initial |> change(path, update) |> Backups.configure(:sample, true, true)
      assert issues(conflict) =~ "Cannot safely add SQLite backups"
    end
  end

  test "partial backup markers are actionable conflicts" do
    initial =
      configured()
      |> change(
        "config/deploy.yml",
        &String.replace(&1, "# tamayotchi_stack backups:role end", "# missing end")
      )

    assert issues(Backups.configure(initial, :sample, true, true)) =~ "incomplete or duplicate"
  end

  test "opting out does not delete existing schedules or remote data" do
    disabled =
      configured()
      |> materialize()
      |> Setup.configure(phoenix: true, kamal: true, kamal_proxy: true, backups: false)

    assert {:ok, manifest} = Manifest.read(disabled)
    refute Keyword.has_key?(manifest[:features], :backups)
    assert Igniter.exists?(disabled, "rel/overlays/etc/backup.cron")
    assert content(disabled, "config/deploy.yml") =~ "  backup:"
    assert Enum.any?(disabled.notices, &String.contains?(&1, "not an existing backup schedule"))
  end

  test "manifest rejects backup secrets and doctor requires actual installation" do
    assert {:error, reason} =
             Manifest.parse(
               "[schema: 1, app: :sample, features: [backups: [secret: \"not-real\"]]]"
             )

    assert reason =~ "backups configuration must be []"
    report = %{manifest: :ok, managed_phoenix: false, managed_backups: true, backups: false}
    refute Doctor.healthy?(report)
    assert Doctor.healthy?(%{report | backups: true})
  end

  defp configured(options \\ []) do
    Setup.configure(
      project(),
      Keyword.merge([phoenix: true, kamal: true, kamal_proxy: true, backups: true], options)
    )
  end

  defp project(sqlite? \\ true) do
    test_project(
      app_name: :sample,
      files: %{
        "mix.exs" => """
        defmodule Sample.MixProject do
          use Mix.Project
          def project, do: [app: :sample, version: "0.1.0", deps: deps()]
          def application, do: [extra_applications: [:logger]]
          defp deps, do: [{:phoenix, "~> 1.8"}#{if sqlite?, do: ", {:ecto_sqlite3, \"~> 0.22\"}", else: ""}]
        end
        """,
        "config/config.exs" => "import Config\n",
        "assets/js/app.js" => "import \"phoenix_html\";\n"
      }
    )
  end

  defp materialize(igniter) do
    files =
      Map.new(igniter.rewrite.sources, fn {path, source} ->
        {path, Rewrite.Source.get(source, :content)}
      end)

    test_project(app_name: :sample, files: files)
  end

  defp content(igniter, path),
    do: igniter.rewrite |> Rewrite.source!(path) |> Rewrite.Source.get(:content)

  defp change(igniter, path, updater),
    do:
      Igniter.update_file(
        igniter,
        path,
        &Rewrite.Source.update(&1, :content, updater.(Rewrite.Source.get(&1, :content)))
      )

  defp issues(igniter),
    do:
      igniter
      |> Igniter.prepare_for_write()
      |> Map.fetch!(:issues)
      |> Enum.map_join("\n", &to_string/1)
end
