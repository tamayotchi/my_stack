defmodule TamayotchiStack.PublicHostTest do
  use ExUnit.Case, async: true
  alias TamayotchiStack.PublicHost

  @deployment """
  # Managed by tamayotchi_stack.
  service: my-app
  servers:
    web:
      - home-server
    backup:
      proxy: false
  proxy:
    ssl: true # preserve TLS choice
    host: 'old.example.com' # public route
    app_port: 4000
  env: # global
    clear:
      PHX_HOST: "old.example.com" # canonical URL
      DATABASE_PATH: /app/storage/my_app.db
      R2_BUCKET: my-app
    secret:
      - SECRET_KEY_BASE
  volumes:
    - "my-app_storage:/app/storage"
  """

  test "only public-host scalars change, preserving quoting and comments" do
    expected = String.replace(@deployment, "old.example.com", "track.tamayotchi.com")
    assert {:ok, ^expected} = PublicHost.patch(@deployment, "track.tamayotchi.com")
    assert {:ok, ^expected} = PublicHost.patch(expected, "track.tamayotchi.com")
  end

  test "anchored edits cannot hit nested host keys or similarly named sections first" do
    proxy = "proxy:\n  host: old.example.com\n"
    source = "other_" <> proxy <> proxy <> "env:\n  clear:\n    PHX_HOST: old.example.com\n"
    assert {:ok, updated} = PublicHost.patch(source, "track.tamayotchi.com")

    assert updated ==
             "other_" <>
               proxy <>
               "proxy:\n  host: track.tamayotchi.com\nenv:\n  clear:\n    PHX_HOST: track.tamayotchi.com\n"

    nested =
      String.replace(
        @deployment,
        "  host:",
        "  healthcheck:\n    host: 'old.example.com' # public route\n  host:"
      )

    assert {:ok, updated} = PublicHost.patch(nested, "track.tamayotchi.com")
    assert updated =~ "    host: 'old.example.com' # public route"
    assert updated =~ "\n  host: 'track.tamayotchi.com' # public route"
    assert updated =~ "PHX_HOST: \"track.tamayotchi.com\""
  end

  test "literal quoted values and comments are preserved rather than parsed as YAML syntax" do
    extra = ~S|    CUSTOM_JSON: '{"list": [1, 2], "text": "# &anchor *alias !tag"}'| <> "\n"

    deployment =
      @deployment
      |> String.replace("    R2_BUCKET:", extra <> "    R2_BUCKET:")
      |> String.replace("proxy: false", "\"proxy\" : false # PHX_HOST must not be passed here")

    expected = String.replace(deployment, "old.example.com", "track.tamayotchi.com")
    assert {:ok, ^expected} = PublicHost.patch(deployment, "track.tamayotchi.com")
  end

  test "validates literal DNS hosts without evaluating input or accepting URLs" do
    for host <- ["track.tamayotchi.com", "another-name.example.com", "xn--test.example"] do
      assert :ok = PublicHost.validate(host)
    end

    for host <- [
          nil,
          "",
          "localhost",
          "127.0.0.1",
          "UPPER.example.com",
          "https://track.example.com",
          "track.example.com:443",
          "*.example.com",
          "x.example.com/path",
          "x.example.com\n",
          "-x.example.com",
          "x_.example.com",
          "x..example.com",
          String.duplicate("x", 64) <> ".com",
          String.duplicate("a.", 130) <> "com"
        ] do
      assert {:error, _} = PublicHost.validate(host)
    end
  end

  test "inline, inherited, and escaped host overrides cannot bypass the layout checks" do
    for override <- [
          "    env:\n      clear: {PHX_HOST: hidden.example.com}\n",
          "    env:\n      secret: [PHX_HOST]\n",
          "    env:\n      secret:\n        - \"PHX_\\u0048OST\"\n",
          "    options:\n      env: PHX_HOST=hidden.example.com\n",
          "    options:\n      env:\n        - PHX_HOST=hidden.example.com\n",
          "    env:\n      clear:\n        \"PHX_\\u0048OST\": hidden.example.com\n",
          "    proxy :\n      host: hidden.example.com\n",
          "    <<:\n      proxy:\n        host: hidden.example.com\n",
          "    <<: *shared_role\n"
        ] do
      deployment =
        String.replace(
          @deployment,
          "  web:\n    - home-server\n",
          "  web:\n    hosts:\n      - home-server\n" <> override
        )

      assert {:error, _} = PublicHost.patch(deployment, "track.tamayotchi.com")
    end
  end

  test "ambiguous, dynamic, secret-overridden, and multi-host deployments fail closed" do
    for deployment <- [
          @deployment <> "env: {}\n",
          @deployment <> "'env': {}\n",
          @deployment <> "proxy: {}\n",
          @deployment <> "...\n",
          String.replace(@deployment, "  clear:", "  clear: &shared"),
          String.replace(@deployment, "  clear:", "  clear:\n    <<: *shared"),
          String.replace(@deployment, "  clear:", "  clear: {}\n  'clear':"),
          String.replace(
            @deployment,
            "    PHX_HOST:",
            "    'PHX_HOST': other.example.com\n    PHX_HOST:"
          ),
          String.replace(@deployment, "    PHX_HOST:", "    PHX_HOST: *shared\n    OLD_HOST:"),
          String.replace(@deployment, "  host:", "  hosts: [other.example.com]\n  host:"),
          String.replace(
            @deployment,
            "    proxy: false",
            "    proxy:\n      host: other.example.com"
          ),
          String.replace(@deployment, "    - SECRET_KEY_BASE", "    - PHX_HOST"),
          String.replace(@deployment, "    - SECRET_KEY_BASE", "    - 'PHX_HOST:HOST_SECRET'"),
          String.replace(@deployment, "old.example.com", "<%= ENV['HOST'] %>"),
          String.replace(@deployment, "  host:", "  'host': other.example.com\n  host:")
        ] do
      assert {:error, _} = PublicHost.patch(deployment, "track.tamayotchi.com")
    end
  end
end
