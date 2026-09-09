defmodule TamayotchiStack.Secrets do
  @moduledoc false

  alias TamayotchiStack.Features.Kamal
  alias TamayotchiStack.Secrets.Op

  defmodule Plan do
    @moduledoc false
    @derive {Inspect, only: [:destination, :actions]}
    defstruct [:destination, :actions, :fields, :current, :vault_id, :client, :flags, :imports]
  end

  @pairs [
    ~w(R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY),
    ~w(LITESTREAM_ACCESS_KEY_ID LITESTREAM_SECRET_ACCESS_KEY)
  ]
  @markers ~w(TAMAYOTCHI_R2_PROVISIONING TAMAYOTCHI_BACKUPS_PROVISIONING)
  @id ~r/\A[a-z0-9]{26}\z/
  @identifier ~r/\A[A-Za-z0-9][A-Za-z0-9_.-]*\z/
  @metadata ~w(id version title category fields sections urls tags)

  # Only user-facing setup/install enqueue this post-apply command. The pure
  # patchers, sync, declined diffs, and dry runs never contact external systems.
  def queue_setup(igniter, options) do
    with true <- Keyword.get(options, :secrets, true),
         {:ok, manifest} <- TamayotchiStack.Manifest.read(igniter),
         [_ | _] <- fields(manifest),
         false <- Enum.any?(igniter.tasks, &(elem(&1, 0) == "tamayotchi.secrets")) do
      igniter
      |> Igniter.delay_task("tamayotchi.secrets", ["--yes"])
      |> Igniter.add_notice(
        "After accepting these files, missing credentials will be generated/provisioned and saved in 1Password. Authenticate with op and configure SERVER/TAMAYOTCHI_BOOTSTRAP once (see mix help tamayotchi.secrets). Use --no-secrets for offline/file-only setup. Sync never provisions credentials."
      )
    else
      _ -> igniter
    end
  end

  def fields(manifest) do
    features = Keyword.fetch!(manifest, :features)

    [
      {:phoenix, [{"SECRET_KEY_BASE", "CONCEALED"}]},
      {:kamal, [{"KAMAL_REGISTRY_PASSWORD", "CONCEALED"}]},
      {:r2,
       [
         {"R2_ACCOUNT_ID", "CONCEALED"},
         {"R2_ACCESS_KEY_ID", "CONCEALED"},
         {"R2_SECRET_ACCESS_KEY", "CONCEALED"}
       ]},
      {:backups,
       [
         {"LITESTREAM_ENDPOINT", "CONCEALED"},
         {"LITESTREAM_ACCESS_KEY_ID", "CONCEALED"},
         {"LITESTREAM_SECRET_ACCESS_KEY", "CONCEALED"}
       ]}
    ]
    |> Enum.flat_map(fn {feature, fields} ->
      if Keyword.has_key?(features, feature), do: fields, else: []
    end)
  end

  def destination(app, options) do
    defaults = Kamal.secret_location_for_app(app)
    Map.new(defaults, fn {key, value} -> {key, Keyword.get(options, key, value)} end)
  end

  # Read only the conventional literal fetch line, never execute .kamal/secrets.
  # Custom providers require an explicitly selected destination instead of guesses.
  def deployment_options(options, contents) do
    pattern =
      ~r/^SECRETS=\$\(kamal secrets fetch --adapter 1password --account ([A-Za-z0-9_.-]+) --from ([A-Za-z0-9_.-]+)\/([A-Za-z0-9_.-]+) [^\n]*\)$/m

    case Regex.scan(pattern, contents) do
      [[_, account, vault, item]] ->
        {:ok, Keyword.merge([account: account, vault: vault, item: item], options)}

      _ ->
        if Enum.all?([:account, :vault, :item], &Keyword.has_key?(options, &1)),
          do: {:ok, options},
          else:
            {:error,
             "Cannot infer the 1Password destination from .kamal/secrets. Supply --account, --vault, and --item explicitly and keep your deployment references aligned."}
    end
  end

  # The client and environment reader are injectable; tests never access a real
  # vault. Plans keep secret values out of Inspect and of the printable report.
  def prepare(manifest, options, dependencies \\ []) do
    client = Keyword.get(dependencies, :client, &Op.request/2)
    env = Keyword.get(dependencies, :env, &System.get_env/1)
    destination = destination(manifest[:app], options)

    # SQLite implies backup credentials even for a manifest created before the
    # automatic-backup rule. This is an in-memory plan, not a manifest rewrite.
    manifest =
      if Keyword.get(dependencies, :sqlite?, false),
        do: Keyword.update!(manifest, :features, &Keyword.put(&1, :backups, [])),
        else: manifest

    flags =
      if present?(env.("OP_SERVICE_ACCOUNT_TOKEN")),
        do: [],
        else: ["--account", destination.account]

    with :ok <- valid_destination(destination),
         {:ok, fields} <- select_fields(fields(manifest), options[:only]),
         {:ok, identity} <- client.(["whoami" | flags], nil),
         :ok <- verify_account(identity, destination.account),
         {:ok, vault} <- client.(["vault", "get", destination.vault] ++ flags, nil),
         {:ok, vault_id} <- object_id(vault),
         {:ok, current} <- find_item(client, flags, vault_id, destination.item),
         :ok <- editable_item(current),
         fields <- with_existing_markers(fields, current, options[:only]),
         {:ok, actions, imports} <- plan_fields(fields, current, env),
         :ok <- coherent_pairs(actions, current, env),
         imports <- retain_pair_proofs(actions, current, imports) do
      {:ok,
       %Plan{
         destination: destination,
         actions: actions,
         fields: fields,
         imports: imports,
         current: current,
         vault_id: vault_id,
         client: client,
         flags: flags
       }}
    end
  rescue
    _ -> {:error, "Could not prepare the secrets plan safely; no write was attempted"}
  end

  def format(%Plan{} = plan) do
    destination = plan.destination
    action = if plan.current, do: "Update existing item", else: "Create item"

    lines =
      Enum.map_join(plan.actions, "\n", fn {name, action} ->
        label =
          case action do
            :preserve -> "preserve existing value"
            :conceal -> "conceal existing value (unchanged)"
            :generate -> "generate securely"
            :import -> "import from environment"
            :missing -> "MISSING: supply through environment or the bootstrap item"
            :bootstrap -> "copy from the shared 1Password bootstrap item"
            :derive -> "derive from the Cloudflare account"
            :provision -> "issue a bucket-scoped credential in Cloudflare"
          end

        "  #{name}: #{label}"
      end)

    "#{action}: #{destination.account} / #{destination.vault} / #{destination.item}\n" <>
      lines <>
      "\nValues are never displayed. Repository and deployment references will not be modified."
  end

  def ready?(%Plan{actions: actions}), do: not Enum.any?(actions, &(elem(&1, 1) == :missing))
  def changed?(%Plan{actions: actions}), do: Enum.any?(actions, &(elem(&1, 1) != :preserve))

  def apply(%Plan{} = plan, generator \\ &generate_secret/0) do
    case save(plan, generator) do
      {:ok, _saved} -> {:ok, if(changed?(plan), do: :saved, else: :unchanged)}
      error -> error
    end
  end

  # Internal automation helpers retain the same identity, conflict, and read-back
  # checks as the standalone importer. Nothing here bypasses missing-only writes.
  def read_shared(plan, title) do
    with :ok <- valid_destination(%{item: title}),
         {:ok, item} <- find_item(plan.client, plan.flags, plan.vault_id, title),
         :ok <- editable_item(item),
         true <- is_nil(item) or is_nil(plan.current) or item["id"] != plan.current["id"] do
      {:ok, item}
    else
      false -> {:error, "The bootstrap item must be separate from the deployment item"}
      error -> error
    end
  end

  def field_value(item, name), do: field(item, name)
  def check_unchanged(plan), do: unchanged_since_preview(plan)

  def replan(plan, values) do
    with {:ok, actions, imports} <- plan_fields(plan.fields, plan.current, &Map.get(values, &1)),
         :ok <- coherent_pairs(actions, plan.current, &Map.get(values, &1)),
         imports <- retain_pair_proofs(actions, plan.current, imports) do
      {:ok, %{plan | actions: actions, imports: imports}}
    end
  end

  def save_values(plan, values, extra_fields \\ []) do
    fields = Enum.filter(plan.fields ++ extra_fields, &Map.has_key?(values, elem(&1, 0)))

    with {:ok, subset} <- replan(%{plan | fields: fields}, values),
         {:ok, saved} <- save(subset, &generate_secret/0) do
      {:ok, %{plan | current: saved.current}}
    end
  end

  def save(%Plan{} = plan, generator \\ &generate_secret/0) do
    cond do
      not ready?(plan) ->
        {:error,
         "Required imports are missing. Set the named environment variables, or use --only SECRET_KEY_BASE to generate just the Phoenix key. Nothing was written."}

      not changed?(plan) ->
        {:ok, plan}

      true ->
        with :ok <- unchanged_since_preview(plan),
             {:ok, payload} <- payload(plan, generator),
             {:ok, result} <- write_item(plan, payload),
             {:ok, id} <- object_id(result),
             true <- is_nil(plan.current) or id == plan.current["id"],
             {:ok, saved} <- get_item(plan.client, plan.flags, plan.vault_id, id),
             :ok <- verified(payload, saved) do
          {:ok, %{plan | current: saved}}
        else
          _ ->
            {:error,
             "Secrets were not confirmed saved. The item may have changed or the write/verification may have failed. Inspect it in 1Password before retrying; no existing credential was intentionally rotated."}
        end
    end
  rescue
    _ ->
      {:error,
       "Secrets operation failed; inspect the item in 1Password before retrying. Details were suppressed to protect credentials."}
  end

  defp generate_secret do
    {:ok, _} = Application.ensure_all_started(:crypto)
    :crypto.strong_rand_bytes(48) |> Base.encode64()
  end

  defp valid_destination(destination) do
    if Enum.all?(Map.values(destination), &(is_binary(&1) and Regex.match?(@identifier, &1))) do
      :ok
    else
      {:error,
       "Account, vault, and item must be literal identifiers containing letters, numbers, underscores, periods, or hyphens"}
    end
  end

  defp select_fields([], _),
    do: {:error, "No enabled feature requires credentials; run mix tamayotchi.setup first"}

  defp select_fields(fields, nil), do: {:ok, fields}

  defp select_fields(fields, only) do
    selected = String.split(only, ",", trim: true)
    names = Enum.map(fields, &elem(&1, 0))

    cond do
      selected == [] or Enum.any?(selected, &(&1 not in names)) ->
        {:error,
         "--only must name credential fields belonging to enabled features (comma-separated)"}

      Enum.any?(@pairs, fn pair -> Enum.count(pair, &(&1 in selected)) == 1 end) ->
        {:error,
         "Select both access-key fields together; credential pairs cannot be imported independently"}

      true ->
        {:ok, Enum.filter(fields, &(elem(&1, 0) in selected))}
    end
  end

  defp verify_account(%{"url" => url}, expected) when is_binary(url) do
    host = URI.parse(if String.contains?(url, "://"), do: url, else: "https://" <> url).host

    if host == expected,
      do: :ok,
      else:
        {:error,
         "The authenticated 1Password account does not match --account; choose the correct account before writing"}
  end

  defp verify_account(_, _), do: {:error, "Could not verify the authenticated 1Password account"}

  defp object_id(%{"id" => id}) when is_binary(id) do
    if Regex.match?(@id, id),
      do: {:ok, id},
      else: {:error, "1Password returned an invalid object ID"}
  end

  defp object_id(_), do: {:error, "1Password did not return an object ID"}

  defp find_item(client, flags, vault, target) do
    with {:ok, items} when is_list(items) <-
           client.(["item", "list", "--vault", vault] ++ flags, nil) do
      matches = Enum.filter(items, &(&1["title"] == target or &1["id"] == target))

      case matches do
        [] ->
          if Regex.match?(@id, target),
            do:
              {:error, "The requested item ID was not found; refusing to create a lookalike item"},
            else: {:ok, nil}

        [item] ->
          with {:ok, id} <- object_id(item), do: get_item(client, flags, vault, id)

        _ ->
          {:error,
           "Multiple 1Password items match this name; select an unambiguous item ID with --item"}
      end
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, "Could not list 1Password items safely"}
    end
  end

  defp get_item(client, flags, vault, id) do
    with {:ok, item} <- client.(["item", "get", id, "--vault", vault, "--reveal"] ++ flags, nil),
         ^id <- item["id"],
         ^vault <- get_in(item, ["vault", "id"]) do
      {:ok, item}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, "1Password returned an item outside the selected vault or ID"}
    end
  end

  defp editable_item(nil), do: :ok

  defp editable_item(item) do
    fields = item["fields"]

    if item["category"] in ["SECURE_NOTE", "PASSWORD", "API_CREDENTIAL", "SERVER"] and
         is_integer(item["version"]) and is_list(fields) and
         item["files"] in [nil, []] and item["passkeys"] in [nil, []] and
         Enum.all?(
           fields,
           &(is_map(&1) and is_binary(&1["id"]) and &1["id"] != "" and
               &1["type"] not in ["FILE", "SSHKEY", "PASSKEY"])
         ) and
         length(Enum.uniq_by(fields, & &1["id"])) == length(fields) do
      :ok
    else
      {:error,
       "Use a Secure Note, Password, API Credential, or Server item without attachments/passkeys and with unique, nonempty field IDs; unsafe JSON-template edits are refused"}
    end
  end

  defp with_existing_markers(fields, nil, _only), do: fields
  defp with_existing_markers(fields, _current, only) when not is_nil(only), do: fields

  defp with_existing_markers(fields, current, nil) do
    existing =
      Enum.filter(@markers, fn name ->
        Enum.any?(current["fields"], &(&1["label"] == name and present?(&1["value"])))
      end)

    fields ++ Enum.map(existing, &{&1, "CONCEALED"})
  end

  defp concealed?(current, name) do
    Enum.any?(current["fields"], &(&1["label"] == name and &1["type"] == "CONCEALED"))
  end

  defp plan_fields(fields, current, env) do
    Enum.reduce_while(fields, {:ok, [], %{}}, fn {name, _type}, {:ok, actions, imports} ->
      case field(current, name) do
        {:error, reason} ->
          {:halt, {:error, reason}}

        {:ok, existing} ->
          value = if present?(existing), do: nil, else: env.(name)

          action =
            cond do
              present?(existing) and not concealed?(current, name) -> :conceal
              present?(existing) -> :preserve
              present?(value) -> :import
              name == "SECRET_KEY_BASE" -> :generate
              true -> :missing
            end

          case if(action == :import, do: validate_value(name, value), else: :ok) do
            :ok ->
              {:cont,
               {:ok, actions ++ [{name, action}],
                if(action == :import, do: Map.put(imports, name, value), else: imports)}}

            error ->
              {:halt, error}
          end
      end
    end)
  end

  defp field(nil, _name), do: {:ok, nil}

  defp field(item, name) do
    case Enum.filter(item["fields"], &(&1["label"] == name)) do
      [] ->
        if Enum.any?(item["fields"], &(&1["id"] == field_id(name))),
          do:
            {:error,
             "A generated field ID conflicts with an existing field; reconcile the item manually"},
          else: {:ok, nil}

      [%{"type" => type, "value" => value}]
      when type in ["STRING", "CONCEALED"] and (is_binary(value) or is_nil(value)) ->
        {:ok, value}

      [%{"type" => type} = field]
      when type in ["STRING", "CONCEALED"] and not is_map_key(field, "value") ->
        {:ok, nil}

      _ ->
        {:error,
         "Ambiguous or unsupported credential fields in 1Password; reconcile duplicate labels/types manually"}
    end
  end

  defp coherent_pairs(actions, current, env) do
    Enum.reduce_while(@pairs, :ok, fn pair, :ok ->
      pair_actions = Enum.filter(actions, &(elem(&1, 0) in pair))

      if Enum.any?(pair_actions, &(elem(&1, 1) in [:preserve, :conceal])) and
           Enum.any?(pair_actions, &(elem(&1, 1) == :import)) do
        {name, _} = Enum.find(pair_actions, &(elem(&1, 1) in [:preserve, :conceal]))
        {:ok, existing} = field(current, name)

        if env.(name) == existing,
          do: {:cont, :ok},
          else:
            {:halt,
             {:error,
              "An existing access-key pair is incomplete. Supply both matching fields through the environment; rotation is not supported."}}
      else
        {:cont, :ok}
      end
    end)
  end

  # Replanning must retain the proof that the caller supplied the matching
  # existing half of a partial pair. It remains a preserve/conceal action, never
  # an overwrite, and is retained only AFTER coherent_pairs/3 validated it.
  defp retain_pair_proofs(actions, current, imports) do
    Enum.reduce(@pairs, imports, fn pair, values ->
      if Enum.any?(actions, fn {name, action} -> name in pair and action == :import end) do
        Enum.reduce(pair, values, fn name, values ->
          if Enum.any?(actions, &(&1 in [{name, :preserve}, {name, :conceal}])) do
            {:ok, existing} = field(current, name)
            Map.put(values, name, existing)
          else
            values
          end
        end)
      else
        values
      end
    end)
  end

  defp validate_value(name, value) do
    cond do
      byte_size(value) > 16_384 ->
        {:error, "An imported credential exceeds the supported field size"}

      name == "SECRET_KEY_BASE" and byte_size(value) < 64 ->
        {:error, "SECRET_KEY_BASE must contain at least 64 bytes"}

      name == "LITESTREAM_ENDPOINT" ->
        uri = URI.parse(value)

        if uri.scheme == "https" and is_binary(uri.host) and uri.host != "" and
             uri.path in [nil, "", "/"] and
             is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment),
           do: :ok,
           else:
             {:error,
              "LITESTREAM_ENDPOINT must be an HTTPS origin without credentials, path, query, or fragment"}

      true ->
        :ok
    end
  end

  defp unchanged_since_preview(%Plan{current: nil} = plan) do
    case find_item(plan.client, plan.flags, plan.vault_id, plan.destination.item) do
      {:ok, nil} -> :ok
      _ -> {:error, :changed}
    end
  end

  defp unchanged_since_preview(plan) do
    with {:ok, current} <- get_item(plan.client, plan.flags, plan.vault_id, plan.current["id"]),
         :ok <- editable_item(current),
         true <- Map.take(current, @metadata) == Map.take(plan.current, @metadata) do
      :ok
    else
      _ -> {:error, :changed}
    end
  end

  defp payload(plan, generator) do
    initial =
      if plan.current,
        do: Map.take(plan.current, @metadata),
        else: %{"title" => plan.destination.item, "category" => "SECURE_NOTE", "fields" => []}

    Enum.reduce_while(plan.actions, {:ok, initial}, fn
      {_name, :preserve}, acc ->
        {:cont, acc}

      {name, :conceal}, {:ok, payload} ->
        fields =
          Enum.map(payload["fields"], fn field ->
            if field["label"] == name, do: Map.put(field, "type", "CONCEALED"), else: field
          end)

        {:cont, {:ok, Map.put(payload, "fields", fields)}}

      {name, action}, {:ok, payload} ->
        value = if action == :generate, do: generator.(), else: Map.fetch!(plan.imports, name)

        case validate_value(name, value) do
          :ok ->
            type =
              Enum.find_value(plan.fields, fn {field, type} -> if field == name, do: type end)

            fields = payload["fields"]

            fields =
              if Enum.any?(fields, &(&1["label"] == name)) do
                Enum.map(fields, fn field ->
                  if field["label"] == name,
                    do: Map.merge(field, %{"value" => value, "type" => type}),
                    else: field
                end)
              else
                fields ++
                  [%{"id" => field_id(name), "label" => name, "type" => type, "value" => value}]
              end

            {:cont, {:ok, Map.put(payload, "fields", fields)}}

          error ->
            {:halt, error}
        end
    end)
  end

  defp write_item(plan, payload) do
    arguments =
      if plan.current, do: ["item", "edit", plan.current["id"]], else: ["item", "create", "-"]

    plan.client.(arguments ++ ["--vault", plan.vault_id, "--reveal"] ++ plan.flags, payload)
  end

  defp verified(payload, saved) do
    fields_ok? =
      Enum.all?(payload["fields"], fn expected ->
        case Enum.find(saved["fields"] || [], &(&1["id"] == expected["id"])) do
          nil -> false
          actual -> Map.take(actual, Map.keys(expected)) == expected
        end
      end)

    metadata = Map.take(payload, ~w(title category tags sections urls))

    if fields_ok? and Map.take(saved, Map.keys(metadata)) == metadata,
      do: :ok,
      else: {:error, :verification_failed}
  end

  defp field_id(name) do
    :crypto.hash(:sha256, "tamayotchi_stack:" <> name)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 26)
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
