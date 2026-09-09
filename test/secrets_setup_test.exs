defmodule TamayotchiStack.SecretsSetupTest do
  use ExUnit.Case, async: true
  import Igniter.Test

  alias TamayotchiStack.Manifest
  alias TamayotchiStack.Secrets
  alias TamayotchiStack.Sync

  test "setup and install enqueue automatic secrets only after the file changes" do
    for task <- ["tamayotchi.setup", "tamayotchi_stack.install"] do
      igniter = test_project(app_name: :sample)
      args = ["--yes", "--no-phoenix", "--r2"]
      configured = Igniter.compose_task(igniter, task, args)
      assert Igniter.prepare_for_write(configured).issues == []
      assert {"tamayotchi.secrets", ["--yes"], :delayed} in configured.tasks
      assert length(Secrets.queue_setup(configured, []).tasks) == length(configured.tasks)

      offline = Igniter.compose_task(igniter, task, args ++ ["--no-secrets"])
      refute Enum.any?(offline.tasks, &(elem(&1, 0) == "tamayotchi.secrets"))
      assert Manifest.read(configured) == Manifest.read(offline)
    end
  end

  test "sync and projects without credentials never enqueue provisioning" do
    configured =
      test_project(app_name: :sample) |> TamayotchiStack.Setup.configure(phoenix: false, r2: true)

    assert Sync.run(configured).tasks == []
    plain = test_project(app_name: :sample) |> TamayotchiStack.Setup.configure(phoenix: false)
    assert Secrets.queue_setup(plain, []).tasks == []
  end

  test "obsolete database and deployment flags are rejected by setup and install" do
    for task <- ["tamayotchi.setup", "tamayotchi_stack.install"],
        feature <- ["sqlite", "kamal", "backups"],
        prefix <- ["--", "--no-", "--tamayotchi.", "--tamayotchi.no-"] do
      assert_raise Mix.Error, ~r/automatic with Phoenix/, fn ->
        Igniter.compose_task(test_project(app_name: :sample), task, ["--yes", prefix <> feature])
      end
    end
  end

  test "setup, install, and sync reject inherited dry-run flags before composing changes" do
    for task <- ["tamayotchi.setup", "tamayotchi_stack.install", "tamayotchi.sync"],
        prefix <- ["--", "--no-", "--tamayotchi.", "--tamayotchi.no-"],
        suffix <- ["", "=true", "=false"] do
      assert_raise Mix.Error, ~r/no longer support --dry-run/, fn ->
        Igniter.compose_task(test_project(app_name: :sample), task, [
          "--yes",
          prefix <> "dry-run" <> suffix
        ])
      end
    end
  end

  test "R2 bucket defaults are valid for underscored and short app names" do
    assert TamayotchiStack.Features.R2.bucket_for_app(:my_app) == "my-app"
    assert TamayotchiStack.Features.R2.bucket_for_app(:a) == "a-storage"
  end
end
