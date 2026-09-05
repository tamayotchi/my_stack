defmodule TamayotchiStack.BackupScriptsTest do
  use ExUnit.Case, async: true

  setup do
    directory =
      Path.join(System.tmp_dir!(), "backup-scripts-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(directory, "bin"))
    File.mkdir_p!(Path.join(directory, "etc"))
    on_exit(fn -> File.rm_rf!(directory) end)

    for name <- ~w(backup-env litestream-backup litestream-restore litestream-list) do
      template = Path.join(:code.priv_dir(:tamayotchi_stack), "templates/backups/#{name}.eex")

      File.write!(
        Path.join(directory, "bin/#{name}"),
        EEx.eval_file(template, app: "sample", slug: "sample")
      )
    end

    File.write!(Path.join(directory, "etc/litestream.yml"), "# test config\n")
    db = Path.join(directory, "live.db")
    File.write!(db, "live database must not be changed")
    tools = Path.join(directory, "tools")
    File.mkdir_p!(tools)

    File.write!(Path.join(tools, "litestream"), """
    #!/bin/sh
    printf '%s\\n' "$@" > "$CALL_LOG"
    if [ "${FAIL_COMMAND:-}" = "$1" ]; then exit 42; fi
    if [ "$1" = restore ]; then
      while [ "$#" -gt 0 ]; do
        if [ "$1" = -o ]; then shift; printf 'restored database' > "$1"; break; fi
        shift
      done
    fi
    """)

    File.chmod!(Path.join(tools, "litestream"), 0o755)

    File.write!(Path.join(tools, "timeout"), """
    #!/bin/sh
    if [ "${FAIL_TIMEOUT:-}" = true ]; then exit 124; fi
    shift 3
    exec "$@"
    """)

    File.chmod!(Path.join(tools, "timeout"), 0o755)

    env = [
      {"DATABASE_PATH", db},
      {"LITESTREAM_CONFIG", Path.join(directory, "etc/litestream.yml")},
      {"LITESTREAM_ENDPOINT", "https://unused.example.test"},
      {"LITESTREAM_ACCESS_KEY_ID", "test-key-not-a-credential"},
      {"LITESTREAM_SECRET_ACCESS_KEY", "test-secret-not-a-credential"},
      {"CALL_LOG", Path.join(directory, "calls")},
      {"PATH", tools <> ":" <> System.get_env("PATH")}
    ]

    %{directory: directory, env: env, db: db}
  end

  test "scripts have valid shell syntax and backup uses one-shot replication", ctx do
    for name <- ~w(backup-env litestream-backup litestream-restore litestream-list) do
      assert {_, 0} = System.cmd("sh", ["-n", script(ctx, name)])
    end

    assert {output, 0} = run(ctx, "litestream-backup")
    assert output =~ "SQLite backup completed"

    assert File.read!(Path.join(ctx.directory, "calls")) =~
             "-once\n-force-snapshot\n-enforce-retention"

    assert File.read!(ctx.db) == "live database must not be changed"
  end

  test "failed uploads and timeouts are failures, never successful backups", ctx do
    for env <- [[{"FAIL_COMMAND", "replicate"}], [{"FAIL_TIMEOUT", "true"}]] do
      assert {output, status} = run(ctx, "litestream-backup", [], env)
      assert status in [42, 124]
      refute output =~ "backup completed"
    end
  end

  test "missing database or credentials fail before contacting storage", ctx do
    assert {output, 1} = run(ctx, "litestream-backup", [], [{"LITESTREAM_SECRET_ACCESS_KEY", ""}])
    assert output =~ "require LITESTREAM_SECRET_ACCESS_KEY"
    refute output =~ "test-key-not-a-credential"
    refute File.exists?(Path.join(ctx.directory, "calls"))
    File.rm!(ctx.db)
    assert {output, 1} = run(ctx, "litestream-backup")
    assert output =~ "database does not exist"
    refute File.exists?(ctx.db)
  end

  test "shared-volume lock prevents overlapping backups", ctx do
    command =
      "exec 9>\"$DATABASE_PATH.backup.lock\"; flock 9; sh \"$SCRIPT\"; status=$?; exit $status"

    assert {output, 1} =
             System.cmd("sh", ["-c", command],
               env: [{"SCRIPT", script(ctx, "litestream-backup")} | ctx.env],
               stderr_to_stdout: true
             )

    assert output =~ "already running"
    refute File.exists?(Path.join(ctx.directory, "calls"))
  end

  test "restore requests full integrity checking and publishes to a separate file", ctx do
    output_path = Path.join(ctx.directory, "recovered.db")
    assert {output, 0} = run(ctx, "litestream-restore", [output_path, "2026-01-01T15:00:00Z"])
    assert output =~ "live database was not changed"
    assert File.read!(output_path) == "restored database"
    assert File.read!(ctx.db) == "live database must not be changed"
    args = File.read!(Path.join(ctx.directory, "calls"))
    assert args =~ "-integrity-check\nfull"
    assert args =~ "-timestamp\n2026-01-01T15:00:00Z"
    refute args =~ "-force\n"
    refute args =~ "-if-replica-exists"
    assert Path.wildcard(output_path <> ".restore.*") == []
  end

  test "restore refuses the live DB, existing targets, symlinks, and sidecars", ctx do
    target = Path.join(ctx.directory, "target.db")

    for target <- [
          ctx.db,
          ctx.db <> "-wal",
          ctx.db <> "-shm",
          ctx.db <> "-journal",
          Path.join(ctx.directory, ".live.db-litestream/state")
        ] do
      assert {_, 1} = run(ctx, "litestream-restore", [target])
    end

    assert {_, 1} = run(ctx, "litestream-restore", [Path.join(ctx.directory, "./live.db")])
    File.write!(target, "existing recovery")
    assert {_, 1} = run(ctx, "litestream-restore", [target])
    assert File.read!(target) == "existing recovery"
    File.rm!(target)
    File.ln_s!(ctx.db, target)
    assert {_, 1} = run(ctx, "litestream-restore", [target])
    File.rm!(target)
    File.write!(target <> "-wal", "sidecar")
    assert {_, 1} = run(ctx, "litestream-restore", [target])
    assert File.read!(ctx.db) == "live database must not be changed"
    refute File.exists?(Path.join(ctx.directory, "calls"))
  end

  test "missing replicas and restore failures do not publish a file", ctx do
    target = Path.join(ctx.directory, "failed.db")
    assert {_, 42} = run(ctx, "litestream-restore", [target], [{"FAIL_COMMAND", "restore"}])
    refute File.exists?(target)
    assert Path.wildcard(target <> ".restore.*") == []
  end

  defp script(ctx, name), do: Path.join(ctx.directory, "bin/#{name}")

  defp run(ctx, name, arguments \\ [], env \\ []) do
    System.cmd("sh", [script(ctx, name) | arguments],
      env: Map.to_list(Map.merge(Map.new(ctx.env), Map.new(env))),
      stderr_to_stdout: true
    )
  end
end
