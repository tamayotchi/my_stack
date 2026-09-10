# Igniter Phoenix Starter Definition

Status: **In implementation**

Implemented in the first vertical slice:

- single development-time `tamayotchi_stack` package
- `tamayotchi.setup`, `tamayotchi.sync`, and `tamayotchi.doctor`
- `tamayotchi.new` installer archive
- optional Phoenix project generation
- app-owned GoatCounter integration derived from the application name
- app-owned Kamal deployment with optional `kamal-proxy`

R2 is also implemented as optional app-owned storage, following Prezio's
put/delete behaviour and adapter pattern. SQLite always includes backup scripts
based on Robert's Litestream/Supercronic setup; Kamal adds the daily schedule. Oban remains planned work.

This document defines a reusable Phoenix application starter built with
[Igniter](https://hexdocs.pm/igniter). It is intended to preserve the decisions
from the initial design conversation so implementation can continue later.

## Goal

Create a reusable tool that can:

1. Generate a new Phoenix application from an application name.
2. Include GoatCounter and Kamal automatically with Phoenix, and offer optional
   infrastructure such as Oban and Cloudflare R2.
3. Apply the same infrastructure safely to an existing Phoenix repository.
4. Support noninteractive flags for scripts and CI.
5. Produce idempotent, reviewable changes rather than copying one static
   project directory.

Igniter is appropriate because it is both a project generator and a semantic
project-patching framework. It can create and modify Elixir source without
relying primarily on fragile text replacement.

## Accepted Architecture Decision: One Configuration Tool, App-Owned Code

Use **one development-time package** for the entire workflow. Do not publish or
require separate `tamayotchi_oban`, `tamayotchi_r2`, or `tamayotchi_kamal`
packages, and do not put a Tamayotchi runtime proxy between applications and
those libraries.

The provisional dependency is:

```elixir
{:tamayotchi_stack, "~> 1.0", only: [:dev, :test], runtime: false}
```

It must not use the OTP application name `:tamayotchi`, because the existing
Tamayotchi application already owns that name.

The package is responsible only for:

- detecting the current repository state
- collecting the desired configuration
- adding and updating direct dependencies
- generating implementation into the target repository
- semantically patching configuration, supervision, migrations, and routes
- creating or safely updating release, Docker, and Kamal files
- validating that the resulting project follows the current conventions

Each target repository owns its generated implementation. For example:

- the application depends directly on and calls Oban
- Oban workers live in the application
- the R2 behaviour, adapter, and domain-specific storage boundary live in the
  application
- Docker, release, and Kamal files live in the application
- tests and fake adapters live in the application

Updating `tamayotchi_stack` does not silently rewrite a repository during
`mix deps.get` or compilation. The explicit `mix tamayotchi.sync` command
inspects app-owned code, presents an Igniter diff, and applies accepted updates.
There is one tool version, not independent feature versions.

Internal modules for Oban, R2, and Kamal are still useful for keeping the tool
maintainable, but they are private implementation details inside the single
package—not packages or runtime dependencies exposed to applications.

## User Experience

### New application

Proposed command:

```sh
mix tamayotchi.new my_app
```

Example interaction:

```text
$ mix tamayotchi.new my_app
Include Phoenix? [Y/n]

Include Oban? [Y/n]
Include Cloudflare R2? [y/N]
Use kamal-proxy? [Y/n]
```

SQLite, Kamal, GoatCounter, and backups are invariants of managed Phoenix, not
independent opt-ins. Plain Mix applications (`--no-phoenix`) get no database or
deployment scaffolding and no proxy question. Separate `--sqlite`/`--no-sqlite`,
`--kamal`/`--no-kamal`, and backup flags are rejected.

The target directory and base module are derived from the application name, and
Git is always initialized. They are not wizard questions or public options.

The implementation should build on the official generator chain:

```text
igniter.new -> phx.new -> tamayotchi starter installers
```

Conceptually, Igniter supports this through `mix igniter.new`, `--with
phx.new`, and composed installation tasks.

### Existing application

Proposed command, run from an existing repository:

```sh
mix tamayotchi.setup
```

Example interaction:

```text
Existing Phoenix application detected: MyApp

Oban is not installed. Install it? [Y/n]
R2 is not configured. Configure it? [y/N]
Use kamal-proxy? [Y/n]
```

The tool should detect:

- OTP application name
- base module
- Phoenix endpoint
- Ecto repository and database adapter
- existing Oban dependency, migration, supervision, and configuration
- existing R2 dependencies, adapters, and runtime configuration
- existing Docker, release, and Kamal files

It should ask only about missing or incomplete features.

### Minimal CLI

The public CLI should stay small:

```sh
mix tamayotchi.new my_app  # create and configure a new Phoenix application
mix tamayotchi.setup       # adopt/configure a repository for the first time
mix tamayotchi.sync        # update enabled features to current conventions
mix tamayotchi.doctor      # inspect and report without changing files
mix tamayotchi.secrets     # explicitly generate/import missing credentials into 1Password
```

Feature-specific logic remains internal. Users should not have to install,
version, or understand a separate handler for every feature.

### Noninteractive operation

Interactive prompts are a convenience. Flags must be the source of truth so
that the workflow is reproducible:

```sh
mix tamayotchi.new my_app --oban --r2
mix tamayotchi.setup --oban --r2 --yes
mix tamayotchi.setup --no-oban --r2
mix tamayotchi.sync --yes
mix tamayotchi.doctor --format json
```

The setup wizard collects choices and dispatches to deterministic internal
feature modules. Those modules should not depend on prompts to know what
changes to make.

### Update workflow

A normal update is explicit and reviewable:

```sh
mix deps.update tamayotchi_stack
mix tamayotchi.sync
mix precommit
```

The dependency update provides the latest detection rules, templates, and
codemods. `tamayotchi.sync` updates the implementation stored in the
application repository. Dependency updates may be automated across repositories
with Dependabot or Renovate, but repository modifications still require the
sync task and review.

## Proposed Package Architecture

Use one source repository containing an installer archive and one reusable
Igniter package, similar to the separation used by Igniter itself:

```text
tamayotchi_stack/
├── installer/
│   └── lib/mix/tasks/tamayotchi.new.ex
├── lib/
│   ├── mix/tasks/
│   │   ├── tamayotchi.setup.ex
│   │   ├── tamayotchi.sync.ex
│   │   └── tamayotchi.doctor.ex
│   └── tamayotchi_stack/
│       ├── project.ex
│       ├── feature.ex
│       └── features/
│           ├── oban.ex
│           ├── r2.ex
│           └── kamal.ex
├── priv/templates/
│   ├── oban/
│   ├── r2/
│   └── kamal/
└── test/
    ├── new_project_test.exs
    ├── existing_project_test.exs
    └── fixtures/
```

Responsibilities:

- The installer archive works outside a Mix project and creates a new Phoenix
  application.
- The single `tamayotchi_stack` package contains the CLI, repository detection,
  and all Igniter patchers.
- `TamayotchiStack.Features.*` modules are internal handlers composed by the
  public setup and sync tasks.
- The package generates and updates code in the target application; it does
  not provide Oban, R2, or Kamal runtime APIs.
- The application keeps direct dependencies on Oban, ExAws/Req, and any other
  selected libraries.
- Generated applications do not require `tamayotchi_stack` at production
  runtime.
- Tasks should use `Igniter.compose_task/3` where upstream installers or
  reusable Igniter operations are available.

## Prezio Reference Implementation

The initial design used the sibling `prezio` project as a reference. Prezio
contains working examples of all three target features, but its business logic
must not be copied into the generic starter.

### Oban in Prezio

The reusable infrastructure includes:

- the `oban` dependency
- an Oban migration
- Oban in the application supervision tree
- `Oban.Engines.Lite` for SQLite
- queue configuration
- the Pruner plugin
- manual testing mode
- worker tests with `Oban.Testing`
- optional Oban Web routing and authorization

Prezio-specific elements that must not become starter defaults include:

- the `price_fetching` queue
- `StorePriceFetcher`
- `StorePriceScheduler`
- the six-hour price refresh cron schedule
- Catalog-specific job arguments and uniqueness rules

### R2 in Prezio

The reusable infrastructure includes:

- `ex_aws` and `ex_aws_s3`
- `ExAws.Request.Req` as the ExAws HTTP client
- a storage behaviour
- an R2 implementation with put and delete operations
- a fake storage adapter for tests
- runtime configuration through environment variables
- startup validation of required storage configuration
- Kamal clear and secret environment integration

Prezio-specific elements that must not become starter defaults include:

- `ProductImages`
- product-image MIME restrictions
- the five-megabyte image limit
- the `product-images/` object prefix
- Catalog-specific public URL behavior
- LiveView product-upload UI

### Kamal in Tamagym

The latest Tamagym deployment is the reference for:

- a Phoenix release-oriented Dockerfile
- `config/deploy.yml`
- optional kamal-proxy routing
- registry credentials
- clear and secret environment variables
- a persistent volume for SQLite
- a release migration module
- `bin/server` and `bin/migrate` release overlays
- a container entrypoint that runs migrations before starting the server
- the shared server, registry owner, architecture, and 1Password location

Application-specific values such as the service, image name, hostname, release
paths, storage volume, and 1Password item are derived from the application name.
Tamagym-only media and AI configuration is not copied.

## Feature: Phoenix and GoatCounter

This is the implemented first vertical slice.

For a new project, `tamayotchi.new` asks for the application name and whether
to include Phoenix. It runs `phx.new` when enabled and creates a supervised Mix
application when disabled. Every Phoenix project automatically includes
GoatCounter; there is no separate GoatCounter question, option, or manifest
state.

When Phoenix is enabled, the generator always runs `phx.new --database sqlite3`.
There is no database question, opt-out, or database-free Phoenix template. Existing
Phoenix repositories must already have SQLite configured before setup/sync; missing
SQLite support is an actionable conflict, not permission to install a second
backend or migrate existing data automatically.

The GoatCounter feature accepts the Mix application name, not a user-supplied
endpoint. It constructs the HTTPS URL internally, replacing underscores with
hyphens; there is no separate URL-validation step for this derived value:

```text
my_app -> https://my-app.goatcounter.com/count
```

The generated application owns:

```text
assets/js/goatcounter.js
assets/vendor/goatcounter.js
assets/js/app.js             # imports the wrapper
```

The official `count.js` client is vendored into the application bundle. The
wrapper configures the endpoint, counts the initial page load, rebinds declared
GoatCounter click events after LiveView patches, and counts LiveView URL
navigation. Local/private addresses retain GoatCounter's default filtering.
The wrapper also includes Prezio's dynamic product-route normalization as a
commented example. An application can uncomment and adapt it when URLs with IDs
should be grouped under one logical GoatCounter path.

Managed generated files carry a Tamayotchi marker. Sync may update marked files
but refuses to overwrite an unmarked, pre-existing integration. The manifest
records only that Phoenix is managed; the GoatCounter endpoint is always derived
from the manifest application name.

### Automatic hosted GoatCounter site creation

The post-acceptance credential task also provisions GoatCounter for managed Phoenix.
The read-only shared bootstrap item supplies `GOATCOUNTER_SITE_URL` (the existing
main hosted site) and `GOATCOUNTER_API_TOKEN` with Read sites/Create sites permissions.
Both use Password/concealed fields. The API token never becomes an app credential
or runtime dependency; normal browser tracking still uses the public count endpoint.

Preflight checks `/api/v0/me` permissions and `/api/v0/sites` ownership. An existing
active matching site, including the parent itself, is reused without changing any
settings. Otherwise `PUT /api/v0/sites` creates a child with the derived code and
an HTTPS linking domain from literal `PHX_HOST` (or the app-host default). Full
reruns recheck GoatCounter read-only; `--only` excludes site provisioning, while
`--no-provision` excludes both providers. `--no-secrets` and sync stay file-only.

A concealed `TAMAYOTCHI_GOATCOUNTER_PROVISIONING` checkpoint precedes creation.
An interrupted operation can be reconciled read-only when the owned site exists;
a checkpoint without that site, or a different parent target, refuses recreation.
There is no automatic checkpoint clearing, retry, retargeting, or deletion.
Req transport is bounded, TLS-verified, paced for the hosted rate limit, and never
retries or redirects. Only hosted HTTPS main-site origins are accepted. GoatCounter
codes must be unreserved, 2–50-character labels; conflicts require manual action.
API schema changes fail closed rather than guessing ownership or permissions.

## Feature: Oban

### Installation behavior

The Oban installer should:

1. Detect the Ecto repository and database adapter.
2. Add a compatible Oban dependency.
3. Prefer composing an official Oban installer when one is available and
   compatible; otherwise generate the required migration safely.
4. Generate an Oban migration using the appropriate migration version for the
   installed Oban release.
5. Add Oban to the application supervision tree.
6. Add base configuration for the repository, engine, queues, and pruning.
7. Configure test mode as `testing: :manual`.
8. Add or document `Oban.Testing` support.
9. Avoid creating application-specific workers or cron schedules unless an
   explicit example option is selected.

Database-specific defaults:

- SQLite: use `Oban.Engines.Lite`.
- PostgreSQL: use the appropriate regular/default Oban engine.

### Oban Web

Oban Web should be a distinct option:

```text
Include Oban Web? [y/N]
```

The generator must not expose an unauthenticated production dashboard. If the
existing application has recognized authentication and admin authorization,
the installer may offer to integrate with it. Otherwise it should either:

- generate a disabled/example route with clear instructions, or
- skip routing until the user supplies an authorization strategy.

Commercial dependency or repository requirements for Oban Web must be handled
explicitly rather than assumed.

## Feature: Cloudflare R2

### Generic API

The R2 feature should provide generic object storage rather than an image or
Catalog feature. Proposed generated modules:

```text
lib/my_app/storage.ex
lib/my_app/storage/r2.ex
lib/my_app/storage/fake.ex
```

The storage contract intentionally supports only `put_object/1` and
`delete_object/1`, returning `:ok | {:error, reason}`, matching Prezio. `Storage`
also dispatches to the configured adapter, so callers remain provider-independent.
Get, list, signed URLs, metadata, and public URL construction are not generated.

Public image galleries follow Prezio's URL-based approach: the application stores
its image keys in its database and constructs each image URL from the configured
`R2_PUBLIC_BASE_URL` and a validated, URL-safe key. Query the database to discover
images; browsers fetch their bytes directly from the public domain, not through
Phoenix. Public access/domain configuration remains an explicit operator action;
`R2_ENDPOINT` is the authenticated S3 API origin, not a public image URL. Database
backup buckets always remain private.

The fake lives in `lib/` so it is available in development as well as tests;
its call history and injected results are process-local for async test isolation.
It is non-persistent and does not serve uploaded objects.

R2 is opt-in via the wizard or `--r2`; `--yes` does not enable it by default.
`--no-r2` stops management of an existing installation, without uninstalling it.
Sync preserves app-owned edits rather than replacing marked storage files.

### Dependencies and HTTP client

The Prezio-compatible approach is:

- `ex_aws`
- `ex_aws_s3`
- the already included `req` dependency
- `ExAws.Request.Req` as the request-local ExAws HTTP client
- `jason` and `sweet_xml` for response handling

Credentials, endpoint, and region are passed per request, not installed as global
ExAws settings, allowing other AWS/S3 integrations to coexist.

This preserves the Phoenix preference for Req rather than introducing
HTTPoison, Tesla, or direct `:httpc` usage.

### Runtime configuration

Generated configuration should use environment variables:

```text
R2_ACCOUNT_ID
R2_ACCESS_KEY_ID
R2_SECRET_ACCESS_KEY
R2_BUCKET
R2_PUBLIC_BASE_URL
R2_REGION
R2_ENDPOINT
```

Recommended behavior:

- `R2_REGION` defaults to `auto`.
- `R2_ENDPOINT` defaults to
  `https://<R2_ACCOUNT_ID>.r2.cloudflarestorage.com`.
- Bucket name and optional public base URL come from runtime environment variables;
  they are not wizard questions. Private buckets do not require a public URL.
- Access keys must never be written directly to source-controlled files.
- Generated runtime configuration uses the fake adapter in tests even when R2
  environment variables are present. An explicitly configured alternative backend
  is preserved.
- Development defaults to the fake unless an R2 endpoint/account/credential
  variable is present; partial credentials produce an actionable error.
- Runtime configuration is embedded in `runtime.exs` because runtime config does
  not support `import_config`. No additional release config files are needed.
- Production validates all required values at startup and fails with a clear
  error when configuration is incomplete.

### External provisioning boundary

The dedicated development-time credential task now creates missing R2 buckets
and bucket-scoped account-owned API tokens, using one-time bootstrap authorization
from 1Password. It runs after accepted setup changes, not inside patchers or sync.
Public bucket access, custom public domains, DNS records, and deployment remain
manual. Installation notices distinguish automatic credentials from these remaining
operational steps.

## Feature: Kamal

This feature is implemented. The Kamal installer creates or safely updates:

```text
Dockerfile
config/deploy.yml
.kamal/secrets
rel/overlays/bin/server
rel/overlays/bin/migrate
rel/overlays/bin/docker-entrypoint
lib/my_app/release.ex
```

### Wizard inputs

Phoenix always includes Kamal. The only deployment question is:

```text
Use kamal-proxy? [Y/n]
```

It is omitted when Phoenix is not managed. There is no Kamal opt-in/opt-out flag.
Other values follow the accepted deployment conventions:

- server: `home-server`, using the SSH destination convention from `../tamayotchi/`
- SSH user/key: `root` with `~/.ssh/id_home_server`
- container registry: `ghcr.io`, username/namespace `tamayotchi`
- local Kamal builds/deploys; no generated GitHub Actions workflow
- deployment architecture: `amd64`
- host: `<app-name>.tamayotchi.com`
- 1Password account/vault: `instaleap-llc.1password.com` / `SERVER`
- 1Password item: the uppercase application name

Configure `home-server` in the operator's SSH config or DNS before deploying.
Web and backup roles use the same destination. Setup/sync preserve existing IPs
and custom hosts; moving a deployment requires an explicit application edit.
For older Phoenix manifests, sync restores derived Kamal state and installs
missing files without provider calls. Existing proxy choices are retained even
when the old manifest omitted Kamal. Run the credential task separately after
reviewing a migration if needed. Doctor requires Kamal whenever Phoenix is managed.
Turning off Phoenix management preserves existing deployment files, services,
schedules, and credentials for manual review rather than uninstalling them.

The public `PHX_HOST` remains `<app-slug>.tamayotchi.com` with or without proxy;
an SSH alias need not resolve in browsers. The alias is address indirection,
not a security boundary: this does not install the reference app's Cloudflare
Tunnel, loopback-only proxy binding, or a firewall policy.

### Generated behavior

The generated deployment should include:

- Phoenix release build
- static asset deployment and digesting
- non-root runtime user
- CA certificates and required runtime libraries
- `PHX_HOST`, `PORT`, and `SECRET_KEY_BASE`
- optional proxy host and app port
- root-path health check
- release migrations before server startup
- database configuration appropriate to the selected adapter
- persistent storage when using SQLite
- R2 variables only when R2 is enabled

### Secrets

The generated `.kamal/secrets` fetches `KAMAL_REGISTRY_PASSWORD` and
`SECRET_KEY_BASE` from the derived 1Password item. It contains references only,
is safe to commit, and must never contain raw secret values. Additional feature
modules can append their own secret names later.

## Feature: 1Password credential setup

Credential setup is automatic by default in `tamayotchi.new`, `tamayotchi.setup`,
and the Igniter installer. They enqueue `mix tamayotchi.secrets --yes` only after
accepted file changes; `--no-secrets` supports offline/file-only runs. Pure patchers,
compilation, declined changes, conflicts, and sync never contact providers.
The default does not add another wizard question or a persisted feature flag.

The task reads enabled features from the literal `.tamayotchi.exs`, verifies the
application identity, and obtains the destination from conventional literal
`.kamal/secrets` references (without executing shell). Defaults remain the stack's
1Password account, vault `SERVER`, and uppercase app item. Explicit account/vault/item
overrides do not modify deployment references. Ambiguous names require an item ID.

GitHub is used only as a container registry. A package-scoped classic PAT is
configured once as `KAMAL_REGISTRY_PASSWORD` in the shared bootstrap item and reused
for new app items. The user's existing `gh` OAuth login is not exported or widened.
Automatic bootstrap reuse checks classic PAT format and a conventional GHCR target;
it does not validate live package access. Existing registries/credentials are preserved,
so migration requires explicitly changing `registry.server` and reviewing credentials.

A missing `SECRET_KEY_BASE` is imported from the environment or generated from 48
cryptographically random bytes, Base64-encoded to 64 characters. Registry, R2, and
Litestream credentials/configuration can still be imported from matching environment
variables. By default, a separate `TAMAYOTCHI_BOOTSTRAP` item supplies a shared registry
token, Cloudflare account/provisioning token, and GoatCounter main-site URL/API
token, configured once. Missing storage and
backup buckets are created and separate bucket-scoped account-owned tokens issued;
their IDs and SHA-256-derived S3 secrets are saved directly in the app item. Runtime
credentials never receive the bootstrap token or administrative token permissions.
All managed fields use Password/concealed types, including identifiers, endpoints,
and provisioning markers. Accepted secrets runs conceal legacy managed text fields
without changing their values or IDs; unrelated fields and metadata are preserved.
Existing non-empty values and unrelated fields are preserved. All selected inputs
and provider checks must pass before writes; `--only` permits deliberate partial setup.
Access-key pairs are selected together and cannot silently combine unmatched halves.

The task reads and displays names/actions before asking for confirmation, which
defaults to no. `--yes` explicitly authorizes noninteractive writes. There is no
`--dry-run` option; removed flags are rejected before configuration or credential
operations, including Igniter's inherited dry-run flag on setup/install/sync.
Authorization uses an existing op session or a separately supplied, vault-scoped
`OP_SERVICE_ACCOUNT_TOKEN`; the authenticated account hostname is always verified.
For desktop integration, sign-in and all vault reads/writes share one persistent
launcher parent for the entire command. Separate Erlang ports do not reliably share
terminal authentication. Session output is discarded, never saved or displayed;
service accounts never invoke desktop sign-in. Framed stdin carries arguments and
JSON without eval, secret shell variables, or credential files. Requests are bounded,
failed sessions never retry, and the parent is cleaned up even on exceptions.
No token-creation permissions are passed into generated applications.

Secret JSON stays in memory and is piped to op's stdin using a bounded Bash/coreutils
subprocess transport. No credential values become process arguments, temporary files,
source files, or logs. op caching and debug output are disabled, and provider errors
are redacted. Existing item IDs are used for edits; re-reads detect changes since the
preview, and read-back verification checks saved/preserved fields. JSON-template edits
of unsupported categories, attachments, and passkeys are refused. The CLI cannot
provide atomic compare-and-swap: concurrent writers must be avoided, and ambiguous
write failures require inspecting the vault before retrying. No automatic retries,
rotation, deletion, or revocation are performed.

Cloudflare provisioning supports default-jurisdiction R2 and literal conventional
deployment settings. Existing bucket configuration is not changed; backups require
a separate private bucket. Public domains/DNS and production deployment are not
provisioned. Other S3 endpoints and custom/dynamic layouts use `--no-provision` and
manual imports. Imported or preserved credentials are not externally validated.

Before each provider write, a non-secret per-feature provisioning marker is saved
and verified in 1Password. Each newly issued pair is saved immediately. A marker
with missing keys, or an existing deterministic Cloudflare token name, blocks
reissuance after interruption. Pagination is checked. There is no cross-provider
transaction, rollback, automatic retry, rotation, or revocation. Detailed bootstrap,
permissions, recovery, and security boundaries are in [`secrets.md`](secrets.md).
Tests use fake clients and a synthetic CLI/vault, never live accounts. Generated
credential smoke tests inject a fake HTTP transport in a disposable package copy;
no production CLI switch can redirect GoatCounter bootstrap credentials.

## Feature: SQLite backups

Managed Phoenix requires SQLite and always includes backups. There is no database
or backup prompt/flag. Kamal includes the daily role, binary installation, aliases,
and deployment environment. There is no standalone backup-installation mode for
plain Mix apps. Backups are independent of the optional R2 object-storage adapter.

Robert (`../../Nativo/Robert`) is the reference: a separate Kamal backup application
role using the release image and shared SQLite volume, daily at 15:00 UTC, with
Litestream replication to a private R2/S3 bucket. No backup configuration was
found in Prezio during implementation.

The generated app owns:

```text
rel/overlays/etc/litestream.yml
rel/overlays/etc/backup.cron
rel/overlays/bin/backup-env
rel/overlays/bin/litestream-backup
rel/overlays/bin/litestream-restore
rel/overlays/bin/litestream-list
docs/sqlite-backups.md
```

Deployment adds a non-proxied `backup` role on the same host and named volume,
backup aliases, and separate `LITESTREAM_*` environment references. Backup credentials
are scoped to `servers.backup.env.secret`, never the global/web environment. Exact
legacy generated global credential blocks are migrated; customized blocks yield
an actionable conflict rather than dropping user changes. The default
bucket is `<app-slug>-db-backups`, prefix `<app-slug>-production-v0.5`, and region
`auto`. Endpoint and access keys are supplied through the existing 1Password
location, never inserted into generated files. Default credential setup provisions
the private R2 bucket and bucket-scoped read/write/list/delete credentials. Other
S3-compatible providers use manual provisioning and explicit imports.

Pinned, checksum-verified Litestream 0.5.17 and Supercronic 0.2.49 binaries are
installed in the final Docker stage. Unlike Robert's v0.3 timed `sleep 10` job,
the backup script uses `replicate -once -force-snapshot -enforce-retention`, a
15-minute timeout, and a shared-volume file lock. The snapshot retention is
seven days; the schedule is 15:00 UTC. Daily backups are not continuous protection:
recovery can lose changes since the last successful job. External missed-job
alerts and regular restore drills are necessary.

Restores require a separate absolute, non-existing output path, reject the live
DB and its sidecars/metadata, run a full SQLite integrity check, and publish with
an atomic no-clobber link. Missing replicas and all other errors fail visibly.
There is no automatic restore or empty-database fallback in the web entrypoint.
Promotion into service is an explicit operator procedure after stopping writers
and preserving the existing database, WAL/SHM, and Litestream metadata.

Initial support is one amd64 web host and one SQLite DB in a named shared
`/app/storage` volume. Multi-host/custom layouts, unmarked existing integrations,
and ambiguous deployment structures yield actionable conflicts. Owned files and
marked deployment sections preserve user changes; incomplete markers are refused.
`.tamayotchi.exs` records `backups: []` as derived Phoenix state, not an independent
opt-in. Removing this entry cannot disable backups: setup/sync reinstate it for
managed Phoenix. Doctor requires SQLite and the full backup/deployment integration.
It does not verify the running scheduler, remote freshness, or recoverability.
Removing SQLite causes setup/sync to refuse further configuration, not silently
switch to a database-free deployment. Turning off Phoenix management preserves
existing backup artifacts, jobs, credentials, and remote data for manual review.
The explicit secrets command retains compatibility with older managed Phoenix +
SQLite manifests that omitted the backup entry; it does not migrate their database
configuration or add backup credentials after opting out of Phoenix management.

The generated-project smoke test exercises a real WAL-mode SQLite database,
multiple one-shot backups, restore, and integrity checks using the pinned binaries
and a local file replica, without cloud credentials or production data.

References:
- <https://litestream.io/reference/replicate/> (one-shot mode)
- <https://litestream.io/reference/config/> (snapshot retention and replica settings)
- <https://litestream.io/reference/restore/> (safe restoration and integrity checks)
- <https://github.com/aptible/supercronic>

## Existing-Repository Safety Requirements

All installers and sync operations must be:

- **App-owned:** generated implementation remains ordinary source code in the
  target repository and must not delegate core behavior to a Tamayotchi runtime
  proxy.
- **Idempotent:** running a task twice does not duplicate dependencies,
  children, queues, routes, configuration, migrations, or environment entries.
- **Additive:** preserve existing queues, plugins, supervision children, and
  dependencies where possible.
- **Conflict-aware:** report incompatible existing configuration instead of
  silently replacing it.
- **Previewable:** use Igniter's diff and confirmation workflow.
- **Composable:** Oban, R2, and Kamal must work independently.
- **Recoverable:** a failed feature installer should not leave an unexplained
  partially configured state.
- **Non-secret:** never print, persist, or include credentials in a generated
  diff.

### Elixir files

Use semantic Igniter APIs where possible:

- `Igniter.Project.Deps`
- `Igniter.Project.Config`
- `Igniter.Project.Application`
- `Igniter.Project.Module`
- `Igniter.compose_task/3`

Avoid broad string replacement for `mix.exs`, config files, modules, and
application supervision trees.

### YAML, shell, and Docker files

These files are harder to patch semantically while preserving comments. The
merge policy should be:

1. Create a complete file when it does not exist.
2. Modify an explicitly managed section when starter markers already exist.
3. Perform a narrowly validated structured merge when it is demonstrably safe.
4. Refuse a destructive rewrite when the file contains unknown conflicting
   content.
5. Present manual instructions for unresolved conflicts.

The installer must never replace an existing Dockerfile or Kamal configuration
without showing a clear diff and obtaining confirmation.

## Desired-State Manifest

A minimal non-secret manifest is recommended so the single sync command knows
which features the repository intends to keep configured:

```text
.tamayotchi.exs
```

Example conceptual content:

```elixir
[
  schema: 1,
  app: :my_app,
  features: [
    phoenix: [],
    kamal: [proxy: true],
    oban: [],
    r2: []
  ],
  r2: [
    bucket: "my-app",
    public_base_url: "https://images.my-app.tamayotchi.com"
  ]
]
```

The manifest stores desired state and non-secret inputs, not copies of
implementation and not separate Oban/R2/Kamal template versions. The installed
`tamayotchi_stack` dependency supplies the current conventions.

The repository remains the source of truth for actual implementation. Sync
must inspect real files rather than assuming the manifest proves that a feature
is complete. On first adoption, the tool should detect existing manual setup,
ask whether to manage it, and then write the corresponding desired state.

## Detection and Conflict Policy

Before changing an existing project, produce a detection report such as:

```text
Phoenix: 1.8.x
Application: my_app
Base module: MyApp
Endpoint: MyAppWeb.Endpoint
Repo: MyApp.Repo
Database: SQLite
Oban: partial (dependency and migration found, supervision missing)
R2: absent
Kamal: present, unmanaged
Git worktree: dirty
```

Recommended responses:

- Complete recognized partial installations after confirmation.
- Preserve compatible manual configuration.
- Warn before operating on a dirty worktree.
- Abort when multiple repositories/endpoints are ambiguous unless the user
  selects one with a flag.
- Never infer authorization for Oban Web.
- Never infer secret values.

## Compatibility Boundary for Version One

Recommended initial support:

- Phoenix 1.8
- Elixir 1.17 or newer, even though Igniter supports Elixir 1.15+
- one Phoenix endpoint
- one Ecto repository
- PostgreSQL or SQLite
- non-umbrella projects
- standard Phoenix release layout
- Kamal 2

Initially unsupported or explicit opt-in:

- umbrella applications
- multiple endpoints
- multiple repositories
- MySQL
- applications without Ecto when Oban is selected
- replacing heavily customized deployment files

Unsupported layouts should produce actionable errors rather than guessed
changes.

## Testing Strategy

Each feature needs tests for new and existing projects.

### Fixture matrix

At minimum:

- fresh Phoenix + PostgreSQL
- fresh Phoenix + SQLite
- existing Phoenix with no optional features
- existing Phoenix with complete Oban
- existing Phoenix with partial Oban
- existing Phoenix with R2-like manual configuration
- existing Phoenix with an existing Dockerfile
- existing Phoenix with an existing Kamal file
- dirty Git worktree
- task run twice

### Assertions

Validate:

- generated projects compile
- migrations compile and run
- supervision starts
- tests use fake/manual infrastructure
- no duplicate dependencies or configuration after a second run
- no secrets appear in generated files or command output
- Kamal configuration parses
- Docker image builds
- feature combinations work in every supported database mode
- installing one feature does not modify unrelated features

Use temporary fixture projects and snapshot the resulting Igniter diffs where
helpful.

## Distribution Options

Two reasonable options:

1. **Private GitHub distribution:** suitable for personal use and early
   iteration. The installer/archive and package are installed from a Git URL.
2. **Hex package and archive:** easier commands and versioning once the API is
   stable.

Recommended sequence:

1. Start private on GitHub.
2. Exercise it against several real existing projects.
3. Stabilize feature contracts and upgrade behavior.
4. Publish only if broader reuse becomes valuable.

## Open Decisions

Remaining decisions:

1. Shape and timing of the future database feature; SQLite is the accepted
   default.
2. Whether Oban Web is included in version one.
3. Private Git installation or Hex publication.
4. Whether architecture docs and an `AGENTS.md` baseline are generated.
5. Resolved: R2 version one supports put/delete only.
6. Resolved: private buckets are supported; public base URLs are optional.
7. Exact desired-state manifest schema and which non-secret inputs belong in
   it.
8. Whether cron support is merely configured or includes an optional example.

## Recommended Implementation Order

The package, manifest, setup/sync/doctor tasks, external installer, Phoenix,
GoatCounter, and Kamal vertical slices are implemented. Continue with:

1. Run the implemented features against additional real repositories and refine
   conflict handling.
2. Implement app-owned Oban generation for one fresh SQLite fixture.
3. Make Oban sync idempotent and support existing/partial installations.
4. Add PostgreSQL support.
5. R2 storage and fake adapters are implemented; exercise additional existing
   repositories and add explicit codemods as the storage contract evolves.

## Continuation Checklist

When returning to this work:

1. Read this document.
2. Re-read the current Igniter generator documentation because its API is
   evolving.
3. Reinspect Prezio's Oban/R2 setup and Tamagym's release, Docker, and Kamal
   implementation for changes since this definition.
4. Decide the open questions above.
5. Create a separate repository for the starter rather than implementing it
   inside an application repository.
6. Start with one vertical slice: generate a Phoenix SQLite app and install an
   idempotent minimal Oban configuration.

## References

- Igniter documentation: <https://hexdocs.pm/igniter>
- Igniter source: <https://github.com/ash-project/igniter>
- Phoenix: <https://www.phoenixframework.org>
- Oban: <https://hexdocs.pm/oban>
- Kamal: <https://kamal-deploy.org>
- Cloudflare R2 S3 API: <https://developers.cloudflare.com/r2/api/s3/api/>
- Cloudflare R2 public buckets: <https://developers.cloudflare.com/r2/buckets/public-buckets/>
