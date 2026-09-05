defmodule TamayotchiStack.R2RuntimeTest do
  use ExUnit.Case, async: false

  @env ~w(R2_ACCOUNT_ID R2_ENDPOINT R2_BUCKET R2_REGION R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_PUBLIC_BASE_URL)

  setup do
    previous = Map.new(@env, &{&1, System.get_env(&1)})
    Enum.each(@env, &System.delete_env/1)
    storage = Application.get_env(:r2_fixture, :storage)
    Application.delete_env(:r2_fixture, :storage)

    directory = Path.join(System.tmp_dir!(), "r2-config-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    path = Path.join(directory, "r2.exs")
    template = Path.join(:code.priv_dir(:tamayotchi_stack), "templates/r2/config.exs.eex")
    File.write!(path, EEx.eval_file(template, app: ":r2_fixture", base: "R2Fixture"))

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      if storage,
        do: Application.put_env(:r2_fixture, :storage, storage),
        else: Application.delete_env(:r2_fixture, :storage)

      File.rm_rf!(directory)
    end)

    %{path: path}
  end

  test "development uses the fake without credentials", %{path: path} do
    assert config(path, :dev)[:adapter] == R2Fixture.Storage.Fake
  end

  test "tests use the fake even with real-looking environment configuration", %{path: path} do
    credentials()
    assert config(path, :test)[:adapter] == R2Fixture.Storage.Fake
  end

  test "production validates missing and empty settings without leaking values", %{path: path} do
    assert_raise RuntimeError, ~r/requires R2_ACCOUNT_ID/, fn -> config(path, :prod) end
    credentials()
    System.put_env("R2_BUCKET", "")
    assert_raise RuntimeError, ~r/requires R2_BUCKET/, fn -> config(path, :prod) end
  end

  test "R2 uses defaults and private buckets do not need public URLs", %{path: path} do
    credentials()
    config = config(path, :prod)
    assert config[:adapter] == R2Fixture.Storage.R2
    assert config[:endpoint] == "https://test-account.r2.cloudflarestorage.com"
    assert config[:region] == "auto"
    assert config[:bucket] == "test-bucket"
    assert config[:public_base_url] == nil
  end

  test "custom endpoints do not require account IDs", %{path: path} do
    credentials()
    System.delete_env("R2_ACCOUNT_ID")
    System.put_env("R2_ENDPOINT", "https://objects.example.com:8443")
    assert config(path, :dev)[:endpoint] == "https://objects.example.com:8443"
  end

  test "invalid endpoints fail without printing their contents", %{path: path} do
    credentials()

    for endpoint <- [
          "http://example.com",
          "https://user:secret@example.com",
          "https://example.com/path",
          "https://example.com?secret=value"
        ] do
      System.put_env("R2_ENDPOINT", endpoint)

      assert_raise RuntimeError,
                   "R2_ENDPOINT must be an HTTPS origin without a path, credentials, query, or fragment",
                   fn -> config(path, :prod) end
    end
  end

  test "an alternate backend is not forced through R2 validation", %{path: path} do
    Application.put_env(:r2_fixture, :storage, adapter: R2Fixture.Storage.S3)
    assert config(path, :prod) == nil
  end

  defp credentials do
    System.put_env(%{
      "R2_ACCOUNT_ID" => "test-account",
      "R2_BUCKET" => "test-bucket",
      "R2_ACCESS_KEY_ID" => "test-access-key",
      "R2_SECRET_ACCESS_KEY" => "test-secret-key"
    })
  end

  defp config(path, env),
    do:
      Config.Reader.read!(path, env: env, target: :host, imports: :disabled)[:r2_fixture][
        :storage
      ]
end
