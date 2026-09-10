defmodule Mix.Tasks.Tamayotchi.Secrets do
  @shortdoc "Saves missing application credentials in 1Password"
  @moduledoc """
  Plans and saves missing credentials and provisions the managed Phoenix app's
  GoatCounter site using features in `.tamayotchi.exs`.
  Managed Phoenix + SQLite implies backup credentials, including for older manifests.
  Does not start the application or modify repository files. Setup/install run
  this automatically after accepted file changes unless --no-secrets was selected.

      mix tamayotchi.secrets --only SECRET_KEY_BASE
      mix tamayotchi.secrets --yes

  Generates a missing SECRET_KEY_BASE locally. Uses the shared TAMAYOTCHI_BOOTSTRAP
  item to copy KAMAL_REGISTRY_PASSWORD and authorize Cloudflare to create missing
  R2 buckets and issue separate bucket-scoped storage/backup credentials. Set up
  CLOUDFLARE_ACCOUNT_ID and CLOUDFLARE_API_TOKEN there once. Explicit environment
  imports still work. GOATCOUNTER_SITE_URL and GOATCOUNTER_API_TOKEN authorize
  creation of missing GoatCounter child sites; existing owned sites keep their settings.
  Neither administrative API token is copied into the app item or runtime.
  Existing non-empty fields are never rotated or replaced.
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
  CLOUDFLARE_ACCOUNT_ID, CLOUDFLARE_API_TOKEN, GOATCOUNTER_SITE_URL, and
  GOATCOUNTER_API_TOKEN as needed by your features. Set every field to
  Password/concealed, including identifiers and URLs. For GoatCounter, use your
  existing main https://<site>.goatcounter.com URL and an API token with Read sites
  and Create sites permissions (username menu → API).
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

    * `--yes` / `-y` - explicitly authorize writes without a confirmation prompt
    * `--only FIELD,FIELD` - operate on named fields; skips GoatCounter provisioning
    * `--account HOST` - 1Password sign-in hostname (default: stack deployment convention)
    * `--vault NAME_OR_ID` - existing vault (default: SERVER)
    * `--item TITLE_OR_ID` - item (default: uppercase application name)
    * `--bootstrap-item TITLE_OR_ID` - separate shared item in the same vault
      (default: TAMAYOTCHI_BOOTSTRAP)
    * `--provision` / `--no-provision` - Cloudflare and GoatCounter provisioning
      and bootstrap lookup (default: yes); disable for manual configuration

  Account/vault/item overrides do not update `.kamal/secrets`; keep deployment
  references aligned. Item names must be unambiguous. Existing items are edited
  by ID, with a re-read before writing and verification afterward. Do not run
  concurrent writers: the CLI does not provide an atomic compare-and-swap.

  Secret values are passed to op as JSON through stdin. CLI responses and errors
  are captured, never printed. No secret-value flags, rotation, or automatic
  rollback/revocation are supported. A durable provisioning marker precedes each
  Cloudflare issuance or GoatCounter creation and blocks blind reissuance after
  interruption. Inspect the affected providers after ambiguous failures. Requires op, Bash, coreutils, and kill on POSIX.
  """

  use Mix.Task

  alias TamayotchiStack.Manifest
  alias TamayotchiStack.Project
  alias TamayotchiStack.Prompt
  alias TamayotchiStack.Secrets
  alias TamayotchiStack.Secrets.Automation

  @requirements ["loadpaths"]
  @switches [
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
    options = parse_options!(argv)

    case TamayotchiStack.Secrets.Op.with_session(fn -> run_in_session(options) end) do
      {:error, reason} -> Mix.raise(reason)
      result -> result
    end
  end

  defp parse_options!(argv) do
    # Do not echo invalid arguments: someone may have accidentally supplied a
    # secret-value flag. The same rule applies to provider errors and JSON.
    {options, positional, invalid} =
      OptionParser.parse(argv, strict: @switches, aliases: [y: :yes])

    if invalid != [] or positional != [] do
      Mix.raise(
        "Invalid secrets options. See mix help tamayotchi.secrets; never pass secret values as command arguments."
      )
    end

    options
  end

  defp run_in_session(options) do
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
      not Automation.ready?(plan) ->
        {:error, reason} = Automation.apply(plan)
        Mix.raise(reason)

      not Automation.changed?(plan) ->
        Mix.shell().info("All selected credentials and sites already exist. Nothing changed.")

      options[:yes] ||
          Prompt.confirm(
            "Create these missing credentials/resources and save in 1Password?",
            false
          ) ->
        case Automation.apply(plan) do
          {:ok, :saved} ->
            Mix.shell().info(
              "Selected credentials saved and verified in 1Password; selected service setup completed. No repository files changed."
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
