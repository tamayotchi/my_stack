defmodule TamayotchiStack.SecretsTaskTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Tamayotchi.Secrets, as: Task

  test "the CLI previews, confirms, saves, verifies, and reruns without real vault access" do
    directory = Path.join(System.tmp_dir!(), "secrets-cli-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(directory, "tools"))
    previous_path = System.get_env("PATH")
    previous_state = System.get_env("TSTACK_TEST_OP_STATE")
    previous_shell = Mix.shell()

    credential_names =
      ~w(SECRET_KEY_BASE LITESTREAM_ENDPOINT LITESTREAM_ACCESS_KEY_ID LITESTREAM_SECRET_ACCESS_KEY CLOUDFLARE_ACCOUNT_ID CLOUDFLARE_API_TOKEN)

    previous_credentials = Map.new(credential_names, &{&1, System.get_env(&1)})
    Enum.each(credential_names, &System.delete_env/1)
    state_path = Path.join(directory, "fake-vault.json")

    on_exit(fn ->
      System.put_env("PATH", previous_path)

      if previous_state,
        do: System.put_env("TSTACK_TEST_OP_STATE", previous_state),
        else: System.delete_env("TSTACK_TEST_OP_STATE")

      Enum.each(previous_credentials, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)

      Mix.shell(previous_shell)
      File.rm_rf!(directory)
    end)

    python =
      System.find_executable("python3") ||
        flunk("python3 is required for the fake CLI smoke test")

    File.write!(Path.join(directory, "mix.exs"), """
    defmodule SecretsCliFixture.MixProject do
      use Mix.Project
      def project, do: [app: :sample, version: "0.1.0", deps: [{:ecto_sqlite3, "~> 0.22"}]]
    end
    """)

    File.write!(
      Path.join(directory, ".tamayotchi.exs"),
      "[schema: 1, app: :sample, features: [phoenix: []]]\n"
    )

    # This is a test-only fake vault. Only synthetic fixture credentials are
    # persisted here; no real op invocation or 1Password account is involved.
    File.write!(
      Path.join(directory, "tools/op"),
      "#!#{python}\n" <>
        ~S"""
        import json, os, pathlib, sys
        path = pathlib.Path(os.environ['TSTACK_TEST_OP_STATE'])
        state = json.loads(path.read_text()) if path.exists() else {'writes': 0, 'item': None}
        args = sys.argv[1:]
        vault_id, item_id = 'v' * 26, 'i' * 26
        if args[0] == 'signin':
            sys.exit(0)
        elif args[0] == 'whoami':
            result = {'url': 'instaleap-llc.1password.com'}
        elif args[:2] == ['vault', 'get']:
            result = {'id': vault_id}
        elif args[:2] == ['item', 'list']:
            result = [state['item']] if state['item'] else []
        elif args[:2] == ['item', 'get']:
            result = state['item']
        elif args[:2] in [['item', 'create'], ['item', 'edit']]:
            result = json.load(sys.stdin)
            result.update({'id': item_id, 'vault': {'id': vault_id}, 'version': state['writes'] + 1})
            state.update({'item': result, 'writes': state['writes'] + 1})
            path.write_text(json.dumps(state))
        else:
            sys.exit(1)
        print(json.dumps(result))
        """
    )

    File.chmod!(Path.join(directory, "tools/op"), 0o755)
    System.put_env("PATH", Path.join(directory, "tools") <> ":" <> previous_path)
    System.put_env("TSTACK_TEST_OP_STATE", state_path)
    Mix.shell(Mix.Shell.Process)

    Mix.Project.in_project(:sample, directory, fn _ ->
      before_files = File.ls!() |> Enum.sort()
      Task.run(["--dry-run", "--only", "SECRET_KEY_BASE"])
      assert messages() =~ "Dry run complete"
      refute File.exists?(state_path)

      send(self(), {:mix_shell_input, :prompt, "n"})
      Task.run(["--only", "SECRET_KEY_BASE"])
      assert messages() =~ "Cancelled"
      refute File.exists?(state_path)

      Task.run(["--only", "SECRET_KEY_BASE", "--yes"])
      assert messages() =~ "saved and verified"
      state = state_path |> File.read!() |> Jason.decode!()
      assert state["writes"] == 1
      secret = hd(state["item"]["fields"])["value"]
      assert byte_size(secret) >= 64

      Task.run(["--only", "SECRET_KEY_BASE", "--yes"])
      output = messages()
      assert output =~ "Nothing changed"
      refute output =~ secret
      assert (state_path |> File.read!() |> Jason.decode!())["writes"] == 1
      assert Enum.sort(File.ls!() -- ["fake-vault.json"]) == before_files

      # SQLite implies these fields even though the fixture's manifest predates
      # automatic backups and only records Phoenix.
      Task.run(["--dry-run"])
      output = messages()
      assert output =~ "LITESTREAM_ACCESS_KEY_ID: MISSING"
      assert output =~ "LITESTREAM_SECRET_ACCESS_KEY: MISSING"
      assert output =~ "LITESTREAM_ENDPOINT: MISSING"
      assert (state_path |> File.read!() |> Jason.decode!())["writes"] == 1

      assert_raise Mix.Error, ~r/never pass secret values/, fn ->
        Task.run(["--secret", "dummy-value-that-must-not-be-echoed"])
      end

      refute messages() =~ "dummy-value-that-must-not-be-echoed"

      File.write!(".tamayotchi.exs", "[schema: 1, app: :wrong_app, features: [phoenix: []]]\n")
      assert_raise Mix.Error, ~r/another application/, fn -> Task.run(["--yes"]) end
    end)
  end

  defp messages(acc \\ []) do
    receive do
      {:mix_shell, _kind, values} -> messages([Enum.join(values) | acc])
    after
      0 -> acc |> Enum.reverse() |> Enum.join("\n")
    end
  end
end
