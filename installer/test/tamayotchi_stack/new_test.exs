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

  test "backups are implicit and have no independent generator flag" do
    refute Enum.any?(
             New.setup_arguments(true, false, true),
             &String.contains?(&1, "backups")
           )

    for flag <- ["--backups", "--no-backups"] do
      assert_raise OptionParser.ParseError, fn ->
        Mix.Tasks.Tamayotchi.New.run(["backup_invalid", flag, "--yes"])
      end
    end
  end

  test "secret setup defaults on and can be skipped for offline generation" do
    refute "--no-secrets" in New.setup_arguments(true, false, true)
    assert "--no-secrets" in New.setup_arguments(true, false, true, false)
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
