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
    assert {:ok, updated} = New.inject_dependency(mix_exs, dependency)
    assert updated =~ dependency

    assert {:ok, unchanged} = New.inject_dependency(updated, dependency)
    assert unchanged == updated
    assert length(Regex.scan(~r/\{:tamayotchi_stack,/, unchanged)) == 1
  end
end
