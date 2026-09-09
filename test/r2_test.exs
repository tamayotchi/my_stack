defmodule TamayotchiStack.R2Test do
  use ExUnit.Case, async: true

  import Igniter.Test

  alias TamayotchiStack.Features.R2
  alias TamayotchiStack.Manifest
  alias TamayotchiStack.SetupOptions
  alias TamayotchiStack.Sync

  test "R2 is optional and works without Phoenix" do
    project = test_project(app_name: :sample)
    refute SetupOptions.resolve(project, yes: true)[:r2]
    assert SetupOptions.resolve(project, yes: true, r2: true)[:r2]

    disabled = R2.configure(project, :sample, false)
    refute Igniter.exists?(disabled, "lib/sample/storage.ex")
    refute Igniter.Project.Deps.has_dep?(disabled, :ex_aws)

    enabled = R2.configure(project, :sample, true)
    assert Igniter.prepare_for_write(enabled).issues == []
    assert content(enabled, "lib/sample/storage.ex") =~ "@callback put_object"
    assert content(enabled, "lib/sample/storage/r2.ex") =~ "ExAws.Request.Req"
    assert content(enabled, "lib/sample/storage/fake.ex") =~ "Process.get"

    for path <- [
          "lib/sample/storage.ex",
          "lib/sample/storage/r2.ex",
          "lib/sample/storage/fake.ex"
        ] do
      refute content(enabled, path) =~ "get_object"
      refute content(enabled, path) =~ "list_objects"
    end

    assert content(enabled, "config/runtime.exs") =~ "tamayotchi_r2_storage ="
    assert {:ok, manifest} = Manifest.read(enabled)
    assert manifest[:features][:r2] == []

    for dependency <- [:ex_aws, :ex_aws_s3, :req, :jason, :sweet_xml] do
      assert Igniter.Project.Deps.has_dep?(enabled, dependency)
    end
  end

  test "setup and sync are idempotent and remember the opt-in" do
    first = test_project(app_name: :sample) |> R2.configure(:sample, true) |> materialize()
    assert SetupOptions.resolve(first, yes: true)[:r2]
    second = R2.configure(first, :sample, true)
    refute Igniter.changed?(second)
    synced = Sync.run(first)
    assert Igniter.prepare_for_write(synced).issues == []
    refute Igniter.changed?(synced)
  end

  test "preserves app-owned customizations and existing runtime configuration" do
    initial =
      test_project(
        app_name: :sample,
        files: %{
          "config/runtime.exs" => "import Config\nconfig :sample, custom: true\n"
        }
      )
      |> R2.configure(:sample, true)
      |> Igniter.update_file("lib/sample/storage.ex", fn source ->
        Rewrite.Source.update(
          source,
          :content,
          Rewrite.Source.get(source, :content) <> "\n# My S3 extension\n"
        )
      end)
      |> materialize()

    synced = Sync.run(initial)
    refute Igniter.changed?(synced)
    assert content(synced, "lib/sample/storage.ex") =~ "# My S3 extension"
    assert content(synced, "config/runtime.exs") =~ "custom: true"
  end

  test "refuses unmanaged storage and configuration files" do
    for path <- ["lib/sample/storage.ex", "lib/sample/storage/r2.ex"] do
      igniter =
        test_project(app_name: :sample, files: %{path => "# custom\n"})
        |> R2.configure(:sample, true)
        |> Igniter.prepare_for_write()

      assert Enum.any?(
               igniter.issues,
               &String.contains?(to_string(&1), "Refusing to overwrite unmanaged #{path}")
             )
    end
  end

  test "refuses conflicting runtime configuration" do
    igniter =
      test_project(
        app_name: :sample,
        files: %{
          "config/runtime.exs" =>
            "import Config\nconfig :sample, :storage, adapter: Custom.Storage\n"
        }
      )
      |> R2.configure(:sample, true)
      |> Igniter.prepare_for_write()

    assert Enum.any?(
             igniter.issues,
             &String.contains?(to_string(&1), "runtime configuration conflicts")
           )
  end

  test "does not replace existing dependency requirements or options" do
    igniter =
      test_project(app_name: :sample)
      |> Igniter.Project.Deps.add_dep({:req, "~> 0.6", override: true})
      |> R2.configure(:sample, true)

    assert content(igniter, "mix.exs") =~ ~s({:req, "~> 0.6", override: true})
  end

  test "disabling stops management without deleting app-owned implementation" do
    igniter =
      test_project(app_name: :sample)
      |> R2.configure(:sample, true)
      |> R2.configure(:sample, false)

    assert Igniter.exists?(igniter, "lib/sample/storage.ex")
    assert {:ok, manifest} = Manifest.read(igniter)
    refute Keyword.has_key?(manifest[:features], :r2)
  end

  test "manifest rejects R2 credentials and invalid configuration" do
    for config <- ["true", "[access_key_id: \"not-a-real-key\"]"] do
      assert {:error, reason} =
               Manifest.parse("[schema: 1, app: :sample, features: [r2: #{config}]]")

      assert reason =~ "R2 configuration must be []"
    end
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
end
