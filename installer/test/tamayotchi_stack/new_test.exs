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

  test "forwards explicit R2 choices independently of Phoenix and Kamal" do
    assert New.setup_arguments(true, true, true, false) == [
             "tamayotchi_stack.install",
             "--yes",
             "--phoenix",
             "--r2",
             "--no-backups",
             "--kamal",
             "--no-proxy"
           ]

    assert New.setup_arguments(false, true, false, false) == [
             "tamayotchi_stack.install",
             "--yes",
             "--no-phoenix",
             "--r2",
             "--no-backups",
             "--no-kamal"
           ]

    arguments = New.setup_arguments(true, false, false, false)
    assert "--no-r2" in arguments
    refute "--r2" in arguments
    refute "--proxy" in arguments
  end

  test "forwards optional backup choices and rejects incompatible generation before writing" do
    assert "--backups" in New.setup_arguments(true, false, true, true, true)
    assert "--no-backups" in New.setup_arguments(true, false, true, true)

    for arguments <- [["--no-sqlite"], ["--no-kamal"], ["--no-phoenix"]] do
      assert_raise Mix.Error, ~r/--backups requires SQLite and Kamal/, fn ->
        Mix.Tasks.Tamayotchi.New.run(["backup_invalid", "--backups", "--yes"] ++ arguments)
      end
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
