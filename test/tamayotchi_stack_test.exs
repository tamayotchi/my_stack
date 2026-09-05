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

  test "configures Kamal from application conventions" do
    igniter =
      phoenix_project()
      |> Setup.configure(phoenix: true, kamal: true, kamal_proxy: true)

    deploy = content(igniter, "config/deploy.yml")
    assert deploy =~ "service: sample"
    assert deploy =~ "image: tamayotchi/sample"
    assert deploy =~ "- 192.168.1.39"
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

  test "R2 integrates with Kamal only when selected" do
    enabled =
      phoenix_project()
      |> Setup.configure(phoenix: true, r2: true, kamal: true, kamal_proxy: true)

    assert Igniter.prepare_for_write(enabled).issues == []
    assert content(enabled, "config/deploy.yml") =~ "R2_BUCKET: sample"
    assert content(enabled, "config/deploy.yml") =~ "- R2_SECRET_ACCESS_KEY"

    assert content(enabled, ".kamal/secrets") =~
             "$(kamal secrets extract R2_ACCESS_KEY_ID $SECRETS)"

    assert content(enabled, "Dockerfile") =~ "COPY config/runtime.exs config/"
    refute Igniter.changed?(enabled |> materialized_project() |> Sync.run())

    disabled = phoenix_project() |> Setup.configure(phoenix: true, kamal: true, kamal_proxy: true)
    refute content(disabled, "config/deploy.yml") =~ "R2_"
    refute content(disabled, ".kamal/secrets") =~ "R2_"
  end

  test "R2 preserves customized Kamal values and secret references" do
    initial =
      phoenix_project()
      |> Setup.configure(phoenix: true, kamal: true, kamal_proxy: true)
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

    enabled = Setup.configure(initial, phoenix: true, r2: true, kamal: true, kamal_proxy: true)
    assert Igniter.prepare_for_write(enabled).issues == []
    assert content(enabled, "config/deploy.yml") =~ "R2_BUCKET: custom-bucket"
    assert content(enabled, "config/deploy.yml") =~ "CUSTOM_ENV: custom"
    assert content(enabled, ".kamal/secrets") =~ "# custom provider comment"
    refute Igniter.changed?(enabled |> materialized_project() |> Sync.run())

    disabled =
      enabled
      |> materialized_project()
      |> Setup.configure(phoenix: true, r2: false, kamal: true, kamal_proxy: true)

    assert content(disabled, "config/deploy.yml") =~ "R2_ACCESS_KEY_ID"
    assert content(disabled, ".kamal/secrets") =~ "R2_ACCESS_KEY_ID"
  end

  test "can deploy without kamal-proxy or a database" do
    igniter =
      no_ecto_phoenix_project()
      |> Setup.configure(phoenix: true, kamal: true, kamal_proxy: false)

    deploy = content(igniter, "config/deploy.yml")
    assert deploy =~ "proxy: false"
    assert deploy =~ ~s(publish: "4000:4000")
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
    options = [phoenix: true, kamal: true, kamal_proxy: true]

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
    assert manifest[:features] == [phoenix: []]
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

  test "rejects invalid GoatCounter endpoints" do
    assert {:error, _reason} = GoatCounter.validate_endpoint("http://example.com/count")
    assert {:error, _reason} = GoatCounter.validate_endpoint("https://example.com/not-count")
    assert {:error, _reason} = GoatCounter.validate_endpoint("https://invalid_host/count")
    assert :ok = GoatCounter.validate_endpoint("https://example.com/count")
  end

  test "a non-Phoenix setup does not generate GoatCounter files" do
    igniter = test_project(app_name: :sample) |> Setup.configure(phoenix: false)

    refute Igniter.exists?(igniter, "assets/js/goatcounter.js")
    refute Igniter.exists?(igniter, "assets/vendor/goatcounter.js")
  end

  test "setup keeps GoatCounter implicit and defaults to Kamal" do
    resolved = phoenix_project() |> SetupOptions.resolve(phoenix: true, yes: true)

    assert resolved[:phoenix]
    refute Keyword.has_key?(resolved, :goatcounter)
    refute Keyword.has_key?(resolved, :goatcounter_endpoint)
    assert resolved[:kamal]
    assert resolved[:kamal_proxy]
  end

  test "setup preserves the proxy choice from an existing Kamal configuration" do
    igniter =
      no_ecto_phoenix_project()
      |> Setup.configure(phoenix: true, kamal: true, kamal_proxy: false)
      |> materialized_project()

    resolved = SetupOptions.resolve(igniter, yes: true)

    assert resolved[:phoenix]
    assert resolved[:kamal]
    refute resolved[:kamal_proxy]
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
    igniter.rewrite
    |> Rewrite.source!(path)
    |> Rewrite.Source.get(:content)
  end
end
