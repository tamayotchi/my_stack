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
- recording desired state in `.tamayotchi.exs`
- explicit synchronization and diagnostics

Oban and Cloudflare R2 are planned next. See
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
Include Kamal deployment? [Y/n]
Use kamal-proxy? [Y/n]
```

The last two questions are only asked when applicable. GoatCounter remains
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

# Generate and validate a real Phoenix/SQLite application.
cd ..
./scripts/smoke-new.sh
```
