# Tamayotchi Stack

Tamayotchi Stack is a development-time configuration tool for creating and
maintaining Phoenix applications with shared conventions. The generated
implementation belongs to each application; this package is not a production
runtime proxy.

## Current vertical slice

Version `0.1.0` supports:

- creating either a Phoenix app or a plain supervised Mix app
- adopting an existing Phoenix repository
- automatically including GoatCounter and Kamal whenever Phoenix is enabled
- counting full page loads and Phoenix LiveView navigation
- generating an app-owned Kamal deployment with optional `kamal-proxy`
- configuring SQLite persistence and release migrations when SQLite is present
- optional app-owned R2 storage with a replaceable adapter and network-free fake
- automatic backup scripts whenever SQLite is present, with a daily role when using Kamal
- recording desired state in `.tamayotchi.exs`
- explicit synchronization and diagnostics
- explicit, missing-only credential generation/import into 1Password

Oban is planned next. See
[`docs/definition.md`](docs/definition.md).

## Existing repository

Until the package is published, add the local checkout:

```elixir
{:tamayotchi_stack,
 path: "../tamayotchi_stack",
 only: [:dev, :test],
 runtime: false}
```

Then run:

```sh
mix deps.get
mix tamayotchi.setup
```

The wizard asks whether Phoenix should be managed. When Phoenix is enabled,
GoatCounter and Kamal are always included. The GoatCounter endpoint is derived from the
Mix application name:

```text
https://<app-name>.goatcounter.com/count
```

Noninteractive example:

```sh
mix tamayotchi.setup --phoenix --yes
```

## New application CLI

Build and install the local archive:

```sh
cd installer
MIX_ENV=prod mix archive.build
mix archive.install --force tamayotchi_stack_new-0.1.0.ez
```

Create a project:

```sh
mix tamayotchi.new my_app
```

The application name determines the directory and root module, and every project
starts as a Git repository. For automation, accept the defaults without prompts:

```sh
mix tamayotchi.new my_app --yes
```

The complete new-project flow is:

```text
Include Phoenix? [Y/n]
Include SQLite database? [Y/n]
Include Cloudflare R2 storage? [y/N]
Use kamal-proxy? [Y/n]
```

Phoenix always includes GoatCounter and Kamal. Only the proxy question is asked
for Phoenix apps; `--no-phoenix` creates a plain Mix app without Kamal. There are
no `--kamal`/`--no-kamal` flags. Backups are always included with SQLite, without
a separate question or opt-out flag.

Kamal uses the `home-server` SSH destination (as in `../tamayotchi/`), GHCR
namespace `tamayotchi`, `amd64`, and 1Password account
`instaleap-llc.1password.com`. Names are derived from the application. For
`my_app`, setup automatically creates/fills `SERVER/MY_APP`. Configure the shared
`SERVER/TAMAYOTCHI_BOOTSTRAP` item once as described below; no per-project secret
command is needed. Use `--no-secrets` for offline/file-only setup.
The generated `.kamal/secrets` contains references only and is safe to commit.

Configure `home-server` in your local SSH config (or DNS) before deploying.
Generated SSH defaults remain `root` with `~/.ssh/id_home_server`; review them for
your server. The alias centralizes the address, not security policy: SSH host-key
verification, authentication, and network exposure still matter. Existing deployment
hosts are preserved on setup/sync; switching them is an explicit app-owned edit.

Choosing no SQLite generates Phoenix with `--no-ecto`. Choosing no proxy
publishes Phoenix directly on port `4000` instead of running `kamal-proxy`.
`PHX_HOST` remains `<app-slug>.tamayotchi.com` in either mode, separate from the
SSH alias. Configure real DNS/public access yourself; no Cloudflare Tunnel,
loopback-only binding, or firewall policy is installed by this host-name change.

## Optional Cloudflare R2 storage

R2 defaults to **off**, including with `--yes`. Select it in the wizard or use:

```sh
mix tamayotchi.new my_app --r2 --yes
# Or, inside an existing project:
mix tamayotchi.setup --r2 --yes
mix deps.get
```

Use `--no-r2` to decline. R2 works independently of Phoenix and Kamal. The app owns:

```text
lib/my_app/storage.ex          # behaviour and dispatch boundary
lib/my_app/storage/r2.ex       # ExAws.S3 + ExAws.Request.Req
lib/my_app/storage/fake.ex     # non-persistent development/test adapter
config/runtime.exs            # environment configuration and startup validation
test/my_app/storage_test.exs
test/my_app/storage/r2_test.exs # request tests without network access
```

```elixir
MyApp.Storage.put_object(%{
  key: "documents/example.txt", body: "hello", content_type: "text/plain"
})
MyApp.Storage.delete_object(%{key: "documents/example.txt"})
```

Both operations return `:ok | {:error, reason}`. To use S3 or another provider,
implement `MyApp.Storage` and set `config :my_app, :storage, adapter: MyApp.Storage.S3`
in your application configuration. There is no Tamayotchi runtime dependency.
Get/list operations, signed URLs, upload restrictions, and public URL construction
are intentionally left to the application.

Production requires `R2_BUCKET`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, and
`R2_ACCOUNT_ID` (or an explicit HTTPS `R2_ENDPOINT`). `R2_REGION` defaults to `auto`.
`R2_PUBLIC_BASE_URL` is optional, so private buckets are supported. Credentials
are request-local and do not replace global ExAws credentials for other services.

Normal setup creates the bucket and issues a bucket-scoped API token using your
one-time Cloudflare bootstrap authorization, saving credentials in 1Password.
For public objects, configure public access, custom domains, and DNS yourself.
Never commit credentials.

With Kamal enabled, `R2_BUCKET` defaults to the hyphenated app name in
`config/deploy.yml` (very short names gain `-storage`); literal custom bucket names
are honored. `R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`, and `R2_SECRET_ACCESS_KEY` are saved
in the same 1Password item as the deployment secrets.

Tests always use the fake under the generated R2 configuration. Development uses
it unless R2 connection/credential variables are present, in which case incomplete
configuration fails clearly. The fake records calls and supports injected errors
per process; it neither persists nor serves uploads. Cross-process tests can
supply their own supervised adapter.

Sync preserves edits to generated storage modules and runtime configuration, and
refuses unmanaged conflicting files. `--no-r2` on an already configured app stops
management; it does not uninstall dependencies/code or remove deployment credentials.

## SQLite always includes backups

Based on **Robert's** Litestream/Supercronic deployment (no backup setup was found
in Prezio). Whenever SQLite is detected, backup scripts and credentials are included
automatically, independently of application R2 storage.

```sh
mix tamayotchi.new my_app --yes
# Or adopt an existing Phoenix + SQLite repository:
mix tamayotchi.setup --yes
```

There is no separate backup choice. Phoenix includes Kamal automatically, and the
generated application owns:

- Litestream configuration with **seven-day retention**
- a **15:00 UTC daily** Supercronic schedule in a non-proxied Kamal `backup` role
- backup credentials scoped to that role, not exposed to the web container
- pinned, SHA256-verified Litestream/Supercronic binaries in the release image
- `kamal backup`, `backup-logs`, `backup-list`, and `backup-restore` aliases
- `docs/sqlite-backups.md` with provisioning, monitoring, and recovery instructions

Normal setup automatically provisions a **private** `<hyphenated-app>-db-backups`
bucket and saves separate `LITESTREAM_ENDPOINT`, `LITESTREAM_ACCESS_KEY_ID`, and
`LITESTREAM_SECRET_ACCESS_KEY` values in 1Password. Bucket/prefix/region remain
non-secret settings in `config/deploy.yml`. For another S3-compatible service,
provision it yourself and use `mix tamayotchi.secrets --no-provision` to import
its credentials. Credentials never go into source files.

Unlike Robert's timed replication, the generated backup uses Litestream 0.5's
one-shot command and propagates failures. Restores are integrity-checked and
written to a **separate, non-existing file**, never over the live database. The
web entrypoint does not automatically restore or silently initialize after a
failed recovery. The replica prefix is separate from legacy v0.3 backups.

Daily backups can lose changes since the last successful job—normally up to
24 hours. Configure external failure/missed-job alerts and test recovery regularly.
Doctor checks installation, not remote backup health. The initial supported layout
is one amd64 web host and one SQLite database on the shared `/app/storage` volume.

For existing SQLite repositories configured with `--no-phoenix`, no Kamal is added.
The same backup/restore scripts and recovery guide are generated, but runtime tools
and scheduling remain manual. Follow
`docs/sqlite-backups.md` to install Litestream/Supercronic, supply the SQLite path
and credentials, and configure the production schedule yourself.

The manifest's `backups: []` entry is derived from SQLite detection; removing it
does not disable backups, and sync reinstates it. If SQLite is later removed,
existing files, deployed jobs, and remote backup data are retained for manual review.

## Automatic credentials in 1Password

**Once:** authenticate `op` and create a Secure Note named
`SERVER/TAMAYOTCHI_BOOTSTRAP` with these custom fields:

- `KAMAL_REGISTRY_PASSWORD`: a GitHub **classic PAT** with `read:packages` and
  `write:packages` (for local Kamal and GHCR; no GitHub Actions)
- `CLOUDFLARE_ACCOUNT_ID`: your account ID (for R2/SQLite)
- `CLOUDFLARE_API_TOKEN`: provisioning authorization with Account API Tokens Write
  and Workers R2 Storage Write; see the permission details in [`docs/secrets.md`](docs/secrets.md)

Cloudflare authorization is needed **once**, not for each application. Only replace
the shared token if it expires or is revoked. Application R2/backup keys are issued
automatically; never copy the administrative Cloudflare token into an app item.

New Kamal configurations use `registry.server: ghcr.io` and push images to
`ghcr.io/tamayotchi/<app-slug>` from your machine. No GitHub Actions workflow is
installed. Create the GitHub PAT once using the [package-only token page](https://github.com/settings/tokens/new?scopes=write:packages)
and store it in the bootstrap item; `gh auth token` does not turn an OAuth token
into a registry PAT. Avoid adding `repo`, `workflow`, or `delete:packages` scopes.
Existing registry settings/credentials are preserved, not silently migrated.

Use Password/concealed fields for all bootstrap values. Every generated app field
is concealed too, including account IDs, endpoints, and provisioning markers.
Legacy managed text fields are concealed on the next accepted secrets run without
rotating their values. Vault operations reuse one parent process per command to
avoid repeated desktop approvals; keep 1Password open and unlocked.

**Each project:** normal `tamayotchi.new` / `tamayotchi.setup` automatically generate
the Phoenix key, copy the shared registry credential, and issue/save bucket-scoped
R2/backup keys. Existing values are preserved. The powerful bootstrap token is
never copied to the app item or deployment. No extra per-project command is needed.

```sh
mix tamayotchi.new my_app --yes
# Offline/file-only escape hatch:
mix tamayotchi.setup --no-secrets --yes
# Preview or finish credential setup separately when needed:
mix tamayotchi.secrets --dry-run
mix tamayotchi.secrets --yes
```

Credentials run only after accepted setup changes. `sync` and setup dry runs never
contact providers. Secret-task dry runs perform read-only preflight. No values
appear in arguments, logs, temporary files, or repository diffs. Durable 1Password
markers prevent automatic token reissuance after interrupted operations; inspect
both systems after an ambiguous failure. There is no automatic rotation or rollback.

See [`docs/secrets.md`](docs/secrets.md) for bootstrap instructions, manual imports,
service accounts, custom destinations, supported layouts, and recovery.

## Maintenance

```sh
mix tamayotchi.doctor
mix tamayotchi.sync
```

- `doctor` only reports repository state.
- `sync` reads `.tamayotchi.exs`, shows an Igniter diff, and updates managed,
  app-owned files after confirmation.
- Older Phoenix manifests without Kamal acquire its files and derived manifest
  entry on sync. Existing host/proxy settings are preserved; conflicts require
  review. Sync never provisions credentials: run `mix tamayotchi.secrets --yes`
  afterward if credentials are missing. Doctor requires Kamal for managed Phoenix.
- `--no-phoenix` stops Phoenix/GoatCounter/Kamal management, but does not delete
  existing files, credentials, or deployed services. Review those manually.

## Development

```sh
mix deps.get
mix precommit

cd installer
mix precommit

# Generate and validate Phoenix/SQLite + R2 + backups, including a real
# WAL-mode SQLite backup/restore against a local Litestream replica.
# Requires curl, python3, sqlite3, flock, and Ruby (YAML validation).
cd ..
./scripts/smoke-new.sh
```
