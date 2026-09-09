defmodule Mix.Tasks.Tamayotchi.Secrets do
  @shortdoc "Saves missing application credentials in 1Password"
  @moduledoc """
  Plans and saves missing credentials for features in `.tamayotchi.exs`.
  SQLite always implies Litestream backup credentials, including for older manifests.
  Does not start the application or modify repository files. Setup/install run
  this automatically after accepted file changes unless --no-secrets was selected.

      mix tamayotchi.secrets --dry-run
      mix tamayotchi.secrets --only SECRET_KEY_BASE
      mix tamayotchi.secrets --yes

  Generates a missing SECRET_KEY_BASE locally. Uses the shared TAMAYOTCHI_BOOTSTRAP
  item to copy KAMAL_REGISTRY_PASSWORD and authorize Cloudflare to create missing
  R2 buckets and issue separate bucket-scoped storage/backup credentials. Set up
  CLOUDFLARE_ACCOUNT_ID and CLOUDFLARE_API_TOKEN there once. Explicit environment
  imports still work. Existing non-empty fields are never rotated or replaced.
  All inputs are preflighted before writing; --only permits deliberate partial setup.
  Every managed field is concealed, including account IDs, endpoints, and markers.
  Existing managed text fields are concealed without changing their values.

  Use the unlocked 1Password desktop/CLI integration, or supply a separately
  provisioned OP_SERVICE_ACCOUNT_TOKEN with read/write access to the target vault.
  Desktop sign-in and all vault reads/writes share one parent for the entire command;
  keep the desktop app running and approve when needed. No password/session output is displayed
  or saved. Service accounts skip desktop sign-in. No vault or service account is created.

  ## One-time bootstrap

  In the selected vault (default SERVER), create a Secure Note named
  TAMAYOTCHI_BOOTSTRAP. Add actual values in custom fields KAMAL_REGISTRY_PASSWORD,
  CLOUDFLARE_ACCOUNT_ID, and CLOUDFLARE_API_TOKEN as needed by your features.
  Set all three custom fields to Password/concealed, including the account ID.
  For local Kamal + GHCR (no GitHub Actions), use a GitHub classic PAT with only
  read:packages/write:packages for the registry field. Your gh OAuth token is not
  a registry PAT; avoid repo/workflow/delete:packages scopes. Create the PAT once:
  https://github.com/settings/tokens/new?scopes=write:packages
  These bootstrap fields are configured once, not once per app. Cloudflare must
  have R2 enabled; its bootstrap token needs Account API Tokens Write and Workers
  R2 Storage Write for that account, with authority to list/create account-owned
  tokens and inspect bucket public domains. Keep this powerful token out of the
  application item and runtime. Detailed guide:
  https://github.com/tamayotchi/my_stack/blob/main/docs/secrets.md

  ## Options

    * `--dry-run` - read and display the plan; do not generate or write secrets
    * `--yes` / `-y` - explicitly authorize writes without a confirmation prompt
    * `--only FIELD,FIELD` - operate on named fields from enabled features
    * `--account HOST` - 1Password sign-in hostname (default: stack deployment convention)
    * `--vault NAME_OR_ID` - existing vault (default: SERVER)
    * `--item TITLE_OR_ID` - item (default: uppercase application name)
    * `--bootstrap-item TITLE_OR_ID` - separate shared item in the same vault
      (default: TAMAYOTCHI_BOOTSTRAP)
    * `--provision` / `--no-provision` - Cloudflare issuance and bootstrap lookup
      (default: yes); disable for manual imports or other S3-compatible providers

  Account/vault/item overrides do not update `.kamal/secrets`; keep deployment
  references aligned. Item names must be unambiguous. Existing items are edited
  by ID, with a re-read before writing and verification afterward. Do not run
  concurrent writers: the CLI does not provide an atomic compare-and-swap.

  Secret values are passed to op as JSON through stdin. CLI responses and errors
  are captured, never printed. No secret-value flags, rotation, or automatic
  rollback/revocation are supported. A durable provisioning marker precedes each
  Cloudflare write and blocks automatic reissuance after interruption. Inspect
  both systems after ambiguous failures. Requires op, Bash, coreutils, and kill on POSIX.
  """

  use Mix.Task

  alias TamayotchiStack.Manifest
  alias TamayotchiStack.Project
  alias TamayotchiStack.Prompt
  alias TamayotchiStack.Secrets
  alias TamayotchiStack.Secrets.Automation

  @requirements ["loadpaths"]
  @switches [
    dry_run: :boolean,
    yes: :boolean,
    only: :string,
    account: :string,
    vault: :string,
    item: :string,
    bootstrap_item: :string,
    provision: :boolean
  ]

  @impl Mix.Task
  def run(argv) do
    case TamayotchiStack.Secrets.Op.with_session(fn -> run_in_session(argv) end) do
      {:error, reason} -> Mix.raise(reason)
      result -> result
    end
  end

  defp run_in_session(argv) do
    # Do not echo invalid arguments: someone may have accidentally supplied a
    # secret-value flag. The same rule applies to provider errors and JSON.
    {options, positional, invalid} =
      OptionParser.parse(argv, strict: @switches, aliases: [y: :yes])

    if invalid != [] or positional != [] do
      Mix.raise(
        "Invalid secrets options. See mix help tamayotchi.secrets; never pass secret values as command arguments."
      )
    end

    manifest =
      case Manifest.read_file() do
        {:ok, manifest} -> manifest
        _ -> Mix.raise("Missing or invalid .tamayotchi.exs; run mix tamayotchi.setup first")
      end

    if manifest[:app] != Mix.Project.config()[:app] do
      Mix.raise("The manifest belongs to another application; refusing to manage its credentials")
    end

    options =
      case File.read(".kamal/secrets") do
        {:ok, contents} ->
          case Secrets.deployment_options(options, contents) do
            {:ok, options} -> options
            {:error, reason} -> Mix.raise(reason)
          end

        {:error, :enoent} ->
          options

        {:error, _} ->
          Mix.raise("Cannot read .kamal/secrets; refusing to guess the destination")
      end

    options =
      if Keyword.get(options, :provision, true) do
        case File.read("config/deploy.yml") do
          {:ok, contents} -> Keyword.put(options, :deployment, contents)
          {:error, :enoent} -> options
          _ -> Mix.raise("Cannot read config/deploy.yml; refusing to guess provisioning targets")
        end
      else
        options
      end

    plan =
      case Automation.prepare(manifest, options, sqlite?: Project.sqlite_on_disk?()) do
        {:ok, plan} -> plan
        {:error, reason} -> Mix.raise(reason)
      end

    Mix.shell().info(Automation.format(plan))

    cond do
      options[:dry_run] ->
        Mix.shell().info("Dry run complete. No secrets were generated or written.")

      not Automation.ready?(plan) ->
        {:error, reason} = Automation.apply(plan)
        Mix.raise(reason)

      not Automation.changed?(plan) ->
        Mix.shell().info("All selected fields already exist. Nothing changed.")

      options[:yes] ||
          Prompt.confirm(
            "Create these missing credentials/resources and save in 1Password?",
            false
          ) ->
        case Automation.apply(plan) do
          {:ok, :saved} ->
            Mix.shell().info(
              "Selected credentials saved and verified in 1Password. No repository files changed."
            )

          {:ok, :unchanged} ->
            Mix.shell().info("Nothing changed.")

          {:error, reason} ->
            Mix.raise(reason)
        end

      true ->
        Mix.shell().info("Cancelled. No secrets were generated or written.")
    end
  end
end
