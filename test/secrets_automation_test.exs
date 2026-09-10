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
  @goat_url "https://parent.goatcounter.com"
  @goat_token String.duplicate("goat-test-token", 4)
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

  test "reruns preserve keys and metadata, rechecking GoatCounter without Cloudflare access" do
    {deps, state} = fixture()
    {:ok, plan} = Automation.prepare(@manifest, [], deps)
    assert {:ok, :saved} = Automation.apply(plan)
    before = Agent.get(state, & &1.item)
    Agent.update(state, &%{&1 | events: []})
    assert {:ok, rerun} = Automation.prepare(@manifest, [], deps)
    assert {:ok, :unchanged} = Automation.apply(rerun)
    assert Agent.get(state, & &1.item) == before
    assert writes(state) == []
    refute Enum.any?(Agent.get(state, & &1.events), &match?({:cf_read, _}, &1))
    assert Enum.any?(Agent.get(state, & &1.events), &match?({:goat_read, _}, &1))
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
    assert {:ok, plan} = Automation.prepare(manifest, [only: "KAMAL_REGISTRY_PASSWORD"], deps)
    assert {:ok, :saved} = Automation.apply(plan)
    assert length(Agent.get(state, & &1.item["fields"])) == 1
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
               [
                 deployment:
                   "registry:\n  server: 'ghcr.io' # keep\n  username: tamayotchi\nenv:\n  clear:\n    PHX_HOST: my-app.example.com\n"
               ],
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

  test "GoatCounter creation uses a concealed checkpoint and never copies its bootstrap token" do
    {deps, state} = fixture(goat_sites: [goat_parent()])
    assert {:ok, plan} = Automation.prepare(@manifest, [], deps)
    assert Automation.ready?(plan)
    refute plan.goatcounter.exists?
    assert writes(state) == []
    refute Automation.format(plan) <> inspect(plan.goatcounter) =~ @goat_token
    assert {:ok, :saved} = Automation.apply(plan)
    data = Agent.get(state, & &1)
    assert value(data.item, "TAMAYOTCHI_GOATCOUNTER_PROVISIONING") == @goat_url <> "/my-app"
    assert value(data.item, "GOATCOUNTER_API_TOKEN") == nil
    assert value(data.item, "GOATCOUNTER_SITE_URL") == nil
    assert data.bootstrap == bootstrap()
    assert Enum.all?(data.item["fields"], &(&1["type"] == "CONCEALED"))
    assert List.last(data.goat_sites)["link_domain"] == "https://my-app.tamayotchi.com"
    index = Enum.find_index(data.events, &match?({:goat_write, _}, &1))

    assert Enum.any?(Enum.take(data.events, index), fn
             {:op_write, payload} -> value(payload, "TAMAYOTCHI_GOATCOUNTER_PROVISIONING")
             _ -> false
           end)

    before = data.item
    Agent.update(state, &%{&1 | events: []})
    assert {:ok, rerun} = Automation.prepare(@manifest, [], deps)
    assert {:ok, :unchanged} = Automation.apply(rerun)
    assert Agent.get(state, & &1.item) == before
    assert writes(state) == []
  end

  test "existing owned sites retain custom settings and do not need Create sites permission" do
    {deps, state} = fixture(goat_permissions: 8)
    before = Agent.get(state, & &1.goat_sites)
    assert {:ok, plan} = Automation.prepare(@manifest, [], deps)
    assert plan.goatcounter.exists?
    assert {:ok, :saved} = Automation.apply(plan)
    assert Agent.get(state, & &1.goat_sites) == before
    refute Enum.any?(writes(state), &match?({:goat_write, _}, &1))
  end

  test "public host changes leave existing GoatCounter settings and credential identities untouched" do
    {deps, state} =
      fixture(
        goat_permissions: 8,
        item: item(%{"TAMAYOTCHI_GOATCOUNTER_PROVISIONING" => @goat_url <> "/my-app"})
      )

    {:ok, initial} = Automation.prepare(@manifest, [], deps)
    assert {:ok, :saved} = Automation.apply(initial)
    before = Agent.get(state, & &1)
    Agent.update(state, &%{&1 | events: []})

    for host <- ["track.tamayotchi.com", "better.example.com"] do
      manifest = put_in(@manifest, [:features, :phoenix], host: host)
      deployment = "env:\n  clear:\n    PHX_HOST: #{host}\n"
      assert {:ok, plan} = Automation.prepare(manifest, [deployment: deployment], deps)
      assert plan.goatcounter.code == "my-app"
      assert plan.goatcounter.exists?
      refute Automation.changed?(plan)
      assert {:ok, :unchanged} = Automation.apply(plan)
      assert writes(state) == []
      after_state = Agent.get(state, & &1)

      for key <- [:goat_sites, :item, :bootstrap, :tokens, :buckets],
          do: assert(after_state[key] == before[key])
    end
  end

  test "missing GoatCounter configuration or permissions blocks ALL writes" do
    missing =
      Map.update!(
        bootstrap(),
        "fields",
        &Enum.reject(&1, fn f -> String.starts_with?(f["label"], "GOATCOUNTER_") end)
      )

    {deps, state} = fixture(bootstrap: missing)
    assert {:ok, plan} = Automation.prepare(@manifest, [], deps)
    refute Automation.ready?(plan)
    assert Automation.format(plan) =~ "GOATCOUNTER_SITE_URL"
    assert {:error, _} = Automation.apply(plan)
    assert writes(state) == []

    for permission <- [0, 8] do
      {deps, state} = fixture(goat_sites: [goat_parent()], goat_permissions: permission)
      assert {:error, _} = Automation.prepare(@manifest, [], deps)
      assert writes(state) == []
    end
  end

  test "ambiguous GoatCounter creation reconciles an owned site without a second PUT" do
    {deps, state} = fixture(goat_sites: [goat_parent()], goat_fail: :lost_response)
    {:ok, plan} = Automation.prepare(@manifest, [], deps)
    assert {:error, _} = Automation.apply(plan)
    assert value(Agent.get(state, & &1.item), "TAMAYOTCHI_GOATCOUNTER_PROVISIONING")
    before = writes(state)
    assert {:ok, rerun} = Automation.prepare(@manifest, [], deps)
    assert {:ok, :unchanged} = Automation.apply(rerun)
    assert writes(state) == before

    Agent.update(state, &%{&1 | goat_sites: [goat_parent()]})
    assert {:error, message} = Automation.prepare(@manifest, [], deps)
    assert message =~ "automatic recreation"
    assert writes(state) == before
  end

  test "full setup adds GoatCounter even when all application credentials already exist" do
    {deps, state} = fixture()
    {:ok, plan} = Automation.prepare(@manifest, [], deps)
    assert {:ok, :saved} = Automation.apply(plan)
    Agent.update(state, &%{&1 | goat_sites: [goat_parent()], events: []})
    assert {:ok, plan} = Automation.prepare(@manifest, [], deps)
    assert Automation.changed?(plan)
    assert {:ok, :saved} = Automation.apply(plan)
    refute Enum.any?(writes(state), &match?({:cf_write, _}, &1))
    assert length(Enum.filter(writes(state), &match?({:goat_write, _}, &1))) == 1
  end

  test "partial, manual, and non-Phoenix setup never call GoatCounter" do
    for {manifest, opts} <- [
          {@manifest, [only: "SECRET_KEY_BASE"]},
          {@manifest, [provision: false]},
          {[schema: 1, app: :my_app, features: [r2: []]], []}
        ] do
      {deps, state} = fixture()
      assert {:ok, plan} = Automation.prepare(manifest, opts, deps)
      assert is_nil(plan.goatcounter)

      refute Enum.any?(Agent.get(state, & &1.events), fn {kind, _} ->
               kind in [:goat_read, :goat_write]
             end)
    end
  end

  test "GoatCounter HTTP failures and schema errors are not mislabeled as missing permissions" do
    for {response, expected} <- [
          {{:error, "GoatCounter rate limit reached (HTTP 429)"}, "HTTP 429"},
          {{:error, "GoatCounter rejected authentication (HTTP 401)"}, "HTTP 401"},
          {{:ok, %{"token" => %{"permissions" => "unexpected-format"}}},
           "unexpected permissions response"}
        ] do
      {deps, state} = fixture()
      deps = Keyword.put(deps, :goatcounter, fn :get, _, "/api/v0/me", _, _ -> response end)
      assert {:error, message} = Automation.prepare(@manifest, [], deps)
      assert message =~ expected
      refute message =~ "missing Read sites"
      assert writes(state) == []
    end
  end

  test "unowned, duplicate, inactive sites and checkpoint retargeting are refused" do
    for sites <- [
          [goat_parent(), Map.put(goat_site(), "parent", 99)],
          [goat_parent(), goat_site(), goat_site()],
          [goat_parent(), Map.put(goat_site(), "state", "d")],
          [goat_parent(), Map.put(goat_site(), "state", "active")],
          [Map.put(goat_parent(), "parent", 99), goat_site()]
        ] do
      {deps, state} = fixture(goat_sites: sites)
      assert {:error, _} = Automation.prepare(@manifest, [], deps)
      assert writes(state) == []
    end

    {deps, state} =
      fixture(
        item:
          item(%{"TAMAYOTCHI_GOATCOUNTER_PROVISIONING" => "https://other.goatcounter.com/my-app"})
      )

    assert {:error, message} = Automation.prepare(@manifest, [], deps)
    assert message =~ "retargeting"
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
          fail: nil,
          goat_permissions: 24,
          goat_sites: [goat_parent(), goat_site()],
          goat_fail: nil
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

    goat = fn method, origin, path, token, body ->
      assert origin == @goat_url
      assert token == @goat_token
      Agent.get_and_update(state, &goat(&1, method, path, body))
    end

    {[client: op, cloudflare: cf, goatcounter: goat, env: fn _ -> nil end], state}
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

  defp goat(data, method, path, body) do
    event = if method == :get, do: :goat_read, else: :goat_write
    data = %{data | events: data.events ++ [{event, {path, body}}]}

    case {method, path} do
      {:get, "/api/v0/me"} ->
        {{:ok, %{"token" => %{"permissions" => data.goat_permissions}}}, data}

      {:get, "/api/v0/sites"} ->
        {{:ok, %{"sites" => data.goat_sites}}, data}

      {:put, "/api/v0/sites"} ->
        created =
          Map.merge(goat_site(), %{"code" => body.code, "link_domain" => body.link_domain})

        data = %{data | goat_sites: data.goat_sites ++ [created]}

        if data.goat_fail == :lost_response,
          do: {{:error, "synthetic lost response"}, data},
          else: {{:ok, created}, data}
    end
  end

  # Captures the hosted API's wire state, not a human-readable display label.
  defp goat_parent, do: %{"id" => 1, "code" => "parent", "parent" => nil, "state" => "a"}

  defp goat_site,
    do: %{
      "id" => 2,
      "code" => "my-app",
      "parent" => 1,
      "state" => "a",
      "link_domain" => "https://custom.example.com",
      "cname" => nil,
      "setttings" => %{"public" => false},
      "user_defaults" => %{"timezone" => "UTC"}
    }

  defp ok(result, info \\ %{}),
    do: {:ok, %{"result" => result, "success" => true, "result_info" => info}}

  defp writes(state),
    do:
      Agent.get(
        state,
        &Enum.filter(&1.events, fn {kind, _} -> kind in [:op_write, :cf_write, :goat_write] end)
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
      "KAMAL_REGISTRY_PASSWORD" => @registry,
      "GOATCOUNTER_SITE_URL" => @goat_url,
      "GOATCOUNTER_API_TOKEN" => @goat_token
    })
    |> Map.merge(%{"id" => @bootstrap, "title" => "TAMAYOTCHI_BOOTSTRAP"})
  end
end
