defmodule TamayotchiStack.SecretsAutomationTest do
  use ExUnit.Case, async: true

  alias TamayotchiStack.Secrets.Automation

  @account String.duplicate("a", 32)
  @vault String.duplicate("v", 26)
  @item String.duplicate("i", 26)
  @bootstrap String.duplicate("b", 26)
  @permission String.duplicate("c", 32)
  @token String.duplicate("test-only-provider-token", 2)
  @registry "ghp_" <> String.duplicate("p", 36)
  @manifest [schema: 1, app: :my_app, features: [phoenix: [], kamal: [], r2: [], backups: []]]

  test "default preview is read-only; apply generates and saves every field with separate scoped keys" do
    {deps, state} = fixture()
    assert {:ok, plan} = Automation.prepare(@manifest, [], deps)
    assert Automation.ready?(plan)
    assert length(plan.jobs) == 2
    assert writes(state) == []
    output = Automation.format(plan) <> inspect(plan) <> inspect(plan.jobs)
    refute output =~ @token
    refute output =~ @registry
    assert output =~ "my-app-db-backups"
    assert output =~ "my-app"
    assert {:ok, :saved} = Automation.apply(plan)

    data = Agent.get(state, & &1)
    saved = data.item
    assert {:ok, bytes} = saved |> value("SECRET_KEY_BASE") |> Base.decode64()
    assert byte_size(bytes) == 48
    assert value(saved, "KAMAL_REGISTRY_PASSWORD") == @registry
    assert value(saved, "R2_ACCOUNT_ID") == @account
    assert value(saved, "LITESTREAM_ENDPOINT") == "https://#{@account}.r2.cloudflarestorage.com"
    assert value(saved, "R2_ACCESS_KEY_ID") != value(saved, "LITESTREAM_ACCESS_KEY_ID")
    assert value(saved, "R2_SECRET_ACCESS_KEY") != value(saved, "LITESTREAM_SECRET_ACCESS_KEY")
    assert value(saved, "CLOUDFLARE_API_TOKEN") == nil
    assert value(saved, "OP_SERVICE_ACCOUNT_TOKEN") == nil
    assert data.bootstrap == bootstrap()

    for {_, job} <- plan.jobs do
      issued = Enum.find(data.tokens, &(&1["name"] == job.name))
      assert [policy] = issued["policies"]

      assert policy["resources"] == %{
               "com.cloudflare.edge.r2.bucket.#{@account}_default_#{job.bucket}" => "*"
             }

      assert policy["permission_groups"] == [%{"id" => @permission}]
      field = if job.private?, do: "LITESTREAM_SECRET_ACCESS_KEY", else: "R2_SECRET_ACCESS_KEY"

      assert value(saved, field) ==
               Base.encode16(:crypto.hash(:sha256, issued["value"]), case: :lower)
    end

    # A durable marker is saved and verified before each cloud write. Each pair
    # is committed immediately, before issuing the next token.
    events = Enum.filter(data.events, fn {kind, _} -> kind in [:op_write, :cf_write] end)

    assert Enum.map(events, &elem(&1, 0)) == [
             :op_write,
             :op_write,
             :cf_write,
             :cf_write,
             :op_write,
             :op_write,
             :cf_write,
             :cf_write,
             :op_write
           ]

    assert {:op_write, first_marker} = Enum.at(events, 1)
    assert value(first_marker, "TAMAYOTCHI_R2_PROVISIONING")
    assert {:op_write, first_pair} = Enum.at(events, 4)
    assert value(first_pair, "R2_SECRET_ACCESS_KEY")
  end

  test "reruns preserve keys, notes, and metadata without bootstrap or Cloudflare access" do
    {deps, state} = fixture()
    {:ok, plan} = Automation.prepare(@manifest, [], deps)
    assert {:ok, :saved} = Automation.apply(plan)
    before = Agent.get(state, & &1.item)
    Agent.update(state, &%{&1 | events: [], bootstrap: nil})
    assert {:ok, rerun} = Automation.prepare(@manifest, [], deps)
    assert {:ok, :unchanged} = Automation.apply(rerun)
    assert Agent.get(state, & &1.item) == before
    assert writes(state) == []
    refute Enum.any?(Agent.get(state, & &1.events), &match?({:cf_read, _}, &1))
  end

  test "missing bootstrap inputs prevent all writes, while the Phoenix-only subset needs no bootstrap" do
    {deps, state} = fixture(bootstrap: nil)
    assert {:ok, plan} = Automation.prepare(@manifest, [], deps)
    refute Automation.ready?(plan)
    assert {:error, message} = Automation.apply(plan)
    assert message =~ "TAMAYOTCHI_BOOTSTRAP"
    assert writes(state) == []
    assert {:ok, partial} = Automation.prepare(@manifest, [only: "SECRET_KEY_BASE"], deps)
    assert {:ok, :saved} = Automation.apply(partial)
    assert length(Agent.get(state, & &1.item["fields"])) == 1
  end

  test "--no-provision bypasses bootstrap and cloud and accepts complete manual imports" do
    {deps, state} = fixture(bootstrap: nil)

    values = %{
      "KAMAL_REGISTRY_PASSWORD" => @registry,
      "R2_ACCOUNT_ID" => @account,
      "R2_ACCESS_KEY_ID" => "external-r2",
      "R2_SECRET_ACCESS_KEY" => "external-r2-secret",
      "LITESTREAM_ENDPOINT" => "https://s3.example.com",
      "LITESTREAM_ACCESS_KEY_ID" => "external-s3",
      "LITESTREAM_SECRET_ACCESS_KEY" => "external-s3-secret"
    }

    deps = Keyword.put(deps, :env, &Map.get(values, &1))
    assert {:ok, plan} = Automation.prepare(@manifest, [provision: false], deps)
    assert {:ok, :saved} = Automation.apply(plan)

    refute Enum.any?(Agent.get(state, & &1.events), fn {kind, _} ->
             kind in [:cf_read, :cf_write]
           end)
  end

  test "an incomplete existing or imported pair is never filled with an unrelated issued half" do
    for item <- [nil, item(%{"R2_ACCESS_KEY_ID" => "existing"})] do
      {deps, state} = fixture(item: item)

      deps =
        if item,
          do: deps,
          else:
            Keyword.put(deps, :env, fn
              "R2_ACCESS_KEY_ID" -> "imported"
              _ -> nil
            end)

      assert {:error, message} = Automation.prepare(@manifest, [], deps)
      assert message =~ "pair is incomplete"
      assert writes(state) == []
    end
  end

  test "automatic config never guesses the provider of existing keys" do
    {deps, state} =
      fixture(
        item:
          item(%{"R2_ACCESS_KEY_ID" => "existing", "R2_SECRET_ACCESS_KEY" => "existing-secret"})
      )

    assert {:error, message} = Automation.prepare(@manifest, [], deps)
    assert message =~ "will not guess"
    assert writes(state) == []
  end

  test "conflicting endpoints and nonliteral or invalid deployment buckets are refused" do
    for options <- [
          [
            deployment: "    R2_BUCKET: bad_bucket\n    LITESTREAM_BUCKET_NAME: private-backups\n"
          ],
          [deployment: "    R2_BUCKET: <%= ENV.fetch('BUCKET') %>\n"],
          [deployment: "    R2_BUCKET: first-bucket\n    R2_BUCKET: second-bucket\n"],
          [deployment: "    R2_BUCKET: my-app\n    R2_ENDPOINT: https://s3.example.com\n"]
        ] do
      {deps, state} = fixture()

      options =
        Keyword.update!(
          options,
          :deployment,
          &("registry:\n  server: ghcr.io\nenv:\n  clear:\n" <> &1)
        )

      assert {:error, _} = Automation.prepare(@manifest, options, deps)
      assert writes(state) == []
    end

    {deps, state} = fixture(item: item(%{"R2_ACCOUNT_ID" => String.duplicate("d", 32)}))
    assert {:error, message} = Automation.prepare(@manifest, [], deps)
    assert message =~ "differs from the bootstrap account"
    assert writes(state) == []
  end

  test "literal custom buckets are honored, but a public backup bucket is rejected" do
    options = [
      deployment:
        "registry:\n  server: ghcr.io\nenv:\n  clear:\n    R2_BUCKET: 'custom-storage'\n    LITESTREAM_BUCKET_NAME: custom-backups\n  secret:\n    - LITESTREAM_ENDPOINT\n"
    ]

    {deps, state} = fixture(buckets: MapSet.new(["custom-storage", "custom-backups"]))
    assert {:ok, plan} = Automation.prepare(@manifest, options, deps)
    assert Enum.all?(plan.jobs, fn {_, job} -> job.exists? end)

    assert Enum.map(plan.jobs, fn {_, job} -> job.bucket end) == [
             "custom-storage",
             "custom-backups"
           ]

    Agent.update(state, &%{&1 | public: true})
    assert {:error, message} = Automation.prepare(@manifest, options, deps)
    assert message =~ "privacy"
    assert writes(state) == []
  end

  test "known token names on later pages block issuance before any vault writes" do
    {deps, state} = fixture()
    {:ok, plan} = Automation.prepare(@manifest, [], deps)
    {_group, job} = hd(plan.jobs)
    others = Enum.map(1..50, &%{"name" => "unrelated-#{&1}"})
    Agent.update(state, &%{&1 | tokens: others ++ [%{"name" => job.name}]})
    assert {:error, message} = Automation.prepare(@manifest, [], deps)
    assert message =~ "already has a token"
    assert writes(state) == []
  end

  test "provider failure leaves a marker that prevents reissuance on rerun" do
    {deps, state} = fixture(fail: :cloud_after_create)
    {:ok, plan} = Automation.prepare(@manifest, [], deps)
    assert {:error, _} = Automation.apply(plan)
    saved = Agent.get(state, & &1.item)
    assert value(saved, "SECRET_KEY_BASE")
    assert value(saved, "TAMAYOTCHI_R2_PROVISIONING")
    assert value(saved, "R2_SECRET_ACCESS_KEY") == nil
    assert length(Agent.get(state, & &1.tokens)) == 1
    before = writes(state)
    assert {:error, message} = Automation.prepare(@manifest, [], deps)
    assert message =~ "provisioning marker"
    assert writes(state) == before
  end

  test "vault pair-save failure retains the marker and never retries or revokes the cloud token" do
    {deps, state} = fixture(fail: :pair_save)
    {:ok, plan} = Automation.prepare(@manifest, [], deps)
    assert {:error, _} = Automation.apply(plan)
    assert length(Agent.get(state, & &1.tokens)) == 1
    assert value(Agent.get(state, & &1.item), "TAMAYOTCHI_R2_PROVISIONING")
    assert {:error, message} = Automation.prepare(@manifest, [], deps)
    assert message =~ "provisioning marker"
  end

  test "a changed item after preview prevents both vault and provider writes" do
    {deps, state} = fixture(item: item(%{}))
    {:ok, plan} = Automation.prepare(@manifest, [], deps)
    Agent.update(state, &put_in(&1, [:item, "version"], 2))
    assert {:error, _} = Automation.apply(plan)
    assert writes(state) == []
  end

  test "item ID aliases use the same deterministic provisioning names" do
    {deps, _state} = fixture(item: item(%{}))
    {:ok, by_title} = Automation.prepare(@manifest, [], deps)
    {:ok, by_id} = Automation.prepare(@manifest, [item: @item], deps)

    assert Enum.map(by_title.jobs, fn {_, job} -> job.name end) ==
             Enum.map(by_id.jobs, fn {_, job} -> job.name end)
  end

  test "registry-only setup does not require Cloudflare bootstrap fields" do
    shared =
      item(%{"KAMAL_REGISTRY_PASSWORD" => @registry})
      |> Map.merge(%{"id" => @bootstrap, "title" => "TAMAYOTCHI_BOOTSTRAP"})

    {deps, state} = fixture(bootstrap: shared)
    manifest = Keyword.put(@manifest, :features, phoenix: [], kamal: [])
    assert {:ok, plan} = Automation.prepare(manifest, [], deps)
    assert {:ok, :saved} = Automation.apply(plan)
    assert length(Agent.get(state, & &1.item["fields"])) == 2
    refute Enum.any?(writes(state), &match?({:cf_write, _}, &1))
  end

  test "backups cannot share the application object-storage bucket" do
    {deps, state} = fixture()

    options = [
      deployment:
        "registry:\n  server: ghcr.io\nenv:\n  clear:\n    R2_BUCKET: shared-bucket\n    LITESTREAM_BUCKET_NAME: shared-bucket\n"
    ]

    assert {:error, message} = Automation.prepare(@manifest, options, deps)
    assert message =~ "separate private bucket"
    assert writes(state) == []
  end

  test "a returned token with widened scope is not saved as a deployment credential" do
    {deps, state} = fixture(fail: :wide_scope)
    {:ok, plan} = Automation.prepare(@manifest, [], deps)
    assert {:error, _} = Automation.apply(plan)
    assert value(Agent.get(state, & &1.item), "R2_SECRET_ACCESS_KEY") == nil
    assert value(Agent.get(state, & &1.item), "TAMAYOTCHI_R2_PROVISIONING")
    assert length(Agent.get(state, & &1.tokens)) == 1
  end

  test "shared GHCR credentials are not copied to legacy or ambiguous registries" do
    manifest = Keyword.put(@manifest, :features, phoenix: [], kamal: [])

    for deployment <- [
          "registry:\n  username: tamayotchi\n",
          "registry:\n  server: registry.example.com\n",
          "registry:\n  server: ghcr.io\n  server: registry.example.com\n",
          "registry:\n  server: <%= ENV.fetch(\"REGISTRY\") %>\n"
        ] do
      {deps, state} = fixture()
      assert {:error, _} = Automation.prepare(manifest, [deployment: deployment], deps)
      assert writes(state) == []
    end
  end

  test "GHCR bootstrap requires a classic PAT, not gh OAuth or other provider tokens" do
    manifest = Keyword.put(@manifest, :features, phoenix: [], kamal: [])

    for token <- ["gho_" <> String.duplicate("x", 36), "github_pat_test", "docker-token"] do
      shared =
        item(%{"KAMAL_REGISTRY_PASSWORD" => token})
        |> Map.merge(%{"id" => @bootstrap, "title" => "TAMAYOTCHI_BOOTSTRAP"})

      {deps, state} = fixture(bootstrap: shared)
      assert {:error, message} = Automation.prepare(manifest, [], deps)
      assert message =~ "classic PAT"
      refute message =~ token
      assert writes(state) == []
    end
  end

  test "literal GHCR registry settings permit automatic package credential reuse" do
    {deps, state} = fixture()
    manifest = Keyword.put(@manifest, :features, phoenix: [], kamal: [])

    assert {:ok, plan} =
             Automation.prepare(
               manifest,
               [deployment: "registry:\n  server: 'ghcr.io' # keep\n  username: tamayotchi\n"],
               deps
             )

    assert {:ok, :saved} = Automation.apply(plan)
    assert value(Agent.get(state, & &1.item), "KAMAL_REGISTRY_PASSWORD") == @registry
  end

  test "matching partial-pair imports survive all automation replans, including manual mode" do
    for provision? <- [true, false] do
      existing = item(%{"R2_ACCESS_KEY_ID" => "existing-test-id"})
      {deps, state} = fixture(item: existing)

      deps =
        Keyword.put(
          deps,
          :env,
          &Map.get(
            %{
              "R2_ACCESS_KEY_ID" => "existing-test-id",
              "R2_SECRET_ACCESS_KEY" => "matching-test-secret"
            },
            &1
          )
        )

      assert {:ok, plan} =
               Automation.prepare(
                 @manifest,
                 [only: "R2_ACCESS_KEY_ID,R2_SECRET_ACCESS_KEY", provision: provision?],
                 deps
               )

      assert {:ok, :saved} = Automation.apply(plan)
      saved = Agent.get(state, & &1.item)
      assert value(saved, "R2_ACCESS_KEY_ID") == "existing-test-id"
      assert value(saved, "R2_SECRET_ACCESS_KEY") == "matching-test-secret"
      assert Enum.all?(writes(state), &(elem(&1, 0) == :op_write))
    end
  end

  test "bootstrap destination is reserved even for partial/manual setup before it exists" do
    {deps, state} = fixture(bootstrap: nil)

    assert {:error, message} =
             Automation.prepare(
               @manifest,
               [item: "TAMAYOTCHI_BOOTSTRAP", only: "SECRET_KEY_BASE", provision: false],
               deps
             )

    assert message =~ "separate"
    assert writes(state) == []
  end

  test "ambiguous YAML cannot change the actual provisioning destination" do
    registry = "registry:\n  server: ghcr.io\n"

    clear =
      "env:\n  clear:\n    R2_BUCKET: custom-storage\n    LITESTREAM_BUCKET_NAME: custom-backups\n"

    for deployment <- [
          registry <> clear <> "    'R2_BUCKET': other-storage\n",
          registry <> clear <> "'env': {clear: {R2_BUCKET: other-storage}}\n",
          registry <> clear <> "  'clear': {R2_BUCKET: other-storage}\n",
          registry <> clear <> "'registry': {server: other.example.com}\n",
          registry <> "  'server': other.example.com\n" <> clear,
          registry <> String.replace(clear, "custom-storage", "0123"),
          registry <> String.replace(clear, "custom-storage", "null"),
          registry <> String.replace(clear, "custom-storage", "2026-09-09"),
          registry <> clear <> "    'R2_ENDPOINT': https://other.example.com\n",
          registry <> clear <> "...\n"
        ] do
      {deps, state} = fixture()
      assert {:error, _} = Automation.prepare(@manifest, [deployment: deployment], deps)
      assert writes(state) == []
    end
  end

  test "explicitly quoted numeric bucket names remain strings" do
    {deps, _} = fixture()

    deployment =
      "registry:\n  server: ghcr.io\nenv:\n  clear:\n    R2_BUCKET: '0123' # intentionally a string\n    LITESTREAM_BUCKET_NAME: custom-backups\n"

    assert {:ok, plan} = Automation.prepare(@manifest, [deployment: deployment], deps)
    assert Automation.ready?(plan)
  end

  test "bootstrap and deployment cannot be the same item" do
    {deps, state} = fixture(item: item(%{}))
    assert {:error, message} = Automation.prepare(@manifest, [bootstrap_item: "MY_APP"], deps)
    assert message =~ "must be separate"
    assert writes(state) == []
  end

  defp fixture(options \\ []) do
    initial =
      Map.merge(
        %{
          item: nil,
          bootstrap: bootstrap(),
          buckets: MapSet.new(),
          tokens: [],
          events: [],
          public: false,
          fail: nil
        },
        Map.new(options)
      )

    state = start_supervised!({Agent, fn -> initial end}, id: make_ref())
    op = fn args, input -> Agent.get_and_update(state, &op(&1, args, input)) end

    cf = fn method, path, token, body ->
      assert token == @token
      assert String.starts_with?(path, "/accounts/#{@account}/")
      Agent.get_and_update(state, &cloud(&1, method, path, body))
    end

    {[client: op, cloudflare: cf, env: fn _ -> nil end], state}
  end

  defp op(data, ["whoami" | _], _), do: {{:ok, %{"url" => "instaleap-llc.1password.com"}}, data}
  defp op(data, ["vault", "get" | _], _), do: {{:ok, %{"id" => @vault}}, data}

  defp op(data, ["item", "list" | _], _),
    do: {{:ok, Enum.reject([data.item, data.bootstrap], &is_nil/1)}, data}

  defp op(data, ["item", "get", id | _], _) do
    result = Enum.find([data.item, data.bootstrap], &(&1 && &1["id"] == id))
    {{:ok, result}, data}
  end

  defp op(data, ["item", action | _], payload) when action in ["create", "edit"] do
    data = %{data | events: data.events ++ [{:op_write, payload}]}

    if data.fail == :pair_save and value(payload, "R2_SECRET_ACCESS_KEY") do
      {{:error, "synthetic vault write failure"}, data}
    else
      saved =
        Map.merge(payload, %{
          "id" => @item,
          "vault" => %{"id" => @vault},
          "version" => if(data.item, do: data.item["version"] + 1, else: 1)
        })

      {{:ok, saved}, %{data | item: saved}}
    end
  end

  defp cloud(data, method, path, body) do
    data = %{
      data
      | events: data.events ++ [{if(method == :get, do: :cf_read, else: :cf_write), {path, body}}]
    }

    suffix = String.replace_prefix(path, "/accounts/#{@account}", "")

    cond do
      String.starts_with?(suffix, "/tokens/permission_groups?") ->
        {ok([
           %{
             "id" => @permission,
             "name" => "Workers R2 Storage Bucket Item Write",
             "scopes" => ["com.cloudflare.edge.r2.bucket"]
           }
         ]), data}

      String.starts_with?(suffix, "/tokens?") ->
        page = URI.decode_query(URI.parse(suffix).query)["page"] |> String.to_integer()

        {ok(Enum.slice(data.tokens, (page - 1) * 50, 50), %{"total_count" => length(data.tokens)}),
         data}

      suffix == "/tokens" and method == :post ->
        token =
          Map.merge(body, %{
            "id" => Integer.to_string(length(data.tokens) + 1, 16) |> String.pad_leading(32, "0"),
            "value" =>
              "test-only-issued-" <>
                String.pad_leading(Integer.to_string(length(data.tokens) + 1), 40, "x"),
            "status" => "active"
          })

        token =
          if data.fail == :wide_scope,
            do:
              put_in(token, ["policies", Access.at(0), "resources"], %{
                "com.cloudflare.api.account.*" => "*"
              }),
            else: token

        data = %{data | tokens: data.tokens ++ [token]}

        if data.fail == :cloud_after_create,
          do: {{:error, "synthetic lost response"}, data},
          else: {ok(token), data}

      suffix == "/r2/buckets" and method == :post ->
        {ok(body), %{data | buckets: MapSet.put(data.buckets, body["name"])}}

      String.ends_with?(suffix, "/domains/managed") ->
        {ok(%{"enabled" => data.public}), data}

      String.ends_with?(suffix, "/domains/custom") ->
        {ok(%{"domains" => []}), data}

      true ->
        bucket = String.replace_prefix(suffix, "/r2/buckets/", "")

        if MapSet.member?(data.buckets, bucket),
          do: {ok(%{"name" => bucket, "jurisdiction" => "default"}), data},
          else: {{:error, :not_found}, data}
    end
  end

  defp ok(result, info \\ %{}),
    do: {:ok, %{"result" => result, "success" => true, "result_info" => info}}

  defp writes(state),
    do:
      Agent.get(
        state,
        &Enum.filter(&1.events, fn {kind, _} -> kind in [:op_write, :cf_write] end)
      )

  defp value(item, name),
    do:
      item["fields"]
      |> Enum.find_value(fn field -> if field["label"] == name, do: field["value"] end)

  defp item(values) do
    fields =
      Enum.map(values, fn {name, value} ->
        %{"id" => name, "label" => name, "value" => value, "type" => "CONCEALED"}
      end)

    %{
      "id" => @item,
      "vault" => %{"id" => @vault},
      "version" => 1,
      "category" => "SECURE_NOTE",
      "title" => "MY_APP",
      "fields" => fields,
      "tags" => ["keep"],
      "sections" => [],
      "urls" => []
    }
  end

  defp bootstrap do
    item(%{
      "CLOUDFLARE_ACCOUNT_ID" => @account,
      "CLOUDFLARE_API_TOKEN" => @token,
      "KAMAL_REGISTRY_PASSWORD" => @registry
    })
    |> Map.merge(%{"id" => @bootstrap, "title" => "TAMAYOTCHI_BOOTSTRAP"})
  end
end
