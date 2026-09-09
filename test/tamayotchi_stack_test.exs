defmodule TamayotchiStackTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  alias TamayotchiStack.Doctor
  alias TamayotchiStack.Features.GoatCounter
  alias TamayotchiStack.Features.Kamal
  alias TamayotchiStack.Manifest
  alias TamayotchiStack.Setup
  alias TamayotchiStack.SetupOptions
  alias TamayotchiStack.Sync

  doctest TamayotchiStack

  test "reports its version" do
    assert TamayotchiStack.version() == "0.1.0"
  end

  test "configures app-owned GoatCounter files in a Phoenix project" do
    igniter = phoenix_project() |> Setup.configure(phoenix: true)

    assert content(igniter, "assets/js/app.js") =~ ~s(import "./goatcounter";)

    wrapper = content(igniter, "assets/js/goatcounter.js")
    assert wrapper =~ "// Managed by tamayotchi_stack."
    assert wrapper =~ ~s(window.goatcounter.endpoint = "https://sample.goatcounter.com/count";)
    assert wrapper =~ ~s(window.addEventListener("phx:page-loading-stop")
    assert wrapper =~ "// Optional path normalization for pages with dynamic IDs."
    assert wrapper =~ ~S"//     /^\/products\/\d+\/(history|edit)(?:\?.*)?$/"

    vendor = content(igniter, "assets/vendor/goatcounter.js")
    assert vendor =~ "// Managed by tamayotchi_stack."
    assert vendor =~ "window.goatcounter.count"

    assert {:ok, manifest} = Manifest.parse(content(igniter, ".tamayotchi.exs"))
    assert manifest[:app] == :sample
    assert manifest[:features][:phoenix] == []
    refute Keyword.has_key?(manifest[:features], :goatcounter)
  end

  test "Phoenix always configures Kamal from application conventions" do
    igniter = phoenix_project() |> Setup.configure(phoenix: true)

    deploy = content(igniter, "config/deploy.yml")
    assert deploy =~ "service: sample"
    assert deploy =~ "image: tamayotchi/sample"
    assert deploy =~ "registry:\n  server: ghcr.io\n  username: tamayotchi"
    refute Igniter.exists?(igniter, ".github/workflows/deploy.yml")
    assert deploy =~ "- home-server"
    assert deploy =~ "host: sample.tamayotchi.com"
    assert deploy =~ "ssl: false"
    assert deploy =~ "DATABASE_PATH: /app/storage/sample.db"
    assert deploy =~ ~s("sample_storage:/app/storage")

    secrets = content(igniter, ".kamal/secrets")
    assert secrets =~ "--from SERVER/SAMPLE KAMAL_REGISTRY_PASSWORD SECRET_KEY_BASE"
    refute secrets =~ ~r/SECRET_KEY_BASE=\S{32}/

    assert content(igniter, "Dockerfile") =~ ~s(ENTRYPOINT ["/app/bin/docker-entrypoint"])
    assert content(igniter, "rel/overlays/bin/migrate") =~ "Sample.Release.migrate"
    assert content(igniter, "lib/sample/release.ex") =~ "defmodule Sample.Release"

    assert {:ok, manifest} = Manifest.parse(content(igniter, ".tamayotchi.exs"))
    assert manifest[:features][:phoenix] == []
    assert manifest[:features][:kamal] == [proxy: true]
  end

  test "Kamal release paths follow module names rather than numeric OTP app segments" do
    mix_exs = """
    defmodule Sample123.MixProject do
      use Mix.Project
      def project, do: [app: :sample_123, version: "0.1.0", deps: deps()]
      def application, do: [extra_applications: [:logger]]
      defp deps, do: [{:phoenix, "~> 1.8"}, {:ecto_sqlite3, "~> 0.22"}]
    end
    """

    configured =
      phoenix_project(%{"mix.exs" => mix_exs})
      |> Setup.configure(phoenix: true, kamal_proxy: false)

    assert Igniter.prepare_for_write(configured).issues == []
    assert content(configured, "lib/sample123/release.ex") =~ "defmodule Sample123.Release"
    refute Igniter.exists?(configured, "lib/sample_123/release.ex")
    assert TamayotchiStack.Project.release_path(Sample123) == "lib/sample123/release.ex"
    synced = configured |> materialized_project() |> Sync.run()
    assert Igniter.prepare_for_write(synced).issues == []
    refute Igniter.changed?(synced)
  end

  test "GHCR defaults do not silently switch existing registries" do
    configured = phoenix_project() |> Setup.configure(phoenix: true)

    deployment = content(configured, "config/deploy.yml")

    for existing <- [
          String.replace(deployment, "  server: ghcr.io\n", ""),
          String.replace(deployment, "ghcr.io", "registry.example.com")
        ] do
      updated =
        Igniter.update_file(
          configured,
          "config/deploy.yml",
          &Rewrite.Source.update(&1, :content, existing)
        )

      synced = updated |> materialized_project() |> Sync.run()
      assert Igniter.prepare_for_write(synced).issues == []
      assert content(synced, "config/deploy.yml") == existing
      refute Igniter.changed?(synced)
    end
  end

  test "R2 integrates with Kamal only when selected" do
    enabled =
      phoenix_project()
      |> Setup.configure(phoenix: true, r2: true)

    assert Igniter.prepare_for_write(enabled).issues == []
    assert content(enabled, "config/deploy.yml") =~ "R2_BUCKET: sample"
    assert content(enabled, "config/deploy.yml") =~ "- R2_SECRET_ACCESS_KEY"

    assert content(enabled, ".kamal/secrets") =~
             "$(kamal secrets extract R2_ACCESS_KEY_ID $SECRETS)"

    assert content(enabled, "Dockerfile") =~ "COPY config/runtime.exs config/"
    refute Igniter.changed?(enabled |> materialized_project() |> Sync.run())

    disabled = phoenix_project() |> Setup.configure(phoenix: true)
    refute content(disabled, "config/deploy.yml") =~ "R2_"
    refute content(disabled, ".kamal/secrets") =~ "R2_"
  end

  test "R2 preserves customized Kamal values and secret references" do
    initial =
      phoenix_project()
      |> Setup.configure(phoenix: true)
      |> Igniter.update_file("config/deploy.yml", fn source ->
        text = Rewrite.Source.get(source, :content)

        text =
          String.replace(
            text,
            "PORT: 4000",
            "PORT: 4000\n    R2_BUCKET: custom-bucket\n    CUSTOM_ENV: custom"
          )

        Rewrite.Source.update(source, :content, text)
      end)
      |> Igniter.update_file(".kamal/secrets", fn source ->
        text = Rewrite.Source.get(source, :content)
        Rewrite.Source.update(source, :content, text <> "# custom provider comment\n")
      end)
      |> materialized_project()

    enabled = Setup.configure(initial, phoenix: true, r2: true)
    assert Igniter.prepare_for_write(enabled).issues == []
    assert content(enabled, "config/deploy.yml") =~ "R2_BUCKET: custom-bucket"
    assert content(enabled, "config/deploy.yml") =~ "CUSTOM_ENV: custom"
    assert content(enabled, ".kamal/secrets") =~ "# custom provider comment"
    refute Igniter.changed?(enabled |> materialized_project() |> Sync.run())

    disabled =
      enabled
      |> materialized_project()
      |> Setup.configure(phoenix: true, r2: false)

    assert content(disabled, "config/deploy.yml") =~ "R2_ACCESS_KEY_ID"
    assert content(disabled, ".kamal/secrets") =~ "R2_ACCESS_KEY_ID"
  end

  test "can deploy without kamal-proxy or a database" do
    igniter =
      no_ecto_phoenix_project()
      |> Setup.configure(phoenix: true, kamal_proxy: false)

    deploy = content(igniter, "config/deploy.yml")
    assert deploy =~ "proxy: false"
    assert deploy =~ ~s(publish: "4000:4000")
    assert deploy =~ "hosts:\n      - home-server"
    assert deploy =~ "PHX_HOST: sample.tamayotchi.com"
    refute deploy =~ "PHX_HOST: home-server"
    refute deploy =~ "\nproxy:\n"
    refute deploy =~ "DATABASE_PATH"
    refute deploy =~ "volumes:"

    refute Igniter.exists?(igniter, "rel/overlays/bin/migrate")
    refute Igniter.exists?(igniter, "rel/overlays/bin/docker-entrypoint")
    refute Igniter.exists?(igniter, "lib/sample/release.ex")
    refute content(igniter, "Dockerfile") =~ "ENTRYPOINT"

    assert {:ok, manifest} = Manifest.parse(content(igniter, ".tamayotchi.exs"))
    assert manifest[:features][:kamal] == [proxy: false]
  end

  test "Kamal configuration and sync are idempotent" do
    options = [phoenix: true, kamal_proxy: true]

    first_pass = phoenix_project() |> Setup.configure(options)
    materialized = materialized_project(first_pass)
    second_pass = Setup.configure(materialized, options)
    synced = Sync.run(materialized)

    refute Igniter.changed?(second_pass)
    refute Igniter.changed?(synced)
    assert Igniter.prepare_for_write(second_pass).issues == []
    assert Igniter.prepare_for_write(synced).issues == []
  end

  test "does not overwrite an unmanaged Dockerfile" do
    igniter =
      phoenix_project(%{
        "Dockerfile" =>
          "FROM custom/image\n# Managed by tamayotchi_stack. is only a comment here\n"
      })
      |> Kamal.configure(:sample, true, proxy: true)

    assert Enum.any?(
             Igniter.prepare_for_write(igniter).issues,
             &String.contains?(to_string(&1), "Refusing to overwrite unmanaged Dockerfile")
           )
  end

  test "configuration is idempotent" do
    options = [phoenix: true]
    first_pass = phoenix_project() |> Setup.configure(options)

    second_pass =
      first_pass
      |> materialized_project()
      |> Setup.configure(options)

    refute Igniter.changed?(second_pass)
    assert Igniter.prepare_for_write(second_pass).issues == []
  end

  test "sync normalizes a managed endpoint from the application name" do
    igniter =
      phoenix_project()
      |> Setup.configure(phoenix: true)
      |> Igniter.update_file("assets/js/goatcounter.js", fn source ->
        contents = Rewrite.Source.get(source, :content)
        updated = String.replace(contents, "https://sample.", "https://old.")
        Rewrite.Source.update(source, :content, updated)
      end)
      |> materialized_project()

    updated = Sync.run(igniter)

    assert content(updated, "assets/js/goatcounter.js") =~
             ~s(window.goatcounter.endpoint = "https://sample.goatcounter.com/count";)

    assert {:ok, manifest} = Manifest.parse(content(updated, ".tamayotchi.exs"))
    assert manifest[:features] == [backups: [], kamal: [proxy: true], phoenix: []]
  end

  test "does not overwrite an unmanaged GoatCounter wrapper" do
    igniter =
      phoenix_project(%{
        "assets/js/goatcounter.js" => "console.log('custom analytics')\n"
      })
      |> Setup.configure(phoenix: true)

    assert Enum.any?(
             Igniter.prepare_for_write(igniter).issues,
             &String.contains?(to_string(&1), "Refusing to overwrite")
           )
  end

  test "GoatCounter derives HTTPS endpoints directly from application names" do
    for app <- [:price_tracker, "price_tracker", "Price_Tracker"] do
      assert GoatCounter.endpoint_for_app(app) == "https://price-tracker.goatcounter.com/count"

      igniter = phoenix_project() |> GoatCounter.configure(app)
      assert Igniter.prepare_for_write(igniter).issues == []

      assert content(igniter, "assets/js/goatcounter.js") =~
               ~s(window.goatcounter.endpoint = "https://price-tracker.goatcounter.com/count";)
    end
  end

  test "GoatCounter still refuses projects without Phoenix assets" do
    igniter = test_project(app_name: :sample) |> GoatCounter.configure(:sample)

    assert Enum.any?(
             Igniter.prepare_for_write(igniter).issues,
             &String.contains?(to_string(&1), "GoatCounter requires a Phoenix project")
           )

    refute Igniter.exists?(igniter, "assets/js/goatcounter.js")
  end

  test "a non-Phoenix setup does not generate GoatCounter or Kamal files" do
    igniter = test_project(app_name: :sample) |> Setup.configure(phoenix: false)

    for path <- [
          "assets/js/goatcounter.js",
          "assets/vendor/goatcounter.js",
          "Dockerfile",
          "config/deploy.yml",
          ".kamal/secrets"
        ] do
      refute Igniter.exists?(igniter, path)
    end

    assert {:ok, manifest} = Manifest.read(igniter)
    refute Keyword.has_key?(manifest[:features], :kamal)
    refute Igniter.changed?(igniter |> materialized_project() |> Sync.run())
  end

  test "setup keeps GoatCounter and Kamal implicit with Phoenix" do
    resolved = phoenix_project() |> SetupOptions.resolve(phoenix: true, yes: true)

    assert resolved[:phoenix]
    refute Keyword.has_key?(resolved, :goatcounter)
    refute Keyword.has_key?(resolved, :goatcounter_endpoint)
    refute Keyword.has_key?(resolved, :kamal)
    refute Keyword.has_key?(TamayotchiStack.TaskInfo.setup().schema, :kamal)
    assert resolved[:kamal_proxy]

    plain = test_project(app_name: :sample) |> SetupOptions.resolve(phoenix: false, yes: true)
    refute Keyword.has_key?(plain, :kamal)
    refute Keyword.has_key?(plain, :kamal_proxy)

    for proxy? <- [true, false] do
      assert_raise Mix.Error, ~r/requires Phoenix/, fn ->
        SetupOptions.resolve(test_project(app_name: :sample),
          phoenix: false,
          proxy: proxy?,
          yes: true
        )
      end
    end
  end

  test "setup preserves the proxy choice from an existing Kamal configuration" do
    igniter =
      no_ecto_phoenix_project()
      |> Setup.configure(phoenix: true, kamal_proxy: false)
      |> materialized_project()

    resolved = SetupOptions.resolve(igniter, yes: true)

    assert resolved[:phoenix]
    refute Keyword.has_key?(resolved, :kamal)
    refute resolved[:kamal_proxy]
    refute Igniter.changed?(Setup.configure(igniter, phoenix: true))
  end

  test "sync adds Kamal to legacy Phoenix manifests without provisioning credentials" do
    legacy =
      no_ecto_phoenix_project()
      |> Manifest.set_feature(:sample, :phoenix, true)
      |> GoatCounter.configure(:sample)
      |> materialized_project()

    refute Igniter.exists?(legacy, "config/deploy.yml")
    synced = Sync.run(legacy)
    assert Igniter.prepare_for_write(synced).issues == []
    assert Igniter.exists?(synced, "config/deploy.yml")
    assert {:ok, manifest} = Manifest.read(synced)
    assert manifest[:features][:kamal] == [proxy: true]
    assert synced.tasks == []
    refute Igniter.changed?(synced |> materialized_project() |> Sync.run())

    conflict =
      legacy
      |> Igniter.create_new_file("Dockerfile", "FROM custom/image\n")
      |> Sync.run()

    assert Enum.any?(
             Igniter.prepare_for_write(conflict).issues,
             &String.contains?(to_string(&1), "Refusing to overwrite unmanaged Dockerfile")
           )

    assert conflict.tasks == []
  end

  test "legacy or partial deployments retain their proxy choice when adding derived Kamal state" do
    deployment =
      no_ecto_phoenix_project()
      |> Setup.configure(phoenix: true, kamal_proxy: false)
      |> content("config/deploy.yml")

    legacy =
      no_ecto_phoenix_project()
      |> Igniter.create_new_file("config/deploy.yml", deployment)
      |> Manifest.set_feature(:sample, :phoenix, true)
      |> materialized_project()

    refute SetupOptions.resolve(legacy, yes: true)[:kamal_proxy]
    synced = Sync.run(legacy)
    assert Igniter.prepare_for_write(synced).issues == []
    assert content(synced, "config/deploy.yml") == deployment
    assert {:ok, manifest} = Manifest.read(synced)
    assert manifest[:features][:kamal] == [proxy: false]
  end

  test "opting out of Phoenix preserves existing deployment files for manual review" do
    original =
      no_ecto_phoenix_project() |> Setup.configure(phoenix: true) |> materialized_project()

    updated = Setup.configure(original, phoenix: false)
    assert Igniter.prepare_for_write(updated).issues == []

    for path <- ["Dockerfile", "config/deploy.yml", ".kamal/secrets", "rel/overlays/bin/server"] do
      assert content(updated, path) == content(original, path)
    end

    assert {:ok, manifest} = Manifest.read(updated)
    refute Keyword.has_key?(manifest[:features], :phoenix)
    refute Keyword.has_key?(manifest[:features], :kamal)
    assert updated.tasks == []
    assert Enum.any?(updated.notices, &String.contains?(&1, "Existing Kamal files"))
  end

  test "doctor health follows desired state" do
    report = %{
      manifest: :ok,
      managed_phoenix: true,
      phoenix: true,
      goatcounter: true,
      goatcounter_endpoint: "https://sample.goatcounter.com/count",
      expected_goatcounter_endpoint: "https://sample.goatcounter.com/count",
      managed_kamal: true,
      kamal: true,
      kamal_proxy: true,
      expected_kamal_proxy: true
    }

    assert Doctor.healthy?(report)
    refute Doctor.healthy?(%{report | goatcounter: false, goatcounter_endpoint: nil})
    refute Doctor.healthy?(%{report | kamal: false})
    refute Doctor.healthy?(%{report | managed_kamal: false, kamal: false})
    refute Doctor.healthy?(%{report | kamal_proxy: false})
    refute Doctor.healthy?(Map.merge(report, %{managed_r2: true, r2: false}))
    assert Doctor.healthy?(Map.merge(report, %{managed_r2: true, r2: true}))
  end

  test "manifest parser rejects executable and invalid feature configuration" do
    assert {:error, _reason} = Manifest.parse("System.cmd(\"echo\", [\"unsafe\"])\n")

    assert {:error, reason} =
             Manifest.parse("[schema: 1, app: :sample, features: [kamal: true]]\n")

    assert reason =~ "Kamal configuration"

    assert {:error, reason} =
             Manifest.parse("[schema: 1, app: :sample, features: [phoenix: false]]\n")

    assert reason =~ "Phoenix configuration"
  end

  defp phoenix_project(extra_files \\ %{}) do
    files =
      Map.merge(
        %{
          "mix.exs" => """
          defmodule Sample.MixProject do
            use Mix.Project

            def project do
              [app: :sample, version: "0.1.0", deps: deps()]
            end

            def application, do: [extra_applications: [:logger]]

            defp deps do
              [
                {:phoenix, "~> 1.8"},
                {:ecto_sqlite3, "~> 0.22"}
              ]
            end
          end
          """,
          "config/config.exs" => "import Config\n",
          "assets/js/app.js" => """
          // Phoenix entrypoint
          import "phoenix_html";
          """
        },
        extra_files
      )

    test_project(app_name: :sample, files: files)
  end

  defp no_ecto_phoenix_project do
    phoenix_project(%{
      "mix.exs" => """
      defmodule Sample.MixProject do
        use Mix.Project

        def project do
          [app: :sample, version: "0.1.0", deps: deps()]
        end

        def application, do: [extra_applications: [:logger]]

        defp deps do
          [
            {:phoenix, "~> 1.8"}
          ]
        end
      end
      """
    })
  end

  defp materialized_project(igniter) do
    files =
      igniter.rewrite.sources
      |> Map.values()
      |> Map.new(fn source -> {source.path, Rewrite.Source.get(source, :content)} end)

    test_project(app_name: :sample, files: files)
  end

  defp content(igniter, path) do
    igniter = Igniter.include_existing_file(igniter, path, required?: true)

    igniter.rewrite
    |> Rewrite.source!(path)
    |> Rewrite.Source.get(:content)
  end
end
