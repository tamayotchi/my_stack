defmodule TamayotchiStack.BackupsTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  alias TamayotchiStack.Doctor
  alias TamayotchiStack.Features.Backups
  alias TamayotchiStack.Features.Kamal
  alias TamayotchiStack.Manifest
  alias TamayotchiStack.Setup
  alias TamayotchiStack.SetupOptions
  alias TamayotchiStack.Sync

  test "SQLite always includes backups without a separate option" do
    refute Keyword.has_key?(SetupOptions.resolve(project(), yes: true), :backups)
    refute Keyword.has_key?(TamayotchiStack.TaskInfo.setup().schema, :backups)
    assert Igniter.exists?(configured(), "rel/overlays/etc/backup.cron")

    plain = test_project(app_name: :sample) |> Setup.configure(phoenix: false)
    assert Igniter.prepare_for_write(plain).issues == []
    refute Igniter.exists?(plain, "rel/overlays/etc/backup.cron")
  end

  test "opting out of Phoenix stops backup management but preserves existing files" do
    original = configured() |> materialize()
    updated = Setup.configure(original, phoenix: false)
    assert Igniter.prepare_for_write(updated).issues == []

    for path <- Backups.paths() do
      assert Igniter.exists?(updated, path)
      assert content(updated, path) == content(original, path)
    end

    assert {:ok, manifest} = Manifest.read(updated)
    refute Keyword.has_key?(manifest[:features], :backups)
    assert Enum.any?(updated.notices, &String.contains?(&1, "Existing backup files"))
    refute Igniter.changed?(updated |> materialize() |> Sync.run())
  end

  test "generates a daily non-proxied backup role with independent credentials" do
    igniter = configured()
    assert Igniter.prepare_for_write(igniter).issues == []
    assert {:ok, manifest} = Manifest.read(igniter)
    assert manifest[:features][:backups] == []
    refute Keyword.has_key?(manifest[:features], :r2)
    refute Igniter.Project.Deps.has_dep?(igniter, :ex_aws)

    deploy = content(igniter, "config/deploy.yml")
    assert Backups.credentials_scoped?(deploy)

    refute Backups.credentials_scoped?(
             String.replace(
               deploy,
               "  secret:\n",
               "  secret:\n    - LITESTREAM_SECRET_ACCESS_KEY\n"
             )
           )

    assert deploy =~ "  web:\n    - home-server"
    assert deploy =~ "  backup:\n    hosts:\n      - home-server\n    proxy: false"
    refute deploy =~ "192.168.1.39"
    assert deploy =~ "LITESTREAM_BUCKET_NAME: sample-db-backups"
    assert deploy =~ "LITESTREAM_BUCKET_PATH: sample-production-v0.5"
    assert deploy =~ "LITESTREAM_REGION: auto"
    assert deploy =~ "TZ: UTC"
    assert deploy =~ "backup-restore:"
    assert deploy =~ "      secret:\n        - LITESTREAM_ENDPOINT"
    [_, global_env] = Regex.run(~r/^env:\n(.*?)(?=^\S|\z)/ms, deploy)
    refute global_env =~ "LITESTREAM_ACCESS_KEY_ID"
    refute global_env =~ "LITESTREAM_SECRET_ACCESS_KEY"

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
      refute Keyword.has_key?(SetupOptions.resolve(initial, yes: true), :backups)
      synced = Sync.run(initial)
      assert Igniter.prepare_for_write(synced).issues == []
      refute Igniter.changed?(synced)
    end
  end

  test "sync preserves legacy IPs, custom hosts, and public URLs instead of changing destinations" do
    for host <- ["192.168.1.39", "custom-server"],
        proxy? <- [true, false],
        r2? <- [true, false] do
      initial =
        configured(kamal_proxy: proxy?, r2: r2?)
        |> change("config/deploy.yml", fn text ->
          text
          |> String.replace("home-server", host)
          |> String.replace("PHX_HOST: sample.tamayotchi.com", "PHX_HOST: existing.example.com")
        end)
        |> materialize()

      synced = Sync.run(initial)
      assert issues(synced) == ""
      assert content(synced, "config/deploy.yml") == content(initial, "config/deploy.yml")
      refute Igniter.changed?(synced)
    end
  end

  test "adopts an existing managed deployment and preserves app-owned changes" do
    initial = project() |> Kamal.configure(:sample, true, proxy: true)

    initial =
      initial
      |> change("config/deploy.yml", &String.replace(&1, "home-server", "192.168.1.50"))
      |> materialize()

    enabled =
      initial |> Setup.configure(phoenix: true, kamal_proxy: true)

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

  test "legacy global backup credentials are migrated to the backup role without losing other settings" do
    initial = configured(r2: true)

    role_secret =
      "      secret:\n        - LITESTREAM_ENDPOINT\n        - LITESTREAM_ACCESS_KEY_ID\n        - LITESTREAM_SECRET_ACCESS_KEY\n"

    legacy_secret =
      "    # tamayotchi_stack backups:secret begin\n    - LITESTREAM_ENDPOINT\n    - LITESTREAM_ACCESS_KEY_ID\n    - LITESTREAM_SECRET_ACCESS_KEY\n    # tamayotchi_stack backups:secret end\n"

    old =
      initial
      |> change("config/deploy.yml", fn text ->
        text
        |> String.replace(role_secret, "")
        |> String.replace("  secret:\n", "  secret:\n" <> legacy_secret)
        |> String.replace("sample-db-backups", "my-private-backups")
      end)
      |> materialize()

    migrated = Sync.run(old)
    assert issues(migrated) == ""
    text = content(migrated, "config/deploy.yml")
    assert text =~ role_secret
    refute text =~ legacy_secret
    assert text =~ "my-private-backups"
    assert text =~ "R2_ACCESS_KEY_ID"
    refute Igniter.changed?(migrated |> materialize() |> Sync.run())

    unsafe =
      old
      |> change(
        "config/deploy.yml",
        &String.replace(
          &1,
          legacy_secret,
          String.replace(
            legacy_secret,
            "    - LITESTREAM_ENDPOINT",
            "    - CUSTOM_SECRET\n    - LITESTREAM_ENDPOINT"
          )
        )
      )

    assert issues(Sync.run(unsafe)) =~ "custom changes"
  end

  test "R2 can be added after backups without erasing the backup integration" do
    enabled =
      configured()
      |> materialize()
      |> Setup.configure(phoenix: true, r2: true, kamal_proxy: true)

    assert Igniter.prepare_for_write(enabled).issues == []
    assert content(enabled, "config/deploy.yml") =~ "R2_ACCESS_KEY_ID"
    assert content(enabled, "config/deploy.yml") =~ "LITESTREAM_ACCESS_KEY_ID"
    refute Igniter.changed?(enabled |> materialize() |> Sync.run())
  end

  test "does not overwrite manual backup files or unsafe deployment layouts" do
    manual =
      project()
      |> Igniter.create_new_file("rel/overlays/etc/litestream.yml", "# my manual replica\n")
      |> Setup.configure(phoenix: true, kamal_proxy: true)

    assert issues(manual) =~ "Refusing to overwrite unmanaged rel/overlays/etc/litestream.yml"

    initial = project() |> Kamal.configure(:sample, true, proxy: true)

    for {path, update} <- [
          {"config/deploy.yml",
           &String.replace(&1, "    - home-server", "    - home-server\n    - second-server")},
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
      conflict = initial |> change(path, update) |> Backups.configure(:sample, true)
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

    assert issues(Backups.configure(initial, :sample, true)) =~ "incomplete or duplicate"
  end

  test "an older manifest without backups cannot disable the SQLite invariant" do
    old = configured() |> Manifest.set_feature(:sample, :backups, false) |> materialize()
    updated = Sync.run(old)
    assert Igniter.prepare_for_write(updated).issues == []
    assert {:ok, manifest} = Manifest.read(updated)
    assert manifest[:features][:backups] == []
    assert Igniter.exists?(updated, "rel/overlays/etc/backup.cron")
    assert content(updated, "config/deploy.yml") =~ "  backup:"
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
      Keyword.merge([phoenix: true, kamal_proxy: true], options)
    )
  end

  defp project do
    test_project(
      app_name: :sample,
      files: %{
        "mix.exs" => """
        defmodule Sample.MixProject do
          use Mix.Project
          def project, do: [app: :sample, version: "0.1.0", deps: deps()]
          def application, do: [extra_applications: [:logger]]
          defp deps, do: [{:phoenix, "~> 1.8"}, {:ecto_sqlite3, "~> 0.22"}]
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

  defp content(igniter, path) do
    igniter = Igniter.include_existing_file(igniter, path, required?: true)
    igniter.rewrite |> Rewrite.source!(path) |> Rewrite.Source.get(:content)
  end

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
