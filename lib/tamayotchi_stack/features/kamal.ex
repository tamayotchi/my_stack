defmodule TamayotchiStack.Features.Kamal do
  @moduledoc false

  alias TamayotchiStack.Manifest
  alias TamayotchiStack.Project

  @managed_marker "Managed by tamayotchi_stack."
  @server "home-server"
  @registry_owner "tamayotchi"
  @one_password_account "instaleap-llc.1password.com"
  @one_password_vault "SERVER"

  @spec configure(Igniter.t(), atom(), boolean(), keyword()) :: Igniter.t()
  def configure(igniter, app_name, enabled?, options \\ []) do
    if enabled? do
      configure_enabled(igniter, app_name, options)
    else
      igniter = Manifest.set_feature(igniter, app_name, :kamal, false)

      if Igniter.exists?(igniter, "config/deploy.yml") do
        Igniter.add_notice(
          igniter,
          "Phoenix is not managed. Existing Kamal files were preserved for manual review; no deployed services, schedules, or credentials were removed."
        )
      else
        igniter
      end
    end
  end

  @doc false
  def secret_location_for_app(app_name) do
    %{
      account: @one_password_account,
      vault: @one_password_vault,
      item: app_name |> to_string() |> String.upcase()
    }
  end

  @spec hostname_for_app(atom() | String.t()) :: String.t()
  def hostname_for_app(app_name), do: "#{slug(app_name)}.tamayotchi.com"

  defp configure_enabled(igniter, app_name, options) do
    if Project.phoenix?(igniter) and Project.sqlite?(igniter) do
      proxy? = Keyword.fetch!(options, :proxy)
      base_module = Igniter.Project.Module.module_name_prefix(igniter)

      r2? =
        case Manifest.read(igniter) do
          {:ok, manifest} -> Keyword.has_key?(manifest[:features], :r2)
          {:error, _} -> false
        end

      # Opting out of management must not remove credentials needed by code
      # that remains in the application.
      r2? = r2? or existing_r2_environment?(igniter)

      deploy_variants =
        for proxy <- [true, false],
            r2 <- [true, false],
            do: deploy_config(app_name, proxy, r2)

      igniter
      |> put_managed_file(
        "config/deploy.yml",
        deploy_config(app_name, proxy?, r2?),
        fn current ->
          if current in deploy_variants do
            {:ok, deploy_config(app_name, proxy?, r2?)}
          else
            merge_r2_environment(current, app_name, proxy?, r2?)
          end
        end
      )
      |> configure_public_host(options[:host])
      |> put_managed_file(".kamal/secrets", secrets(app_name, r2?), fn current ->
        if current in [secrets(app_name, false), secrets(app_name, true)] do
          {:ok, secrets(app_name, r2?)}
        else
          merge_r2_secrets(current, r2?)
        end
      end)
      |> put_managed_file("Dockerfile", dockerfile(app_name))
      |> put_managed_file(".dockerignore", dockerignore())
      |> put_managed_file("rel/overlays/bin/server", server_script(app_name))
      |> put_database_files(app_name, base_module)
      |> Manifest.set_feature(app_name, :kamal, true, proxy: proxy?)
      |> Igniter.add_notice(secret_notice(app_name))
    else
      Igniter.add_issue(igniter, "Kamal deployment requires Phoenix with SQLite")
    end
  end

  defp configure_public_host(igniter, nil), do: igniter

  defp configure_public_host(igniter, host) do
    Igniter.update_file(igniter, "config/deploy.yml", fn source ->
      current = Rewrite.Source.get(source, :content)

      if managed_file?(current) do
        case TamayotchiStack.PublicHost.patch(current, host) do
          {:ok, updated} -> Rewrite.Source.update(source, :content, updated)
          {:error, reason} -> {:error, reason}
        end
      else
        {:error, "Refusing to update the public host in unmanaged config/deploy.yml"}
      end
    end)
  end

  defp put_database_files(igniter, app_name, base_module) do
    igniter
    |> put_managed_file("rel/overlays/bin/migrate", migrate_script(app_name, base_module))
    |> put_managed_file("rel/overlays/bin/docker-entrypoint", docker_entrypoint())
    |> put_managed_file(Project.release_path(base_module), release_module(app_name, base_module))
  end

  defp put_managed_file(igniter, path, desired, merge \\ nil) do
    Igniter.create_or_update_file(igniter, path, desired, fn source ->
      current = Rewrite.Source.get(source, :content)

      cond do
        current == desired ->
          source

        managed_file?(current) ->
          # Source/release files are app-owned. Deployment data has explicit
          # merge rules; a marker alone is not permission to erase user edits.
          case if(merge, do: merge.(current), else: {:ok, current}) do
            {:ok, updated} -> Rewrite.Source.update(source, :content, updated)
            {:error, reason} -> {:error, "Refusing to overwrite customized #{path}; #{reason}"}
          end

        true ->
          {:error,
           "Refusing to overwrite unmanaged #{path}; adopt it manually or add a tamayotchi_stack managed marker"}
      end
    end)
  end

  defp existing_r2_environment?(igniter) do
    if Igniter.exists?(igniter, "config/deploy.yml") do
      igniter = Igniter.include_existing_file(igniter, "config/deploy.yml")

      contents =
        igniter.rewrite |> Rewrite.source!("config/deploy.yml") |> Rewrite.Source.get(:content)

      String.contains?(contents, "R2_ACCESS_KEY_ID")
    else
      false
    end
  end

  defp merge_r2_environment(current, app, proxy?, true) do
    # Restrict edits to the conventional env block, preserving all existing
    # values, comments, hosts, and unrelated configuration.
    pattern = ~r/^(env:\n  clear:\n)(.*?)(  secret:\n)(.*?)(?=^[^ \n#]|\z)/ms

    case Regex.run(pattern, current) do
      [block, start, clear, secret_start, secret] ->
        if Regex.match?(~r/^proxy:\s*$/m, current) == proxy? and
             simple_environment_block?(clear, secret) do
          defaults = [
            {"R2_REGION", "auto"},
            {"R2_BUCKET", TamayotchiStack.Features.R2.bucket_for_app(app)}
          ]

          clear =
            Enum.reduce(defaults, clear, fn {key, value}, text ->
              if Regex.match?(Regex.compile!("^    [\"']?#{key}[\"']?:", "m"), text),
                do: text,
                else: text <> "    #{key}: #{value}\n"
            end)

          secret =
            Enum.reduce(r2_secret_names(), secret, fn name, text ->
              if Regex.match?(
                   Regex.compile!("^    - [\"']?#{name}[\"']?(?:[ \\t]+#.*)?[ \\t]*$", "m"),
                   text
                 ),
                 do: text,
                 else: text <> "    - #{name}\n"
            end)

          {:ok,
           String.replace(current, block, start <> clear <> secret_start <> secret, global: false)}
        else
          {:error, "review the proxy setting and env block structure before adding R2 manually"}
        end

      _ ->
        {:error,
         "add R2_REGION/R2_BUCKET to env.clear and the three R2 credential names to env.secret manually"}
    end
  end

  defp merge_r2_environment(current, _app, proxy?, false) do
    if Regex.match?(~r/^proxy:\s*$/m, current) == proxy? do
      {:ok, current}
    else
      {:error, "review deployment changes manually"}
    end
  end

  defp simple_environment_block?(clear, secret) do
    Enum.all?(
      String.split(clear, "\n"),
      &Regex.match?(~r/^(\s*|\s*#.*|    ["']?[A-Za-z_][A-Za-z_0-9]*["']?:.*)$/, &1)
    ) and
      Enum.all?(String.split(secret, "\n"), &Regex.match?(~r/^(\s*|\s*#.*|    - .*)$/, &1))
  end

  defp merge_r2_secrets(current, true) do
    case Regex.run(~r/^SECRETS=\$\(kamal secrets fetch [^\n]*\)$/m, current) do
      [fetch] ->
        updated_fetch =
          Enum.reduce(r2_secret_names(), fetch, fn name, line ->
            if name in String.split(line, [" ", ")"]),
              do: line,
              else: String.trim_trailing(line, ")") <> " #{name})"
          end)

        extracts =
          Enum.map_join(r2_secret_names(), "", fn name ->
            if Regex.match?(Regex.compile!("^(?:export +)?#{name}=", "m"), current),
              do: "",
              else: "\n#{name}=$(kamal secrets extract #{name} $SECRETS)"
          end)

        {:ok, String.replace(current, fetch, updated_fetch <> extracts, global: false)}

      _ ->
        {:error,
         "add R2_ACCOUNT_ID, R2_ACCESS_KEY_ID, and R2_SECRET_ACCESS_KEY references to your secrets provider manually"}
    end
  end

  defp merge_r2_secrets(current, false), do: {:ok, current}

  defp managed_file?(contents) do
    comment = "# #{@managed_marker}\n"

    String.starts_with?(contents, comment) or
      String.starts_with?(contents, "#!/bin/sh\n" <> comment)
  end

  defp deploy_config(app_name, proxy?, r2?) do
    app = to_string(app_name)
    service = slug(app_name)
    # An SSH alias is not necessarily resolvable by browsers. Keep the public
    # application hostname independent of the SSH destination, with or without proxy.
    hostname = hostname_for_app(app_name)

    """
    # #{@managed_marker}
    service: #{service}
    image: #{@registry_owner}/#{service}

    #{server_configuration(proxy?)}#{proxy_configuration(proxy?, hostname)}ssh:
      user: root
      keys:
        - ~/.ssh/id_home_server

    registry:
      server: ghcr.io
      username: #{@registry_owner}
      password:
        - KAMAL_REGISTRY_PASSWORD

    builder:
      arch: amd64

    env:
      clear:
        PHX_HOST: #{hostname}
        PORT: 4000
        DATABASE_PATH: /app/storage/#{app}.db
    #{r2_environment(app, r2?)}  secret:
        - SECRET_KEY_BASE
    #{r2_secrets(r2?)}
    volumes:
      - "#{service}_storage:/app/storage"

    aliases:
      console: app exec --interactive --reuse "/app/bin/#{app} remote"
      shell: app exec --interactive --reuse "/bin/sh"
      logs: app logs -f
      migrate: app exec --reuse "/app/bin/migrate"
    """
  end

  defp server_configuration(true) do
    """
    servers:
      web:
        - #{@server}

    """
  end

  defp server_configuration(false) do
    """
    servers:
      web:
        hosts:
          - #{@server}
        proxy: false
        options:
          publish: "4000:4000"

    """
  end

  defp proxy_configuration(true, hostname) do
    """
    proxy:
      ssl: false
      host: #{hostname}
      app_port: 4000
      healthcheck:
        interval: 3
        path: /
        timeout: 180

    """
  end

  defp proxy_configuration(false, _hostname), do: ""

  defp r2_environment(app, true) do
    "    R2_REGION: auto\n    R2_BUCKET: #{TamayotchiStack.Features.R2.bucket_for_app(app)}\n"
  end

  defp r2_environment(_app, false), do: ""

  defp r2_secrets(true) do
    Enum.map_join(r2_secret_names(), "", &"    - #{&1}\n")
  end

  defp r2_secrets(false), do: ""

  defp r2_secret_names, do: ~w(R2_ACCOUNT_ID R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY)

  defp secrets(app_name, r2?) do
    item = app_name |> to_string() |> String.upcase()
    extra_names = if r2?, do: " " <> Enum.join(r2_secret_names(), " "), else: ""

    extra_extracts =
      if r2?,
        do:
          Enum.map_join(r2_secret_names(), "", &"#{&1}=$(kamal secrets extract #{&1} $SECRETS)\n"),
        else: ""

    """
    # #{@managed_marker}
    # Safe to commit: this file contains 1Password references, never raw values.
    SECRETS=$(kamal secrets fetch --adapter 1password --account #{@one_password_account} --from #{@one_password_vault}/#{item} KAMAL_REGISTRY_PASSWORD SECRET_KEY_BASE#{extra_names})
    KAMAL_REGISTRY_PASSWORD=$(kamal secrets extract KAMAL_REGISTRY_PASSWORD $SECRETS)
    SECRET_KEY_BASE=$(kamal secrets extract SECRET_KEY_BASE $SECRETS)
    #{extra_extracts}\
    """
  end

  defp dockerfile(app_name) do
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
    RUN mkdir -p /app/storage && chown -R nobody:nogroup /app

    COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/#{app} ./

    USER nobody
    ENTRYPOINT ["/app/bin/docker-entrypoint"]

    CMD ["/app/bin/server"]
    """
  end

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

  defp secret_notice(app_name) do
    item = app_name |> to_string() |> String.upcase()

    "New deployments use ghcr.io/#{@registry_owner}/#{slug(app_name)} with local Kamal (no GitHub Actions). " <>
      "Configure a package-scoped GitHub classic PAT once as KAMAL_REGISTRY_PASSWORD in SERVER/TAMAYOTCHI_BOOTSTRAP; " <>
      "setup generates SECRET_KEY_BASE and saves application credentials automatically. " <>
      "Existing registry settings and credentials are preserved; migrate old registries explicitly. Secrets are referenced from " <>
      "1Password item #{@one_password_vault}/#{item}."
  end

  defp slug(app_name) do
    app_name
    |> to_string()
    |> String.replace("_", "-")
  end
end
