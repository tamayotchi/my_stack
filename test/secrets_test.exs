defmodule TamayotchiStack.SecretsTest do
  use ExUnit.Case, async: true

  alias TamayotchiStack.Secrets

  @vault String.duplicate("v", 26)
  @item String.duplicate("i", 26)
  @account "instaleap-llc.1password.com"
  @key String.duplicate("test-key", 8)
  @manifest [schema: 1, app: :sample, features: [phoenix: [], kamal: [], r2: [], backups: []]]

  test "plans only enabled features and hides all credential values" do
    {client, state} = client()

    assert {:ok, plan} =
             Secrets.prepare(@manifest, [], client: client, env: environment(imports()))

    assert Secrets.ready?(plan)
    assert {"SECRET_KEY_BASE", :generate} in plan.actions
    assert length(plan.actions) == 8
    assert Secrets.format(plan) =~ "SERVER / SAMPLE"
    assert Secrets.format(plan) =~ "import from environment"

    for secret <- Map.values(imports()) do
      refute Secrets.format(plan) =~ secret
      refute inspect(plan) =~ secret
    end

    refute wrote?(state)

    assert Secrets.fields(features: [r2: []]) == [
             {"R2_ACCOUNT_ID", "CONCEALED"},
             {"R2_ACCESS_KEY_ID", "CONCEALED"},
             {"R2_SECRET_ACCESS_KEY", "CONCEALED"}
           ]

    assert {:error, _} = Secrets.prepare([app: :sample, features: []], [], client: client)
  end

  test "SQLite always requires backup credentials even when an older manifest omitted backups" do
    {client, _state} = client()
    manifest = [schema: 1, app: :sample, features: [phoenix: []]]

    assert {:ok, plan} =
             Secrets.prepare(manifest, [],
               client: client,
               env: environment(imports()),
               sqlite?: true
             )

    assert {"LITESTREAM_ACCESS_KEY_ID", :import} in plan.actions
    assert {"LITESTREAM_SECRET_ACCESS_KEY", :import} in plan.actions
    assert {"LITESTREAM_ENDPOINT", :import} in plan.actions
    assert length(plan.actions) == 4

    assert {:ok, no_sqlite} =
             Secrets.prepare(manifest, [],
               client: client,
               env: environment(imports()),
               sqlite?: false
             )

    assert no_sqlite.actions == [{"SECRET_KEY_BASE", :generate}]
  end

  test "generates a Phoenix key, imports others, and uses stdin payloads" do
    {client, state} = client()
    {:ok, plan} = Secrets.prepare(@manifest, [], client: client, env: environment(imports()))
    assert {:ok, :saved} = Secrets.apply(plan)
    saved = Agent.get(state, & &1.item)
    key = value(saved, "SECRET_KEY_BASE")
    assert {:ok, bytes} = Base.decode64(key)
    assert byte_size(bytes) == 48
    assert value(saved, "R2_SECRET_ACCESS_KEY") == imports()["R2_SECRET_ACCESS_KEY"]
    assert saved["category"] == "SECURE_NOTE"
    assert saved["title"] == "SAMPLE"
    assert Enum.all?(saved["fields"], &(&1["type"] == "CONCEALED"))

    for {args, _input} <- Agent.get(state, & &1.requests) do
      refute Enum.any?(args, &String.contains?(&1, key))
      refute Enum.any?(args, &String.contains?(&1, imports()["R2_SECRET_ACCESS_KEY"]))
    end

    assert Enum.any?(Agent.get(state, & &1.requests), fn
             {["item", "create", "-" | _], %{"fields" => fields}} -> length(fields) == 8
             _ -> false
           end)
  end

  test "a second run preserves existing credentials even with different environment values" do
    {client, state} = client()
    deps = [client: client, env: environment(imports())]
    {:ok, first} = Secrets.prepare(@manifest, [], deps)
    assert {:ok, :saved} = Secrets.apply(first, fn -> @key end)
    before = Agent.get(state, & &1.item)

    {:ok, second} =
      Secrets.prepare(@manifest, [],
        client: client,
        env: environment(Map.put(imports(), "SECRET_KEY_BASE", "wrong"))
      )

    refute Secrets.changed?(second)

    assert {:ok, :unchanged} =
             Secrets.apply(second, fn -> flunk("must not generate on rerun") end)

    assert Agent.get(state, & &1.item) == before
    assert write_count(state) == 1
  end

  test "preserves unrelated fields, notes, sections, tags, URLs, and existing field IDs" do
    original = existing_item()
    {client, state} = client(original)

    {:ok, plan} =
      Secrets.prepare(@manifest, [only: "SECRET_KEY_BASE"], client: client, env: environment(%{}))

    assert {:ok, :saved} = Secrets.apply(plan, fn -> @key end)
    saved = Agent.get(state, & &1.item)
    assert Enum.take(saved["fields"], length(original["fields"])) == original["fields"]
    for key <- ~w(tags sections urls title category), do: assert(saved[key] == original[key])

    assert Enum.any?(Agent.get(state, & &1.requests), fn
             {["item", "edit", @item | _], %{}} -> true
             _ -> false
           end)
  end

  test "legacy visible fields and markers are concealed without rotating values or metadata" do
    {client, state} = client()
    deps = [client: client, env: environment(imports())]
    {:ok, initial} = Secrets.prepare(@manifest, [], deps)
    assert {:ok, :saved} = Secrets.apply(initial, fn -> @key end)

    marker = %{
      "id" => "legacy_marker",
      "label" => "TAMAYOTCHI_R2_PROVISIONING",
      "value" => "test-only-provisioning-name",
      "type" => "STRING"
    }

    Agent.update(state, fn state ->
      put_in(
        state.item["fields"],
        Enum.map(state.item["fields"], &Map.put(&1, "type", "STRING")) ++ [marker]
      )
    end)

    before = Agent.get(state, & &1.item)
    {:ok, plan} = Secrets.prepare(@manifest, [], deps)
    assert Enum.all?(plan.actions, &(elem(&1, 1) == :conceal))
    assert Secrets.format(plan) =~ "conceal existing value (unchanged)"
    assert {:ok, :saved} = Secrets.apply(plan, fn -> flunk("must never rotate") end)
    after_save = Agent.get(state, & &1.item)
    assert Enum.all?(after_save["fields"], &(&1["type"] == "CONCEALED"))

    assert Enum.map(before["fields"], &Map.delete(&1, "type")) ==
             Enum.map(after_save["fields"], &Map.delete(&1, "type"))

    {:ok, unchanged} = Secrets.prepare(@manifest, [], deps)
    refute Secrets.changed?(unchanged)
  end

  test "missing imports block all writes, while --only supports a deliberate partial setup" do
    {client, state} = client()
    {:ok, plan} = Secrets.prepare(@manifest, [], client: client, env: environment(%{}))
    refute Secrets.ready?(plan)
    assert Secrets.format(plan) =~ "MISSING"
    assert {:error, _} = Secrets.apply(plan, fn -> flunk("must preflight before generation") end)
    refute wrote?(state)

    {:ok, partial} =
      Secrets.prepare(@manifest, [only: "SECRET_KEY_BASE"], client: client, env: environment(%{}))

    assert {:ok, :saved} = Secrets.apply(partial, fn -> @key end)
    assert length(Agent.get(state, & &1.item["fields"])) == 1
  end

  test "imports an existing SECRET_KEY_BASE instead of generating another" do
    {client, state} = client()

    {:ok, plan} =
      Secrets.prepare(@manifest, [only: "SECRET_KEY_BASE"],
        client: client,
        env: environment(%{"SECRET_KEY_BASE" => @key})
      )

    assert {:ok, :saved} = Secrets.apply(plan, fn -> flunk("must import") end)
    assert value(Agent.get(state, & &1.item), "SECRET_KEY_BASE") == @key
  end

  test "validates imported values without including them in errors" do
    {client, state} = client()

    for {name, secret} <- [
          {"SECRET_KEY_BASE", "too-short-private"},
          {"LITESTREAM_ENDPOINT", "https://user:private@example.test"}
        ] do
      assert {:error, reason} =
               Secrets.prepare(@manifest, [only: name],
                 client: client,
                 env: environment(%{name => secret})
               )

      refute reason =~ secret
    end

    refute wrote?(state)
  end

  test "rejects duplicate names, duplicate fields, attachments, and passkey-bearing categories" do
    {client, state} = client(existing_item())
    Agent.update(state, &Map.put(&1, :duplicate, true))

    assert {:error, reason} =
             Secrets.prepare(@manifest, [], client: client, env: environment(imports()))

    assert reason =~ "Multiple 1Password items"

    assert {:ok, _} =
             Secrets.prepare(@manifest, [item: @item],
               client: client,
               env: environment(imports())
             )

    refute wrote?(state)

    for item <- [
          Map.put(existing_item(), "category", "LOGIN"),
          Map.put(existing_item(), "files", [%{"id" => "attachment"}]),
          Map.put(existing_item(), "fields", [
            %{"label" => "SECRET_KEY_BASE", "value" => @key},
            %{"label" => "SECRET_KEY_BASE", "value" => @key}
          ])
        ] do
      {client, state} = client(item)

      assert {:error, _} =
               Secrets.prepare(@manifest, [], client: client, env: environment(imports()))

      refute wrote?(state)
    end
  end

  test "duplicate field IDs are rejected before edits, including unrelated fields" do
    current = existing_item()
    [first | _] = current["fields"]
    current = Map.update!(current, "fields", &(&1 ++ [Map.put(first, "label", "another-field")]))
    {client, state} = client(current)

    assert {:error, _} =
             Secrets.prepare(@manifest, [], client: client, env: environment(imports()))

    refute wrote?(state)
  end

  test "a missing explicit ID cannot become a newly created item title" do
    {client, state} = client()

    assert {:error, _} =
             Secrets.prepare(@manifest, [item: @item],
               client: client,
               env: environment(imports())
             )

    refute wrote?(state)
  end

  test "partial credential pairs require a matching existing companion" do
    item =
      Map.put(existing_item(), "fields", [
        %{
          "id" => "old_key",
          "label" => "R2_ACCESS_KEY_ID",
          "type" => "STRING",
          "value" => "existing-id"
        }
      ])

    {client, _state} = client(item)

    assert {:error, reason} =
             Secrets.prepare(@manifest, [only: "R2_ACCESS_KEY_ID,R2_SECRET_ACCESS_KEY"],
               client: client,
               env: environment(imports())
             )

    assert reason =~ "pair is incomplete"
    values = Map.put(imports(), "R2_ACCESS_KEY_ID", "existing-id")

    assert {:ok, plan} =
             Secrets.prepare(@manifest, [only: "R2_ACCESS_KEY_ID,R2_SECRET_ACCESS_KEY"],
               client: client,
               env: environment(values)
             )

    assert {:ok, :saved} = Secrets.apply(plan)

    assert {:error, _} =
             Secrets.prepare(@manifest, [only: "R2_SECRET_ACCESS_KEY"],
               client: client,
               env: environment(values)
             )
  end

  test "changes made after the preview cause an abort, without generating or overwriting" do
    for current <- [nil, existing_item()] do
      {client, state} = client(current)

      {:ok, plan} =
        Secrets.prepare(@manifest, [only: "SECRET_KEY_BASE"],
          client: client,
          env: environment(%{})
        )

      Agent.update(state, &Map.put(&1, :item, Map.put(existing_item(), "version", 99)))
      assert {:error, _} = Secrets.apply(plan, fn -> flunk("concurrent change must abort") end)
      refute wrote?(state)
    end
  end

  test "write and verification failures are reported without raw provider data or retries" do
    for failure <- [:write, :verify] do
      {client, state} = client()

      {:ok, plan} =
        Secrets.prepare(@manifest, [only: "SECRET_KEY_BASE"],
          client: client,
          env: environment(%{})
        )

      Agent.update(state, &Map.put(&1, :failure, failure))
      assert {:error, reason} = Secrets.apply(plan, fn -> @key end)
      refute reason =~ @key
      assert reason =~ "Inspect it in 1Password"
      assert write_count(state) == 1
    end
  end

  test "service accounts omit the CLI account selector but still verify account identity" do
    {client, state} = client()
    values = Map.put(imports(), "OP_SERVICE_ACCOUNT_TOKEN", "test-service-account")
    assert {:ok, _} = Secrets.prepare(@manifest, [], client: client, env: environment(values))

    assert Enum.all?(Agent.get(state, & &1.requests), fn {args, _} ->
             "--account" not in args and "test-service-account" not in args
           end)

    Agent.update(state, &Map.put(&1, :account, "wrong.1password.com"))

    assert {:error, reason} =
             Secrets.prepare(@manifest, [], client: client, env: environment(values))

    assert reason =~ "does not match"
    refute wrote?(state)
  end

  test "reads literal deployment references without executing shell, and supports explicit overrides" do
    contents =
      "SECRETS=$(kamal secrets fetch --adapter 1password --account other.1password.com --from PROD/DEMO KAMAL_REGISTRY_PASSWORD SECRET_KEY_BASE)\n"

    assert {:ok, [account: "other.1password.com", vault: "PROD", item: "DEMO"]} =
             Secrets.deployment_options([], contents)

    assert {:ok, options} = Secrets.deployment_options([vault: "OVERRIDE"], contents)
    assert options[:vault] == "OVERRIDE"
    assert {:error, _} = Secrets.deployment_options([], "SECRETS=$(something-else)\n")

    assert {:ok, _} =
             Secrets.deployment_options(
               [account: @account, vault: "SERVER", item: "SAMPLE"],
               "custom"
             )
  end

  defp imports do
    %{
      "KAMAL_REGISTRY_PASSWORD" => "test-registry-token",
      "R2_ACCOUNT_ID" => "test-account-id",
      "R2_ACCESS_KEY_ID" => "test-storage-id",
      "R2_SECRET_ACCESS_KEY" => "test-storage-secret",
      "LITESTREAM_ENDPOINT" => "https://test-backups.example.test",
      "LITESTREAM_ACCESS_KEY_ID" => "test-backup-id",
      "LITESTREAM_SECRET_ACCESS_KEY" => "test-backup-secret"
    }
  end

  defp existing_item do
    %{
      "id" => @item,
      "vault" => %{"id" => @vault},
      "title" => "SAMPLE",
      "version" => 1,
      "category" => "SECURE_NOTE",
      "tags" => ["custom"],
      "sections" => [%{"id" => "section", "label" => "Notes"}],
      "urls" => [%{"href" => "https://example.test", "primary" => true}],
      "fields" => [
        %{
          "id" => "notesPlain",
          "type" => "STRING",
          "label" => "notesPlain",
          "value" => "preserve these notes"
        }
      ]
    }
  end

  defp environment(values), do: &Map.get(values, &1)
  defp value(item, name), do: Enum.find(item["fields"], &(&1["label"] == name))["value"]
  defp wrote?(state), do: write_count(state) > 0

  defp write_count(state),
    do:
      Agent.get(
        state,
        &Enum.count(&1.requests, fn {args, _} ->
          Enum.take(args, 2) in [["item", "create"], ["item", "edit"]]
        end)
      )

  defp client(item \\ nil) do
    {:ok, state} =
      Agent.start_link(fn ->
        %{item: item, requests: [], account: @account, failure: nil, writes: 0, duplicate: false}
      end)

    on_exit(fn -> if Process.alive?(state), do: Agent.stop(state) end)

    client = fn args, input ->
      Agent.get_and_update(state, fn state ->
        state = %{state | requests: state.requests ++ [{args, input}]}

        case args do
          ["whoami" | _] ->
            {{:ok, %{"url" => state.account}}, state}

          ["vault", "get" | _] ->
            {{:ok, %{"id" => @vault}}, state}

          ["item", "list" | _] ->
            items = if state.item, do: [Map.take(state.item, ~w(id title))], else: []

            items =
              if state.duplicate,
                do: items ++ [%{"id" => String.duplicate("j", 26), "title" => "SAMPLE"}],
                else: items

            {{:ok, items}, state}

          ["item", "get", _id | _] ->
            result =
              if state.failure == :verify and state.writes > 0,
                do: {:error, "private-response"},
                else: {:ok, state.item}

            {result, state}

          ["item", operation | _] when operation in ["create", "edit"] ->
            if state.failure == :write do
              {{:error, "private-response"}, %{state | writes: state.writes + 1}}
            else
              saved =
                Map.merge(input, %{
                  "id" => @item,
                  "vault" => %{"id" => @vault},
                  "version" => state.writes + 2
                })

              {{:ok, saved}, %{state | item: saved, writes: state.writes + 1}}
            end
        end
      end)
    end

    {client, state}
  end
end
