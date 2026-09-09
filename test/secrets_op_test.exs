defmodule TamayotchiStack.Secrets.OpTest do
  use ExUnit.Case, async: false

  alias TamayotchiStack.Secrets.Op

  setup do
    directory = Path.join(System.tmp_dir!(), "secrets-op-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    previous = System.get_env("OP_SERVICE_ACCOUNT_TOKEN")
    System.delete_env("OP_SERVICE_ACCOUNT_TOKEN")

    on_exit(fn ->
      if previous,
        do: System.put_env("OP_SERVICE_ACCOUNT_TOKEN", previous),
        else: System.delete_env("OP_SERVICE_ACCOUNT_TOKEN")

      File.rm_rf!(directory)
    end)

    %{directory: directory}
  end

  test "sends JSON only over stdin, closes the pipe, and disables debug logging", ctx do
    executable =
      fake_op(ctx, ~S"""
      test "$OP_DEBUG" = false || exit 1
      test "$OP_INCLUDE_ARCHIVE" = false || exit 1
      # This data must arrive only on stdin, never in a process argument.
      for arg in "$@"; do
        case "$arg" in *dummy-secret-value*) exit 1 ;; esac
      done
      # A finite parent pipe must produce EOF even without a trailing newline.
      head -c 999999
      """)

    payload = %{"value" => "dummy-secret-value with quotes \" ' $() \n unicode: ñ"}
    assert {:ok, ^payload} = Op.request(["item", "create", "-"], payload, executable: executable)
    assert File.ls!(ctx.directory) == ["op"]
  end

  test "captures and suppresses stderr, nonzero exits, and invalid JSON", ctx do
    for {body, expected} <- [
          {"printf 'sensitive error text' >&2; printf 'sensitive stdout'; exit 1", :error},
          {"printf 'sensitive invalid json'", :error},
          {"printf 'sensitive debug' >&2; printf '{\"ok\":true}'", :ok}
        ] do
      executable = fake_op(ctx, body)

      case Op.request(["item", "list"], nil, executable: executable) do
        {:error, reason} ->
          assert expected == :error
          refute reason =~ "sensitive"

        {:ok, %{"ok" => true}} ->
          assert expected == :ok
      end
    end
  end

  test "bounds subprocess execution without displaying its output", ctx do
    executable = fake_op(ctx, "sleep 10; printf '{\"ok\":true}'")
    start = System.monotonic_time(:millisecond)

    assert {:error, reason} =
             Op.request(["item", "edit", "test-id"], %{"value" => "dummy-secret-value"},
               executable: executable,
               timeout_seconds: 1
             )

    assert System.monotonic_time(:millisecond) - start < 8000
    refute reason =~ "dummy-secret-value"
  end

  test "early successful CLI exits cannot leave unread JSON interpreted as another frame", ctx do
    executable = fake_op(ctx, "printf '{\"ok\":true}'")
    payload = %{"value" => String.duplicate("test-only-value", 50_000)}

    assert {:error, _} =
             Op.request(["item", "edit", "test-id"], payload,
               executable: executable,
               timeout_seconds: 1
             )

    assert File.ls!(ctx.directory) == ["op"]
  end

  test "timeout kills descendants that ignore TERM", ctx do
    executable =
      fake_op(ctx, ~S"""
      trap '' TERM
      printf '%s' "$$" > "$0.child"
      exec sleep 30
      """)

    assert {:error, _} =
             Op.request(["item", "list"], nil, executable: executable, timeout_seconds: 1)

    pid = File.read!(executable <> ".child")
    {state, _} = System.cmd("ps", ["-p", pid, "-o", "stat="], stderr_to_stdout: true)
    assert String.trim(state) == "" or String.starts_with?(String.trim(state), "Z")
  end

  test "desktop signin and identity check share a parent and session output is discarded", ctx do
    executable =
      fake_op(ctx, ~S"""
      case "$1" in
        signin)
          # This fixture records only a process ID, never session material.
          printf '%s' "$PPID" > "$0.parent"
          printf 'synthetic-sensitive-session-output'
          ;;
        whoami)
          test "$(head -c 30 "$0.parent")" = "$PPID" || exit 1
          printf '{"url":"example.1password.com"}'
          ;;
        *) exit 1 ;;
      esac
      """)

    assert {:ok, %{"url" => "example.1password.com"}} =
             Op.request(["whoami", "--account", "example.1password.com"], nil,
               executable: executable
             )
  end

  test "an entire session reuses one authorized parent for all reads and writes", ctx do
    executable =
      fake_op(ctx, ~S"""
      if [ "$1" = signin ]; then
        printf '%s' "$PPID" > "$0.parent"
        printf 'synthetic-sensitive-session-output'
      else
        test "$(head -c 30 "$0.parent")" = "$PPID" || exit 1
        if [ "$1" = item ] && [ "$2" = edit ]; then head -c 999999; else printf '{"ok":true}'; fi
      fi
      """)

    Op.with_session(
      fn ->
        assert {:ok, %{"ok" => true}} = Op.request(["whoami"])
        assert {:ok, %{"ok" => true}} = Op.request(["vault", "get", "SERVER"])
        payload = %{"value" => "synthetic-sensitive-value"}
        assert {:ok, ^payload} = Op.request(["item", "edit", "test-id"], payload)
        assert {:ok, %{"ok" => true}} = Op.request(["item", "get", "test-id"])
      end,
      executable: executable
    )
  end

  test "failed sessions cannot retry writes and invalid framing is refused", ctx do
    executable = fake_op(ctx, "printf '{\"ok\":true}'; exit 1")

    Op.with_session(
      fn ->
        assert {:error, _} = Op.request(["item", "edit", "test-id"])
        assert {:error, _} = Op.request(["item", "edit", "test-id"])
      end,
      executable: executable
    )

    assert {:error, _} = Op.request(["item\nquit", "list"], nil, executable: executable)
  end

  test "session cleanup survives exceptions and releases the parent", ctx do
    executable = fake_op(ctx, "printf '{\"parent\":%s}' \"$PPID\"")

    assert_raise RuntimeError, "synthetic failure", fn ->
      Op.with_session(
        fn ->
          assert {:ok, %{"parent" => pid}} = Op.request(["item", "list"])
          send(self(), {:parent, pid})
          raise "synthetic failure"
        end,
        executable: executable
      )
    end

    assert_receive {:parent, pid}
    {_, status} = System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true)
    refute status == 0
    assert {:ok, _} = Op.request(["item", "list"], nil, executable: executable)
  end

  test "launcher ignores shell startup files and restores the caller's exit behavior", ctx do
    startup = Path.join(ctx.directory, "startup")
    File.write!(startup, "touch '#{ctx.directory}/should-not-exist'\n")
    before = System.get_env("BASH_ENV")
    System.put_env("BASH_ENV", startup)

    on_exit(fn ->
      if before, do: System.put_env("BASH_ENV", before), else: System.delete_env("BASH_ENV")
    end)

    executable = fake_op(ctx, "printf '{\"ok\":true}'")
    previous_flag = Process.info(self(), :trap_exit)
    assert {:ok, _} = Op.request(["item", "list"], nil, executable: executable)
    assert Process.info(self(), :trap_exit) == previous_flag
    refute File.exists?(Path.join(ctx.directory, "should-not-exist"))
  end

  test "service accounts never invoke desktop signin", ctx do
    System.put_env("OP_SERVICE_ACCOUNT_TOKEN", "test-only-service-account-token")

    executable =
      fake_op(ctx, ~S"""
      test "$1" = whoami || exit 1
      test "$OP_SERVICE_ACCOUNT_TOKEN" = test-only-service-account-token || exit 1
      printf '{"url":"example.1password.com"}'
      """)

    assert {:ok, %{"url" => "example.1password.com"}} =
             Op.request(["whoami"], nil, executable: executable)
  end

  test "failed desktop authentication suppresses session output and stops identity lookup", ctx do
    executable =
      fake_op(ctx, ~S"""
      test "$1" = signin || exit 2
      printf 'synthetic-sensitive-session-output'
      printf 'synthetic-sensitive-error' >&2
      exit 1
      """)

    assert {:error, reason} = Op.request(["whoami"], nil, executable: executable)
    refute reason =~ "synthetic-sensitive"
    assert File.ls!(ctx.directory) == ["op"]
  end

  test "missing CLI executables give a redacted error", ctx do
    assert {:error, reason} = Op.request([], nil, executable: Path.join(ctx.directory, "missing"))
    refute reason =~ ctx.directory
  end

  defp fake_op(ctx, body) do
    path = Path.join(ctx.directory, "op")
    File.write!(path, "#!/bin/sh\nset -eu\n" <> body <> "\n")
    File.chmod!(path, 0o755)
    path
  end
end
