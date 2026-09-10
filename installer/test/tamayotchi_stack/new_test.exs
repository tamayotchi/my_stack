defmodule TamayotchiStack.NewTest do
  use ExUnit.Case, async: true

  alias TamayotchiStack.New

  doctest New

  test "validates application names" do
    assert :ok = New.validate_app_name("price_tracker")
    assert {:error, _reason} = New.validate_app_name("PriceTracker")
    assert {:error, _reason} = New.validate_app_name("price-tracker")
  end

  test "derives the GoatCounter endpoint from the app name" do
    assert New.goatcounter_endpoint_for_app("price_tracker") ==
             "https://price-tracker.goatcounter.com/count"
  end

  test "forwards R2 independently and only asks Phoenix applications about the proxy" do
    assert New.setup_arguments(true, true, false) == [
             "tamayotchi_stack.install",
             "--yes",
             "--phoenix",
             "--r2",
             "--no-proxy"
           ]

    assert New.setup_arguments(false, true, false) == [
             "tamayotchi_stack.install",
             "--yes",
             "--no-phoenix",
             "--r2"
           ]

    arguments = New.setup_arguments(true, false, true)
    assert "--no-r2" in arguments
    refute "--r2" in arguments
    assert "--proxy" in arguments
  end

  test "Kamal is implicit with Phoenix and has no separate flag" do
    for phoenix? <- [true, false] do
      refute Enum.any?(New.setup_arguments(phoenix?, false, true), &String.contains?(&1, "kamal"))
    end

    for flag <- ["--kamal", "--no-kamal"] do
      assert_raise OptionParser.ParseError, fn ->
        Mix.Tasks.Tamayotchi.New.run(["kamal_invalid", flag, "--yes"])
      end
    end
  end

  test "proxy flags require Phoenix before any project is created" do
    for flag <- ["--proxy", "--no-proxy"] do
      assert_raise Mix.Error, ~r/requires Phoenix/, fn ->
        Mix.Tasks.Tamayotchi.New.run(["proxy_invalid", "--no-phoenix", flag, "--yes"])
      end
    end
  end

  test "SQLite and backups are implicit and have no independent generator flags" do
    refute Enum.any?(
             New.setup_arguments(true, false, true),
             &String.contains?(&1, "backups")
           )

    for flag <- ["--sqlite", "--no-sqlite", "--backups", "--no-backups"] do
      assert_raise OptionParser.ParseError, fn ->
        Mix.Tasks.Tamayotchi.New.run(["backup_invalid", flag, "--yes"])
      end
    end
  end

  test "dry-run flags are rejected before creating a project" do
    for flag <- ["--dry-run", "--no-dry-run", "--dry-run=true", "--dry-run=false"] do
      assert_raise OptionParser.ParseError, fn ->
        Mix.Tasks.Tamayotchi.New.run(["dry_run_invalid", flag, "--yes"])
      end
    end
  end

  test "secret setup defaults on and can be skipped for offline generation" do
    refute "--no-secrets" in New.setup_arguments(true, false, true)
    assert "--no-secrets" in New.setup_arguments(true, false, true, false)
  end

  test "forwards a public host and rejects invalid or non-Phoenix hosts before generation" do
    arguments = New.setup_arguments(true, false, true, false, "track.tamayotchi.com")
    assert ["--host", "track.tamayotchi.com"] in Enum.chunk_every(arguments, 2, 1, :discard)
    assert :ok = New.validate_host("track.tamayotchi.com")

    for host <- [
          "https://track.tamayotchi.com",
          "track.example.com:443",
          "track",
          "*.example.com",
          "127.0.0.1",
          "UPPER.example.com",
          String.duplicate("x", 64) <> ".com"
        ] do
      assert_raise Mix.Error, ~r/--host must/, fn ->
        Mix.Tasks.Tamayotchi.New.run(["invalid_host", "--host", host, "--yes"])
      end
    end

    assert_raise Mix.Error, ~r/--host requires Phoenix/, fn ->
      Mix.Tasks.Tamayotchi.New.run([
        "invalid_host",
        "--no-phoenix",
        "--host",
        "track.tamayotchi.com",
        "--yes"
      ])
    end
  end

  test "injects the stack dependency once" do
    mix_exs = """
    defmodule Demo.MixProject do
      use Mix.Project

      def project, do: [app: :demo, deps: deps()]

      defp deps do
        [
          {:jason, "~> 1.4"}
        ]
      end
    end
    """

    dependency = New.dependency()
    assert dependency =~ ~s(github: "tamayotchi/my_stack")
    assert {:ok, updated} = New.inject_dependency(mix_exs, dependency)
    assert updated =~ dependency

    assert {:ok, unchanged} = New.inject_dependency(updated, dependency)
    assert unchanged == updated
    assert length(Regex.scan(~r/\{:tamayotchi_stack,/, unchanged)) == 1
  end
end
