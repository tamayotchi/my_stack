# Igniter Phoenix Starter Definition

Status: **In implementation**

Implemented in the first vertical slice:

- single development-time `tamayotchi_stack` package
- `tamayotchi.setup`, `tamayotchi.sync`, and `tamayotchi.doctor`
- `tamayotchi.new` installer archive
- optional Phoenix project generation
- app-owned GoatCounter integration derived from the application name
- app-owned Kamal deployment with optional `kamal-proxy`

Oban and R2 remain planned work described below.

This document defines a reusable Phoenix application starter built with
[Igniter](https://hexdocs.pm/igniter). It is intended to preserve the decisions
from the initial design conversation so implementation can continue later.

## Goal

Create a reusable tool that can:

1. Generate a new Phoenix application from an application name.
2. Interactively enable optional infrastructure such as Oban, Cloudflare R2,
   and Kamal.
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
Include SQLite database? [Y/n]

Include Oban? [Y/n]
Include Cloudflare R2? [y/N]
Include Kamal deployment? [Y/n]
Use kamal-proxy? [Y/n]
```

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
Kamal is partially configured. Complete it? [Y/n]
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
```

Feature-specific logic remains internal. Users should not have to install,
version, or understand a separate handler for every feature.

### Noninteractive operation

Interactive prompts are a convenience. Flags must be the source of truth so
that the workflow is reproducible:

```sh
mix tamayotchi.new my_app --oban --r2 --kamal
mix tamayotchi.setup --oban --r2 --kamal --yes
mix tamayotchi.setup --no-oban --r2 --kamal
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

When Phoenix is enabled, the wizard asks whether to include SQLite and defaults
to yes. Choosing no runs `phx.new` with `--no-ecto`. Database support is not yet
a managed feature in the first vertical slice; when implemented, SQLite remains
the default.

The GoatCounter endpoint is derived from the Mix application name, replacing
underscores with hyphens:

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
test/support/storage/fake.ex
```

The initial storage contract should support at least:

```text
put_object
get_object (decision still required)
delete_object
```

Prezio currently demonstrates put and delete. Whether get, list, signed URLs,
and metadata belong in version one remains an open decision.

### Dependencies and HTTP client

The Prezio-compatible approach is:

- `ex_aws`
- `ex_aws_s3`
- the already included `req` dependency
- `ExAws.Request.Req` as the configured ExAws HTTP client

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
- Bucket name and public base URL may be collected as non-secret wizard input.
- Access keys must never be written directly to source-controlled files.
- Test configuration uses the fake adapter.
- Development defaults to a fake/local adapter unless R2 credentials are
  explicitly present.
- Production validates all required values at startup and fails with a clear
  error when configuration is incomplete.

### External provisioning boundary

The starter can generate application configuration but should not claim to
provision these without a dedicated Cloudflare API integration:

- R2 bucket
- R2 API token and credentials
- public bucket access
- custom public domain
- Cloudflare DNS records

After installation, print an explicit provisioning checklist.

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

The installer asks only:

```text
Include Kamal deployment? [Y/n]
Use kamal-proxy? [Y/n]
```

The second question is only asked when Kamal is enabled. Other values follow
the accepted Tamagym convention:

- server: `192.168.1.39`
- SSH user/key: `root` with `~/.ssh/id_home_server`
- Docker Hub owner: `tamayotchi`
- deployment architecture: `amd64`
- host: `<app-name>.tamayotchi.com`
- 1Password account/vault: `instaleap-llc.1password.com` / `SERVER`
- 1Password item: the uppercase application name

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
5. Whether R2 version one supports only put/delete or also get/list/signed URL.
6. Whether R2 public URLs are required or private buckets are supported.
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
5. Implement app-owned generic R2 storage with a fake test adapter.

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
