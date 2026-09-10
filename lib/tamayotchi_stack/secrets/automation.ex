defmodule TamayotchiStack.Secrets.Automation do
  @moduledoc false

  alias TamayotchiStack.Secrets
  alias TamayotchiStack.Secrets.Cloudflare
  alias TamayotchiStack.Secrets.CloudflareHttp
  alias TamayotchiStack.Secrets.GoatCounter
  alias TamayotchiStack.Secrets.GoatCounterHttp

  @derive {Inspect, only: [:problems]}
  defstruct [:base, :values, :jobs, :problems, :goatcounter]

  @bootstrap "TAMAYOTCHI_BOOTSTRAP"
  @groups [
    {:r2, "R2_ACCOUNT_ID", "R2_ACCESS_KEY_ID", "R2_SECRET_ACCESS_KEY", "R2_BUCKET",
     "TAMAYOTCHI_R2_PROVISIONING"},
    {:backups, "LITESTREAM_ENDPOINT", "LITESTREAM_ACCESS_KEY_ID", "LITESTREAM_SECRET_ACCESS_KEY",
     "LITESTREAM_BUCKET_NAME", "TAMAYOTCHI_BACKUPS_PROVISIONING"}
  ]

  def prepare(manifest, options, dependencies \\ []) do
    with {:ok, base} <- Secrets.prepare(manifest, options, dependencies),
         :ok <- separate_bootstrap(base, options) do
      cloud? = Enum.any?(base.actions, &(elem(&1, 1) == :missing))
      goatcounter? = Keyword.has_key?(manifest[:features], :phoenix) and is_nil(options[:only])
      initial = %__MODULE__{base: base, values: base.imports, jobs: [], problems: []}

      if Keyword.get(options, :provision, true) and (cloud? or goatcounter?) do
        with {:ok, shared} <-
               Secrets.read_shared(base, Keyword.get(options, :bootstrap_item, @bootstrap)),
             {:ok, plan} <-
               if(cloud?,
                 do: enrich(base, manifest[:app], options, dependencies, shared),
                 else: {:ok, initial}
               ) do
          if goatcounter?,
            do: prepare_goatcounter(plan, shared, manifest[:app], options, dependencies),
            else: {:ok, plan}
        end
      else
        {:ok, initial}
      end
    end
  rescue
    _ -> {:error, "Cannot prepare automatic credentials safely; no write was attempted"}
  end

  defp separate_bootstrap(base, options) do
    bootstrap = Keyword.get(options, :bootstrap_item, @bootstrap)

    identities =
      [base.destination.item] ++
        if(base.current, do: [base.current["id"], base.current["title"]], else: [])

    if bootstrap in identities,
      do:
        {:error,
         "The bootstrap item must be separate from the deployment item, including in manual/partial mode"},
      else: :ok
  end

  def format(plan) do
    jobs =
      Enum.map_join(plan.jobs, "\n", fn {_group, job} ->
        "  Cloudflare: #{if job.exists?, do: "reuse", else: "create"} #{job.bucket}; issue token #{job.name}"
      end)

    goatcounter =
      if plan.goatcounter,
        do:
          "  GoatCounter: #{if plan.goatcounter.exists?, do: "reuse", else: "create"} #{plan.goatcounter.code}.goatcounter.com",
        else: ""

    Enum.join(
      [Secrets.format(plan.base), jobs, goatcounter | plan.problems] |> Enum.reject(&(&1 == "")),
      "\n"
    )
  end

  def ready?(plan), do: plan.problems == [] and Secrets.ready?(plan.base)

  def changed?(plan),
    do:
      Secrets.changed?(plan.base) or
        (not is_nil(plan.goatcounter) and not plan.goatcounter.exists?)

  def apply(plan) do
    cond do
      not ready?(plan) ->
        {:error,
         "Credential setup is incomplete. Configure the shared TAMAYOTCHI_BOOTSTRAP item (see mix help tamayotchi.secrets), or supply the missing environment values. Then run mix tamayotchi.secrets --yes; existing project files need not be regenerated. Nothing was written."}

      not changed?(plan) ->
        {:ok, :unchanged}

      true ->
        execute(plan)
    end
  end

  defp prepare_goatcounter(plan, shared, app, options, dependencies) do
    env = Keyword.get(dependencies, :env, &System.get_env/1)
    default_host = String.replace(to_string(app), "_", "-") <> ".tamayotchi.com"

    with {:ok, url} <- shared_value(shared, "GOATCOUNTER_SITE_URL", env, true),
         {:ok, token} <- shared_value(shared, "GOATCOUNTER_API_TOKEN", env, true),
         true <- present?(url) and present?(token),
         {:ok, host} <- setting(options[:deployment], "PHX_HOST", default_host, false),
         {:ok, job} <-
           GoatCounter.prepare(
             plan.base,
             app,
             url,
             token,
             "https://" <> host,
             Keyword.get(dependencies, :goatcounter, &GoatCounterHttp.request/5)
           ) do
      {:ok, %{plan | goatcounter: job}}
    else
      false ->
        {:ok,
         %{
           plan
           | problems:
               plan.problems ++
                 [
                   "Set GOATCOUNTER_SITE_URL and GOATCOUNTER_API_TOKEN in the shared bootstrap item; use Read sites + Create sites permissions."
                 ]
         }}

      {:error, _} = error ->
        error
    end
  end

  defp enrich(base, app, options, dependencies, shared) do
    env = Keyword.get(dependencies, :env, &System.get_env/1)
    title = Keyword.get(options, :bootstrap_item, @bootstrap)

    account? =
      Enum.any?(@groups, fn {_, config, access, secret, _, _} ->
        Enum.any?([config, access, secret], &missing?(base, &1))
      end)

    token? =
      Enum.any?(@groups, fn {_, _, access, secret, _, _} ->
        missing?(base, access) and missing?(base, secret)
      end)

    with {:ok, registry} <-
           shared_value(
             shared,
             "KAMAL_REGISTRY_PASSWORD",
             env,
             missing?(base, "KAMAL_REGISTRY_PASSWORD")
           ),
         {:ok, account} <- shared_value(shared, "CLOUDFLARE_ACCOUNT_ID", env, account?),
         {:ok, token} <- shared_value(shared, "CLOUDFLARE_API_TOKEN", env, token?),
         {:ok, values} <- registry_values(base, registry, options[:deployment]) do
      {:ok, updated} = Secrets.replan(base, values)
      client = Keyword.get(dependencies, :cloudflare, &CloudflareHttp.request/4)

      result =
        Enum.reduce_while(@groups, {:ok, updated, values, []}, fn group,
                                                                  {:ok, current, values, jobs} ->
          case prepare_group(current, group, account, token, app, options, env, client, values) do
            {:ok, next, values, nil} -> {:cont, {:ok, next, values, jobs}}
            {:ok, next, values, job} -> {:cont, {:ok, next, values, jobs ++ [{group, job}]}}
            error -> {:halt, error}
          end
        end)

      with {:ok, updated, values, jobs} <- result do
        actions =
          Enum.map(updated.actions, fn {name, action} ->
            cond do
              name == "KAMAL_REGISTRY_PASSWORD" and missing?(base, name) and action == :import ->
                {name, :bootstrap}

              missing?(base, name) and action == :import ->
                {name, :derive}

              true ->
                {name, action}
            end
          end)

        problems =
          if Enum.any?(actions, &(elem(&1, 1) == :missing)),
            do: [
              "One-time setup: configure #{title} in the selected vault with CLOUDFLARE_ACCOUNT_ID, CLOUDFLARE_API_TOKEN, and KAMAL_REGISTRY_PASSWORD as needed. Do not store the provisioning token in the app item."
            ],
            else: []

        {:ok,
         %__MODULE__{
           base: %{updated | actions: actions},
           values: values,
           jobs: jobs,
           problems: problems
         }}
      end
    end
  end

  defp prepare_group(
         base,
         {kind, config, access, secret, bucket_key, marker} = _group,
         account,
         token,
         app,
         options,
         env,
         client,
         values
       ) do
    actions = Map.new(base.actions)
    pair_missing? = actions[access] == :missing and actions[secret] == :missing
    needs_config? = actions[config] == :missing

    cond do
      Enum.count([actions[access], actions[secret]], &(&1 == :missing)) == 1 ->
        {:error,
         "An access-key pair is incomplete. Supply both matching fields through the environment; automatic provisioning never combines existing and newly issued halves."}

      needs_config? and
          Enum.any?([actions[access], actions[secret]], &(&1 in [:preserve, :conceal, :import])) ->
        {:error,
         "Supply the matching account/endpoint for existing or imported access keys through the environment; automatic setup will not guess their provider."}

      not pair_missing? and not needs_config? ->
        {:ok, base, values, nil}

      not present?(account) ->
        {:ok, base, values, nil}

      true ->
        expected =
          if kind == :r2, do: account, else: "https://#{account}.r2.cloudflarestorage.com"

        with {:ok, existing} <- Secrets.field_value(base.current, config),
             :ok <-
               compatible_config(
                 if(present?(existing), do: existing, else: values[config]),
                 expected
               ),
             :ok <- valid_account(account) do
          values = if needs_config?, do: Map.put(values, config, expected), else: values
          {:ok, updated} = Secrets.replan(base, values)
          # Keep actions from previously prepared groups, since provider values
          # intentionally do not exist until after confirmation.
          updated = %{
            updated
            | actions:
                Enum.map(updated.actions, fn {name, action} ->
                  if actions[name] == :provision, do: {name, :provision}, else: {name, action}
                end)
          }

          if pair_missing? and present?(token) do
            default =
              if kind == :backups,
                do: String.replace(to_string(app), "_", "-") <> "-db-backups",
                else: TamayotchiStack.Features.R2.bucket_for_app(app)

            with {:ok, nil} <- marker_absent(base, marker),
                 {:ok, bucket} <-
                   setting(options[:deployment], bucket_key, env.(bucket_key) || default, true),
                 :ok <- compatible_endpoint(kind, options[:deployment], env, account),
                 :ok <- separate_bucket(kind, options[:deployment], env, app, bucket),
                 {:ok, job} <-
                   Cloudflare.prepare(
                     account,
                     token,
                     bucket,
                     token_name(base, kind, account, bucket),
                     kind == :backups,
                     client
                   ) do
              actions =
                Enum.map(updated.actions, fn {name, action} ->
                  if name in [access, secret], do: {name, :provision}, else: {name, action}
                end)

              {:ok, %{updated | actions: actions}, values, job}
            end
          else
            {:ok, updated, values, nil}
          end
        end
    end
  end

  defp execute(plan) do
    # Preflight is all-or-nothing. Once writes start, commit each issued pair
    # immediately, not after the next provider call. Durable markers make an
    # interrupted or ambiguous provider write refuse automatic reissuance.
    with :ok <- Secrets.check_unchanged(plan.base),
         {:ok, initial} <- Secrets.replan(plan.base, plan.values),
         initial <- %{initial | actions: Enum.reject(initial.actions, &(elem(&1, 1) == :missing))},
         {:ok, initial} <- Secrets.save(initial),
         {:ok, saved} <-
           Enum.reduce_while(plan.jobs, {:ok, initial}, fn {group, job}, {:ok, current} ->
             case issue_and_save(current, group, job) do
               {:ok, next} -> {:cont, {:ok, next}}
               error -> {:halt, error}
             end
           end),
         {:ok, _} <- GoatCounter.apply(saved, plan.goatcounter) do
      {:ok, :saved}
    else
      _ ->
        {:error,
         "Automatic credential setup was not confirmed complete. Some credentials may already be saved and cloud resources may exist. Inspect 1Password, Cloudflare, and GoatCounter before retrying; provisioning markers prevent automatic reissuance. No existing credential was intentionally rotated."}
    end
  rescue
    _ ->
      {:error,
       "Automatic credential setup failed; inspect 1Password, Cloudflare, and GoatCounter before retrying. Details suppressed to protect credentials."}
  end

  defp issue_and_save(base, {_kind, _config, access, secret, _bucket, marker}, job) do
    with {:ok, nil} <- marker_absent(base, marker),
         {:ok, marked} <-
           Secrets.save_values(base, %{marker => job.name}, [{marker, "CONCEALED"}]),
         {:ok, pair} <- Cloudflare.provision(job),
         {:ok, saved} <-
           Secrets.save_values(marked, %{access => pair.access_key, secret => pair.secret_key}) do
      {:ok, saved}
    end
  end

  # The shared registry credential is for GHCR, not a generic password to copy
  # into any preserved deployment. Explicit environment/manual imports remain
  # available for other registries. Token format is checked, not remote validity.
  defp registry_values(base, registry, deployment) do
    if present?(registry) and missing?(base, "KAMAL_REGISTRY_PASSWORD") do
      with :ok <- ghcr_destination(deployment),
           true <- Regex.match?(~r/\A(?:ghp_[A-Za-z0-9]{36}|[a-fA-F0-9]{40})\z/, registry) do
        {:ok, Map.put(base.imports, "KAMAL_REGISTRY_PASSWORD", registry)}
      else
        false ->
          {:error,
           "The shared GHCR credential must be a GitHub classic PAT with read:packages/write:packages. gh's OAuth token, fine-grained PATs, and expiring Actions tokens are not suitable. No credential was copied."}

        error ->
          error
      end
    else
      {:ok, base.imports}
    end
  end

  defp ghcr_destination(nil), do: :ok

  defp ghcr_destination(deployment) do
    blocks = Regex.scan(~r/^registry:\n(.*?)(?=^[^\s#]|\z)/ms, deployment)

    case blocks do
      [[_, block]] ->
        server? =
          case Regex.scan(~r/^  (?:server|"server"|'server')[ \t]*:[^\n]*$/m, block) do
            [[line]] -> Regex.match?(~r/^  server:[ \t]+(["']?)ghcr\.io\1[ \t]*(?:#.*)?$/, line)
            _ -> false
          end

        if server? and root_definitions(deployment, "registry") == 1 and
             conventional_document?(deployment) do
          :ok
        else
          {:error,
           "The shared registry PAT is for GHCR. Set registry.server to ghcr.io in config/deploy.yml, or use --no-provision with matching credentials for the existing registry. Existing registry settings were not changed."}
        end

      _ ->
        {:error,
         "Cannot infer the registry safely; use a literal GHCR registry block or manual credential imports with --no-provision"}
    end
  end

  defp shared_value(_item, _name, _env, false), do: {:ok, nil}

  defp shared_value(item, name, env, true) do
    # Explicit environment overrides support CI without storing bootstrap tokens
    # in a repository. The shared item is never edited or copied wholesale.
    if present?(env.(name)), do: {:ok, env.(name)}, else: Secrets.field_value(item, name)
  end

  defp missing?(base, name), do: {name, :missing} in base.actions
  defp present?(value), do: is_binary(value) and String.trim(value) != ""
  defp compatible_config(value, expected) when value in [nil, ""] or value == expected, do: :ok

  defp compatible_config(_, _),
    do:
      {:error,
       "Existing R2 account/backup endpoint differs from the bootstrap account; supply matching credentials with --no-provision instead of silently changing providers"}

  defp valid_account(account) do
    if Regex.match?(~r/\A[a-f0-9]{32}\z/, account),
      do: :ok,
      else: {:error, "CLOUDFLARE_ACCOUNT_ID must be the 32-character account ID"}
  end

  defp marker_absent(base, marker) do
    case Secrets.field_value(base.current, marker) do
      {:ok, nil} ->
        {:ok, nil}

      _ ->
        {:error,
         "A 1Password provisioning marker exists but its credential pair is incomplete. Inspect the named Cloudflare token and the item; clear the marker only after manual reconciliation. Automatic rotation/reissuance is refused."}
    end
  end

  defp token_name(base, kind, account, bucket) do
    identity =
      Enum.join(
        [
          base.destination.account,
          base.vault_id,
          if(base.current, do: base.current["title"], else: base.destination.item),
          kind,
          account,
          bucket
        ],
        ":"
      )

    suffix = :crypto.hash(:sha256, identity) |> Base.encode16(case: :lower) |> binary_part(0, 24)
    "tamayotchi-#{kind}-#{suffix}"
  end

  # Do not evaluate ERB, YAML tags, aliases, shell, or application configuration.
  # Nonconventional/multiple definitions require a deliberate manual import.
  defp setting(nil, _key, default, _required?), do: {:ok, default}

  defp setting(contents, key, default, required?) do
    case Regex.run(~r/^env:\n(.*?)(?=^\S|\z)/ms, contents) do
      [_, env] ->
        with true <- conventional_document?(contents) and root_definitions(contents, "env") == 1,
             1 <- length(Regex.scan(~r/^  (?:clear|"clear"|'clear')[ \t]*:/m, env)),
             [_, clear] <- Regex.run(~r/\A  clear:\n(.*?)(?=^  \S|\z)/ms, env) do
          literal_setting(contents, clear, key, default, required?)
        else
          _ ->
            {:error,
             "Dynamic or ambiguous deployment configuration requires --no-provision and matching imported credentials"}
        end

      _ ->
        {:error,
         "Cannot infer provisioning targets outside a conventional env.clear block; use --no-provision"}
    end
  end

  defp literal_setting(contents, clear, key, default, required?) do
    key_pattern = "(?:#{key}|\"#{key}\"|'#{key}')"

    definitions =
      length(Regex.scan(Regex.compile!("^[ \\t]*" <> key_pattern <> "[ \\t]*:", "m"), contents))

    pattern =
      Regex.compile!(
        "^    " <> key_pattern <> ":[ \\t]+(['\"]?)([^'\" \\t\\n]+)\\1[ \\t]*(?:#.*)?$",
        "m"
      )

    case Regex.scan(pattern, clear) do
      [[_, quote, value]] ->
        if definitions == 1 and literal_string?(quote, value),
          do: {:ok, value},
          else:
            {:error,
             "Ambiguous deployment bucket/endpoint; use --no-provision with externally supplied credentials"}

      [] when not required? ->
        if definitions != 0,
          do: {:error, "Cannot infer the deployment endpoint safely; use --no-provision"},
          else: {:ok, default}

      _ ->
        {:error,
         "Cannot infer the deployment bucket safely. Use a conventional literal env.clear setting, or --no-provision with externally supplied credentials."}
    end
  end

  defp root_definitions(contents, key) do
    length(Regex.scan(Regex.compile!("^(?:#{key}|\"#{key}\"|'#{key}')[ \\t]*:", "m"), contents))
  end

  defp conventional_document?(contents) do
    not String.contains?(contents, "<%") and
      not Regex.match?(~r/^(?:---|\.\.\.|%YAML|%TAG)(?:\s|$)/m, contents)
  end

  # YAML's implicit scalar types (including octal numbers and dates) can change
  # the runtime bucket name. Require quotes for anything other than clear strings.
  defp literal_string?(quote, _value) when quote != "", do: true

  defp literal_string?("", value) do
    Regex.match?(~r|\A[a-zA-Z][a-zA-Z0-9:./_-]*\z|, value) and
      String.downcase(value) not in ~w(null true false yes no on off)
  end

  defp separate_bucket(:r2, _deployment, _env, _app, _bucket), do: :ok

  defp separate_bucket(:backups, deployment, env, app, bucket) do
    default = env.("R2_BUCKET") || TamayotchiStack.Features.R2.bucket_for_app(app)

    with {:ok, storage_bucket} <- setting(deployment, "R2_BUCKET", default, false) do
      if storage_bucket == bucket,
        do:
          {:error,
           "SQLite backups require a separate private bucket, not the application storage bucket"},
        else: :ok
    end
  end

  defp compatible_endpoint(:backups, deployment, env, account) do
    with {:ok, endpoint} <-
           setting(deployment, "LITESTREAM_ENDPOINT", env.("LITESTREAM_ENDPOINT"), false) do
      compatible_config(endpoint, "https://#{account}.r2.cloudflarestorage.com")
    end
  end

  defp compatible_endpoint(:r2, deployment, env, account) do
    with {:ok, endpoint} <- setting(deployment, "R2_ENDPOINT", env.("R2_ENDPOINT"), false) do
      compatible_config(endpoint, "https://#{account}.r2.cloudflarestorage.com")
    end
  end
end
