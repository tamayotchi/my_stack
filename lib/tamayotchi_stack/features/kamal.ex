defmodule TamayotchiStack.Features.Kamal do
  @moduledoc false

  alias TamayotchiStack.Manifest
  alias TamayotchiStack.Project

  @managed_marker "Managed by tamayotchi_stack."
  @server "192.168.1.39"
  @registry_owner "tamayotchi"
  @one_password_account "instaleap-llc.1password.com"
  @one_password_vault "SERVER"

  @spec configure(Igniter.t(), atom(), boolean(), keyword()) :: Igniter.t()
  def configure(igniter, app_name, enabled?, options \\ []) do
    if enabled? do
      configure_enabled(igniter, app_name, options)
    else
      Manifest.set_feature(igniter, app_name, :kamal, false)
    end
  end

  @spec configured?(Igniter.t()) :: boolean()
  def configured?(igniter) do
    Enum.all?(
      [
        "Dockerfile",
        ".dockerignore",
        "config/deploy.yml",
        ".kamal/secrets",
        "rel/overlays/bin/server"
      ],
      &Igniter.exists?(igniter, &1)
    )
  end

  @spec proxy?(Igniter.t()) :: boolean()
  def proxy?(igniter) do
    if Igniter.exists?(igniter, "config/deploy.yml") do
      igniter
      |> Igniter.include_existing_file("config/deploy.yml", required?: true)
      |> Map.fetch!(:rewrite)
      |> Rewrite.source!("config/deploy.yml")
      |> Rewrite.Source.get(:content)
      |> String.contains?("\nproxy:\n")
    else
      false
    end
  end

  @spec hostname_for_app(atom() | String.t()) :: String.t()
  def hostname_for_app(app_name), do: "#{slug(app_name)}.tamayotchi.com"

  defp configure_enabled(igniter, app_name, options) do
    if Project.phoenix?(igniter) do
      proxy? = Keyword.fetch!(options, :proxy)
      sqlite? = Project.sqlite?(igniter)
      base_module = Igniter.Project.Module.module_name_prefix(igniter)

      igniter
      |> put_managed_file("config/deploy.yml", deploy_config(app_name, proxy?, sqlite?))
      |> put_managed_file(".kamal/secrets", secrets(app_name))
      |> put_managed_file("Dockerfile", dockerfile(app_name, sqlite?))
      |> put_managed_file(".dockerignore", dockerignore())
      |> put_managed_file("rel/overlays/bin/server", server_script(app_name))
      |> maybe_put_database_files(app_name, base_module, sqlite?)
      |> Manifest.set_feature(app_name, :kamal, true, proxy: proxy?)
      |> Igniter.add_notice(secret_notice(app_name))
    else
      Igniter.add_issue(igniter, "Kamal deployment requires Phoenix")
    end
  end

  defp maybe_put_database_files(igniter, app_name, base_module, true) do
    igniter
    |> put_managed_file("rel/overlays/bin/migrate", migrate_script(app_name, base_module))
    |> put_managed_file("rel/overlays/bin/docker-entrypoint", docker_entrypoint())
    |> put_managed_file(release_path(app_name), release_module(app_name, base_module))
  end

  defp maybe_put_database_files(igniter, _app_name, _base_module, false), do: igniter

  defp put_managed_file(igniter, path, desired) do
    Igniter.create_or_update_file(igniter, path, desired, fn source ->
      current = Rewrite.Source.get(source, :content)

      cond do
        current == desired ->
          source

        String.contains?(current, @managed_marker) ->
          Rewrite.Source.update(source, :content, desired)

        true ->
          {:error,
           "Refusing to overwrite unmanaged #{path}; adopt it manually or add a tamayotchi_stack managed marker"}
      end
    end)
  end

  defp deploy_config(app_name, true, sqlite?) do
    app = to_string(app_name)
    service = slug(app_name)
    hostname = hostname_for_app(app_name)

    """
    # #{@managed_marker}
    service: #{service}
    image: #{@registry_owner}/#{service}

    servers:
      web:
        - #{@server}

    ssh:
      user: root
      keys:
        - ~/.ssh/id_home_server

    proxy:
      ssl: false
      host: #{hostname}
      app_port: 4000
      healthcheck:
        interval: 3
        path: /
        timeout: 180

    registry:
      username: #{@registry_owner}
      password:
        - KAMAL_REGISTRY_PASSWORD

    builder:
      arch: amd64

    env:
      clear:
        PHX_HOST: #{hostname}
        PORT: 4000
    #{database_environment(app, sqlite?)}  secret:
        - SECRET_KEY_BASE
    #{database_volume(service, sqlite?)}
    aliases:
      console: app exec --interactive --reuse "/app/bin/#{app} remote"
      shell: app exec --interactive --reuse "/bin/sh"
      logs: app logs -f
    #{migration_alias(app, sqlite?)}
    """
  end

  defp deploy_config(app_name, false, sqlite?) do
    app = to_string(app_name)
    service = slug(app_name)

    """
    # #{@managed_marker}
    service: #{service}
    image: #{@registry_owner}/#{service}

    servers:
      web:
        hosts:
          - #{@server}
        proxy: false
        options:
          publish: "4000:4000"

    ssh:
      user: root
      keys:
        - ~/.ssh/id_home_server

    registry:
      username: #{@registry_owner}
      password:
        - KAMAL_REGISTRY_PASSWORD

    builder:
      arch: amd64

    env:
      clear:
        PHX_HOST: #{@server}
        PORT: 4000
    #{database_environment(app, sqlite?)}  secret:
        - SECRET_KEY_BASE
    #{database_volume(service, sqlite?)}
    aliases:
      console: app exec --interactive --reuse "/app/bin/#{app} remote"
      shell: app exec --interactive --reuse "/bin/sh"
      logs: app logs -f
    #{migration_alias(app, sqlite?)}
    """
  end

  defp database_environment(app, true), do: "    DATABASE_PATH: /app/storage/#{app}.db\n"
  defp database_environment(_app, false), do: ""

  defp database_volume(service, true) do
    """

    volumes:
      - "#{service}_storage:/app/storage"
    """
  end

  defp database_volume(_service, false), do: ""

  defp migration_alias(_app, true), do: "  migrate: app exec --reuse \"/app/bin/migrate\"\n"
  defp migration_alias(_app, false), do: ""

  defp secrets(app_name) do
    item = app_name |> to_string() |> String.upcase()

    """
    # #{@managed_marker}
    # Safe to commit: this file contains 1Password references, never raw values.
    SECRETS=$(kamal secrets fetch --adapter 1password --account #{@one_password_account} --from #{@one_password_vault}/#{item} KAMAL_REGISTRY_PASSWORD SECRET_KEY_BASE)
    KAMAL_REGISTRY_PASSWORD=$(kamal secrets extract KAMAL_REGISTRY_PASSWORD $SECRETS)
    SECRET_KEY_BASE=$(kamal secrets extract SECRET_KEY_BASE $SECRETS)
    """
  end

  defp dockerfile(app_name, sqlite?) do
    app = to_string(app_name)

    """
    # #{@managed_marker}
    ARG ELIXIR_VERSION=1.19.1
    ARG OTP_VERSION=28.1.1
    ARG DEBIAN_VERSION=trixie-20260610-slim

    ARG BUILDER_IMAGE="docker.io/hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
    ARG RUNNER_IMAGE="docker.io/debian:${DEBIAN_VERSION}"

    FROM ${BUILDER_IMAGE} AS builder

    RUN apt-get update \\
      && apt-get install -y --no-install-recommends build-essential git \\
      && rm -rf /var/lib/apt/lists/*

    WORKDIR /app

    RUN mix local.hex --force \\
      && mix local.rebar --force

    ENV MIX_ENV="prod"

    COPY mix.exs mix.lock ./
    RUN mix deps.get --only $MIX_ENV
    RUN mkdir config
    COPY config/config.exs config/${MIX_ENV}.exs config/
    RUN mix deps.compile
    RUN mix assets.setup

    COPY priv priv
    COPY lib lib
    RUN mix compile

    COPY assets assets
    RUN mix assets.deploy

    COPY config/runtime.exs config/
    COPY rel rel
    RUN chmod +x rel/overlays/bin/* \\
      && mix release

    FROM ${RUNNER_IMAGE} AS final

    RUN apt-get update \\
      && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 locales ca-certificates \\
      && rm -rf /var/lib/apt/lists/*

    RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \\
      && locale-gen

    ENV LANG=en_US.UTF-8
    ENV LANGUAGE=en_US:en
    ENV LC_ALL=en_US.UTF-8
    ENV MIX_ENV="prod"

    WORKDIR "/app"
    #{storage_setup(sqlite?)}
    COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/#{app} ./

    USER nobody
    #{docker_entrypoint_config(sqlite?)}
    CMD ["/app/bin/server"]
    """
  end

  defp storage_setup(true) do
    "RUN mkdir -p /app/storage && chown -R nobody:nogroup /app\n"
  end

  defp storage_setup(false), do: "RUN chown nobody:nogroup /app\n"

  defp docker_entrypoint_config(true), do: "ENTRYPOINT [\"/app/bin/docker-entrypoint\"]\n"
  defp docker_entrypoint_config(false), do: ""

  defp dockerignore do
    """
    # #{@managed_marker}
    .dockerignore
    .git
    .kamal
    .env
    .env.*
    /_build/
    /assets/node_modules/
    /cover/
    /deps/
    /doc/
    /priv/static/assets/
    /priv/static/cache_manifest.json
    /test/
    /tmp/
    *.db
    *.db-*
    *.ez
    erl_crash.dump
    """
  end

  defp server_script(app_name) do
    """
    #!/bin/sh
    # #{@managed_marker}
    set -eu

    cd -P -- "$(dirname -- "$0")"
    PHX_SERVER=true exec ./#{app_name} start
    """
  end

  defp migrate_script(app_name, base_module) do
    """
    #!/bin/sh
    # #{@managed_marker}
    set -eu

    cd -P -- "$(dirname -- "$0")"
    exec ./#{app_name} eval #{inspect(base_module)}.Release.migrate
    """
  end

  defp docker_entrypoint do
    """
    #!/bin/sh
    # #{@managed_marker}
    set -eu

    if [ "$#" -eq 1 ] && [ "$1" = "/app/bin/server" ]; then
      echo "Running database migrations..."
      /app/bin/migrate
    fi

    exec "$@"
    """
  end

  defp release_module(app_name, base_module) do
    """
    # #{@managed_marker}
    defmodule #{inspect(base_module)}.Release do
      @moduledoc false
      @app #{inspect(app_name)}

      def migrate do
        load_app()

        for repo <- repos() do
          {:ok, _, _} =
            Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
        end
      end

      def rollback(repo, version) do
        load_app()
        {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
      end

      defp repos, do: Application.fetch_env!(@app, :ecto_repos)

      defp load_app do
        Application.ensure_all_started(:ssl)
        Application.ensure_loaded(@app)
      end
    end
    """
  end

  defp release_path(app_name), do: "lib/#{app_name}/release.ex"

  defp secret_notice(app_name) do
    item = app_name |> to_string() |> String.upcase()

    "Store KAMAL_REGISTRY_PASSWORD and SECRET_KEY_BASE (generate with mix phx.gen.secret) " <>
      "in 1Password item #{@one_password_vault}/#{item} before deploying."
  end

  defp slug(app_name) do
    app_name
    |> to_string()
    |> String.replace("_", "-")
  end
end
