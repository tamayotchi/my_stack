# Automatic credentials in 1Password

`mix tamayotchi.new` and `mix tamayotchi.setup` automatically set up missing
credentials and the Phoenix app's GoatCounter site after their file changes are
accepted. **No separate secrets command
is required for the normal flow.** Existing credentials are never rotated.

## One-time bootstrap

1. Install the [1Password CLI](https://developer.1password.com/docs/cli/) (`op`),
   enable its desktop integration, and unlock the desktop app. The task runs
   desktop sign-in and **all vault reads/writes** under one persistent launcher
   parent for the entire command, rather than asking for approval per subprocess.
   Keep the desktop app running and approve when requested; unlocking/session expiry
   may still require authentication. No password/session output is displayed or saved.
   Bash, coreutils `head`/GNU `timeout`, and `kill` are also required.
2. In `instaleap-llc.1password.com`, vault `SERVER`, create a **Secure Note** named
   **`TAMAYOTCHI_BOOTSTRAP`** with these exact custom field labels. Choose the
   **Password/concealed field type for all five**, including the account ID and URL:

   | Field | Set once | Needed for |
   | --- | --- | --- |
   | `KAMAL_REGISTRY_PASSWORD` | GitHub classic PAT with `read:packages`/`write:packages`, concealed | Local Kamal + GHCR |
   | `CLOUDFLARE_ACCOUNT_ID` | Your 32-character Cloudflare account ID | R2 or SQLite backups |
   | `CLOUDFLARE_API_TOKEN` | A Cloudflare provisioning API token, concealed | R2 or SQLite backups |
   | `GOATCOUNTER_SITE_URL` | Your main `https://<site>.goatcounter.com` URL, without a path | Phoenix analytics |
   | `GOATCOUNTER_API_TOKEN` | API token with **Read sites + Create sites** permissions | Phoenix analytics |

3. Enable R2/billing in that Cloudflare account. Create the provisioning token
   with **Account API Tokens Write** and **Workers R2 Storage Write** for that
   account, using an identity authorized to create account-owned tokens. It must
   also be able to list account tokens/permission groups and inspect bucket public
   domains. Cloudflare requires the appropriate account administrator privileges.
   This is a powerful provisioning credential: restrict access and never put it
   in the application's item, deployment environment, or repository.

4. In your main GoatCounter account, open **your username → API** and create a
   token with **Read sites** and **Create sites** permissions, with access to the
   main site. Store it in `GOATCOUNTER_API_TOKEN` and put that main site's HTTPS
   origin in `GOATCOUNTER_SITE_URL`. The initial account/token is a one-time manual
   step; Stack creates child sites, not new accounts.

Use actual credential values in those fields, not placeholders or `op://` reference strings.
The bootstrap item is only read, never modified. Every Phoenix app includes SQLite
backups, Kamal, and GoatCounter, so it needs Cloudflare, registry, and GoatCounter
bootstrap credentials,
even when application R2 storage is disabled. Plain Mix apps (`--no-phoenix`) need
no registry credential; they need Cloudflare only if R2 is selected. The tool cannot
create its own initial Cloudflare/1Password authorization
or manufacture a valid GitHub PAT. **You fill these fields once, not for each new
app.** Only expired/revoked bootstrap credentials need replacement. Each app gets
its own generated Phoenix key and separately issued Cloudflare credentials.

### GoatCounter site provisioning

Full credential setup for managed Phoenix reads `GET /api/v0/me` and
`GET /api/v0/sites` on the configured main site. It reuses an active owned site
with the derived app code, including the main site itself when its code matches.
Existing site settings, linking domain, and dashboard visibility are preserved,
including when changing the public Phoenix/Kamal hostname with `setup --host`.
Otherwise, after confirmation, `PUT /api/v0/sites` creates a child site and a
read-back verifies its identity. New sites use the literal deployment `PHX_HOST`
as their HTTPS linking domain, defaulting to `<app-slug>.tamayotchi.com`.

A concealed `TAMAYOTCHI_GOATCOUNTER_PROVISIONING` checkpoint is saved in the app
item before creation. If a request or read-back fails, a subsequent run can
recognize the existing owned site without another PUT. If the checkpoint exists
but that site is absent, or the parent target changed, creation is refused until
manual reconciliation. Markers are never cleared automatically. Provider writes
are not retried or redirected; requests are paced for the hosted API rate limit.

Full reruns recheck GoatCounter read-only, even when all credential values already
exist. `--only` skips GoatCounter entirely; `--no-provision` skips both Cloudflare
and GoatCounter. Setup `--no-secrets` and sync change files only.
The API token remains bootstrap authorization: it is never placed in app items,
browser JavaScript, or deployment environments. Tracking pageviews needs no API key.

Only hosted `https://<site>.goatcounter.com` main-site origins are supported.
Self-hosted/custom API origins require manual setup. App codes must be valid,
unreserved GoatCounter codes (2–50 characters); unavailable global names fail
rather than adopting someone else's site or silently choosing another URL.
The API is unversioned `/api/v0`; unexpected response shapes are refused.
See [GoatCounter's API documentation](https://www.goatcounter.com/help/api).

### GitHub is the registry, not the deployment runner

Kamal builds and deploys from your machine; no GitHub Actions workflow is generated.
The default registry is `ghcr.io`, username/namespace `tamayotchi`, with image
`ghcr.io/tamayotchi/<app-slug>`.

Create a **classic PAT**, not a fine-grained PAT or an OAuth token, using the
[package-only token creation page](https://github.com/settings/tokens/new?scopes=write:packages).
Select package read/write access, a suitable expiration, and authorize SSO if your
organization requires it. Avoid `repo`, `workflow`, and `delete:packages`; the
registry does not need those scopes. A classic PAT's package permissions cover the
packages the account can access; they are not restricted to one application's image.

Save it once as `KAMAL_REGISTRY_PASSWORD` in the shared bootstrap item. The tool
copies it into each app's uppercase item, but never changes existing non-empty
values. Replacing an expired bootstrap PAT does not rotate existing app items;
update their registry credentials explicitly as part of that rotation. Your normal
`gh` OAuth login can remain unchanged: no token is extracted
from it or silently granted more permissions. `gh auth token` retrieves an existing
credential; it cannot mint a classic package-scoped PAT.

Bootstrap reuse checks for a conventional GHCR destination and classic PAT format.
It does not remotely validate the token's scopes, expiration, username, or package
access. Explicit environment imports and `--no-provision` remain available for
other registries. Existing Docker Hub/custom registry configurations are preserved:
when migrating, explicitly set `registry.server: ghcr.io`, review username/image,
and replace the registry credential yourself. The tool never rotates it implicitly.

Then, for each application:

```sh
mix tamayotchi.new my_app --yes
# Add optional application object storage:
mix tamayotchi.new another_app --r2 --yes
# Or configure an existing repository:
mix tamayotchi.setup --yes
```

The application item (`SERVER/MY_APP`, for example) is created automatically.
Managed Phoenix always includes SQLite backup credentials, even for older manifests
that omitted backups; application R2 storage is independent.

## What happens automatically

| Selected feature | Application fields | Missing-value behavior |
| --- | --- | --- |
| Phoenix | `SECRET_KEY_BASE` | Generate 48 cryptographically random bytes, Base64-encoded |
| Phoenix / GoatCounter | Concealed creation checkpoint; no runtime API token | Reuse an owned site or create the app's child site |
| Kamal (included with Phoenix) | `KAMAL_REGISTRY_PASSWORD` | Copy only this field from the bootstrap item |
| R2 | `R2_ACCOUNT_ID` | Use the bootstrap Cloudflare account |
| R2 | `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY` | Issue a bucket-scoped object read/write token |
| SQLite | `LITESTREAM_ENDPOINT` | Derive the Cloudflare S3 endpoint |
| SQLite | `LITESTREAM_ACCESS_KEY_ID`, `LITESTREAM_SECRET_ACCESS_KEY` | Issue a separate bucket-scoped backup token |

Every generated managed field uses 1Password's **Password/concealed** type,
including account IDs, endpoints, and provisioning markers. Existing managed text
fields are converted to concealed on the next accepted secrets run without changing
their values, IDs, or unrelated fields. Item titles and field labels remain visible.
The confirmation plan includes these presentation changes; `--only` limits the fields changed.

Only missing values are filled. Explicit environment variables of the same name
can import externally issued credentials instead; existing item values always
win. `CLOUDFLARE_ACCOUNT_ID`, `CLOUDFLARE_API_TOKEN`, `GOATCOUNTER_SITE_URL`, and
`GOATCOUNTER_API_TOKEN` environment variables may supply bootstrap configuration
in CI, without storing them in source files.

For Cloudflare issuance, the tool creates missing buckets or reuses existing ones
without changing their configuration. It uses account-owned tokens with only the
**Workers R2 Storage Bucket Item Write** permission on the individual bucket—not
administrative deployment credentials. Access Key ID is the returned token ID;
Secret Access Key is the SHA-256 hash of its one-time token value.

Defaults are the hyphenated application name for storage (short names gain a
`-storage` suffix) and `<hyphenated-app>-db-backups` for SQLite. With Kamal, actual
literal `env.clear` bucket settings in `config/deploy.yml` are used. Duplicate
keys (including quoted spellings), dynamic layouts, and YAML document directives
are refused. Quote numeric/date/boolean-looking bucket names to avoid YAML changing
the value. Without
Kamal, `R2_BUCKET` and `LITESTREAM_BUCKET_NAME` environment overrides are supported;
supply the same bucket settings to your runtime. Backup buckets must be separate
from application storage, with public r2.dev and custom-domain access disabled.
This check does not audit Workers or other applications exposing bucket contents.

Only default-jurisdiction R2 is automated. Dynamic/ambiguous deployment settings,
other S3 endpoints, incomplete credential pairs, and mismatched account/endpoint
values require explicit manual imports; the tool does not guess or rotate keys.
Public URLs, custom domains, DNS, and production deployment remain application-owned.
Kamal scopes Litestream credentials to `servers.backup.env.secret`, not the global
web environment. Sync migrates exact old generated credential blocks; customized
or ambiguous blocks require manual reconciliation. Phoenix always includes SQLite,
Kamal, the backup runtime tools, and the schedule; standalone backup installation
for plain Mix apps is not supported.

Older Phoenix apps without Kamal should run `mix tamayotchi.sync` to install its
files and update the manifest, then `mix tamayotchi.secrets --yes` if credentials
are missing. Sync never reads or writes provider credentials.

## Offline setup, confirmation, and recovery commands

```sh
mix tamayotchi.new my_app --no-secrets --yes
mix tamayotchi.setup --no-secrets --yes
mix tamayotchi.sync --yes               # files only; never provisions credentials

mix tamayotchi.secrets                 # shows the plan, then asks for confirmation
mix tamayotchi.secrets --yes            # finish/retry after checking prior failures
mix tamayotchi.secrets --only SECRET_KEY_BASE
mix tamayotchi.secrets --no-provision --yes  # generate Phoenix key/import other fields only
```

`--no-secrets` is a per-invocation escape hatch for offline work/CI, not saved
feature state. It does not disable backups. There is no `--dry-run` option;
removed flags are rejected rather than silently applying changes. Declined diffs,
patching conflicts, and sync never run the queued credential task. If credentials
fail after setup, generated files remain: fix bootstrap/access and rerun the
secrets task instead of recreating the project.

The standalone secrets command displays names/actions, then asks for confirmation
(default: no), unless `--yes` is supplied. All selected inputs and provider checks
must pass before any writes start. `--only FIELD,FIELD` deliberately scopes a
partial operation; access-key pairs must be selected together. Completing an
existing pair requires both matching values, not an unrelated new half. That
matching-half proof is retained through replanning, including `--no-provision`.
The bootstrap item cannot be an application destination, even in partial/manual mode.

## Destinations and service accounts

The destination comes from the conventional literal `.kamal/secrets` fetch line,
without executing shell. Otherwise the stack account, `SERVER`, and uppercase app
name apply. `--account HOST`, `--vault NAME_OR_ID`, and `--item TITLE_OR_ID` explicitly
override it. `--account` is the sign-in hostname, not an account shorthand. Overrides
do **not** rewrite deployment references. Custom secret layouts require explicit
destination flags. `--bootstrap-item TITLE_OR_ID` selects another separate item in
the same account and vault.

For CI, a separately authorized `OP_SERVICE_ACCOUNT_TOKEN` can authenticate op.
It needs vault read/write access, including item creation/editing and bootstrap
reads. Desktop sign-in and the CLI account selector are omitted for service accounts,
but `whoami`'s account hostname is still verified. No vault, service account, or
bootstrap token is created automatically. Never pass the service-account token into the app.

## Interrupted writes and safety boundaries

Existing items are edited by ID after checking their version/content; saved fields
and preserved metadata are read back and verified. Ambiguous names, duplicate
credential labels/field IDs, unsupported field types, attachments, and passkeys are refused.
Supported item categories: Secure Note, Password, API Credential, and Server.
Unrelated fields, notes, sections, tags, URLs, and compatible field IDs are preserved.

There is **no cross-provider transaction or atomic compare-and-swap**. Don't run
concurrent writers. Local/generated/imported values are saved first. Before each
Cloudflare write, a non-secret `TAMAYOTCHI_R2_PROVISIONING` or
`TAMAYOTCHI_BACKUPS_PROVISIONING` marker is durably saved in the app item. Each issued
pair is saved immediately, before attempting the next provider operation.

Markers remain as provenance after success. A marker with an incomplete pair
blocks automatic reissuance after a crash, timeout, or failed vault write. Existing
Cloudflare token names also block reissuance, with pagination checked. No writes
are retried, and no buckets, tokens, or backups are automatically deleted/revoked.

After an ambiguous failure:

1. Inspect the application item and the Cloudflare token named by its marker.
2. If the complete pair was saved, preserve it; rerunning will not rotate it.
3. If a token was created but its one-time secret was lost, reconcile/revoke that
   token manually before removing the corresponding marker and explicitly retrying.
   Do not clear markers blindly. Other successfully saved credentials remain intact.

Let Kamal load `.kamal/secrets`; **do not source or run it as a shell script**.
Kamal 2's dotenv integration evaluates `kamal secrets fetch/extract` in process.
Running those substitutions manually in a shell can put expanded credentials in
process arguments. Native Kamal 2.10.1 loading of the concealed fields was verified.

Secret JSON goes to op through stdin, with caching/debug output disabled. A framed,
process-local CLI session keeps the same parent across every request, including
read-back verification. It closes on completion/error, bounds each request to 120
seconds by default and the parent lifetime to one hour, and never reopens/retries a
failed session automatically. Bash pipefail detects an early/failed stdin reader;
startup files/exported functions are disabled, broken pipes are redacted, and
TERM-resistant descendants are killed after a bounded grace period. JSON never
enters shell variables or temporary files.
Cloudflare
uses a fixed HTTPS origin, verified TLS, timeouts, and no redirects or retries.
Responses/errors are captured and redacted. Credential values are never command
arguments, logs, temporary files, generated files, or Igniter diffs. This does not
protect against a compromised workstation or privileged process/memory inspection.
Doctor checks installed files, not credential validity, backup freshness, or recovery.

Automated tests use synthetic clients and a fake CLI/vault; the smoke script never
touches real accounts. A separate manual `/tmp` test verified real 1Password item
creation and unchanged credentials on rerun. A full app also successfully provisioned
real Cloudflare storage/backup buckets and saved separate scoped credentials.
Live upload/download, cross-bucket access denial, two WAL snapshots and integrity-checked
R2 restore, and GHCR authentication have now been verified. No production deployment
or registry image publication was performed. See [the production review](production-review.md)
for evidence, operational gates, and the credential-scope finding.

## Provider references

- [1Password JSON item templates](https://developer.1password.com/docs/cli/item-template-json/)
- [1Password service accounts](https://developer.1password.com/docs/service-accounts/)
- [Cloudflare R2 authentication and bucket-scoped policies](https://developers.cloudflare.com/r2/api/tokens/)
- [Create an account-owned API token](https://developers.cloudflare.com/api/resources/accounts/subresources/tokens/methods/create/)
- [Create an R2 bucket](https://developers.cloudflare.com/api/resources/r2/subresources/buckets/methods/create/)
