# Tamayotchi Stack

Tamayotchi Stack is a development-time configuration tool for creating and
maintaining Phoenix applications with shared conventions. The generated
implementation belongs to each application; this package is not a production
runtime proxy.

## Current vertical slice

Version `0.1.0` supports:

- creating either a Phoenix app or a plain supervised Mix app
- adopting an existing Phoenix repository
- automatically installing a self-hosted GoatCounter client whenever Phoenix is enabled
- counting full page loads and Phoenix LiveView navigation
- generating an app-owned Kamal deployment with optional `kamal-proxy`
- configuring SQLite persistence and release migrations when SQLite is present
- optional app-owned R2 storage with a replaceable adapter and network-free fake
- optional daily SQLite backups with Litestream, a Kamal backup role, and safe restore scripts
- recording desired state in `.tamayotchi.exs`
- explicit synchronization and diagnostics

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
GoatCounter is always installed and its endpoint is derived directly from the
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
Include Kamal deployment? [Y/n]
Use kamal-proxy? [Y/n]
Include daily SQLite backups? [y/N]
```

Kamal/proxy questions are only asked when applicable. Backups are offered only
with SQLite and Kamal, and default to off. GoatCounter remains
automatic whenever Phoenix is selected.

Kamal uses the same deployment conventions as Tamagym: server
`192.168.1.39`, Docker Hub owner `tamayotchi`, `amd64`, and 1Password account
`instaleap-llc.1password.com`. Names are derived from the application. For
`my_app`, create a `SERVER/MY_APP` 1Password item containing:

```text
KAMAL_REGISTRY_PASSWORD
SECRET_KEY_BASE
```

Generate `SECRET_KEY_BASE` with `mix phx.gen.secret`. The generated
`.kamal/secrets` contains references only and is safe to commit.

Choosing no SQLite generates Phoenix with `--no-ecto`. Choosing no proxy
publishes Phoenix directly on port `4000` instead of running `kamal-proxy`.

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

Create the bucket and a bucket-scoped API token yourself. For public objects,
also configure public access, a custom domain, and DNS in Cloudflare. This tool
does not provision Cloudflare resources. Never commit credentials.

With Kamal enabled, `R2_BUCKET` defaults to the app name in `config/deploy.yml`;
change it to your bucket name. Add `R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`, and
`R2_SECRET_ACCESS_KEY` to the same 1Password item as your deployment secrets.

Tests always use the fake under the generated R2 configuration. Development uses
it unless R2 connection/credential variables are present, in which case incomplete
configuration fails clearly. The fake records calls and supports injected errors
per process; it neither persists nor serves uploads. Cross-process tests can
supply their own supervised adapter.

Sync preserves edits to generated storage modules and runtime configuration, and
refuses unmanaged conflicting files. `--no-r2` on an already configured app stops
management; it does not uninstall dependencies/code or remove deployment credentials.

## Optional SQLite backups

Based on **Robert's** Litestream/Supercronic deployment (no backup setup was found
in Prezio). Requires SQLite and Kamal; application R2 storage is independent.

```sh
mix tamayotchi.new my_app --backups --yes
# Or adopt an existing Phoenix + SQLite repository:
mix tamayotchi.setup --kamal --backups --yes
```

`--backups` / `--no-backups` and the wizard control the opt-in. `--yes` alone does
not enable it. The generated application owns:

- Litestream configuration with **seven-day retention**
- a **15:00 UTC daily** Supercronic schedule in a non-proxied Kamal `backup` role
- pinned, SHA256-verified Litestream/Supercronic binaries in the release image
- `kamal backup`, `backup-logs`, `backup-list`, and `backup-restore` aliases
- `docs/sqlite-backups.md` with provisioning, monitoring, and recovery instructions

Provision a **private** `<app-name>-db-backups` bucket. Set `LITESTREAM_ENDPOINT`,
`LITESTREAM_ACCESS_KEY_ID`, and `LITESTREAM_SECRET_ACCESS_KEY` in the deployment's
1Password item. Bucket/prefix/region are non-secret settings in `config/deploy.yml`;
they can target R2 or another S3-compatible service. Nothing provisions the bucket
or copies credentials into source files.

Unlike Robert's timed replication, the generated backup uses Litestream 0.5's
one-shot command and propagates failures. Restores are integrity-checked and
written to a **separate, non-existing file**, never over the live database. The
web entrypoint does not automatically restore or silently initialize after a
failed recovery. The replica prefix is separate from legacy v0.3 backups.

Daily backups can lose changes since the last successful job—normally up to
24 hours. Configure external failure/missed-job alerts and test recovery regularly.
Doctor checks installation, not remote backup health. The initial supported layout
is one amd64 web host and one SQLite database on the shared `/app/storage` volume.

On an existing installation, `--no-backups` stops **management**, not the deployed
scheduler. Stop the backup role explicitly to stop jobs; files, credentials, and
remote backups are never deleted by this option.

## Maintenance

```sh
mix tamayotchi.doctor
mix tamayotchi.sync
```

- `doctor` only reports repository state.
- `sync` reads `.tamayotchi.exs`, shows an Igniter diff, and updates managed,
  app-owned files after confirmation.

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
