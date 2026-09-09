# Production review — 2026-09-09

Scope: the development-time generator/configurator and generated single-host,
amd64, Phoenix/SQLite/Kamal 2 application. No deployment or registry image
publication was performed. This is not certification of a running production service.

The SQLite/no-Kamal generation check below records the earlier optional-Kamal
behavior. SQLite, Kamal, and backups are now required with Phoenix; plain Mix apps
omit that scaffolding. Database-free Phoenix generation is no longer supported.
Current setup/sync behavior is documented in the main README.

## Review fixes

- Backup credentials moved from global `env.secret` to `servers.backup.env.secret`.
  The web container must not receive offsite backup keys. Exact older generated
  blocks migrate on sync; custom blocks conflict rather than being overwritten.
  Doctor and the generated-project smoke test check this separation.
- Matching partial credential-pair imports retain their validation evidence across
  replanning, including manual `--no-provision` mode.
- Provisioning refuses ambiguous YAML keys (including quoted duplicate spellings),
  nested/multiple clear blocks, dynamic documents, and implicitly typed bucket names.
- Application credentials cannot target the shared bootstrap item, even during
  manual/partial setup. Duplicate or missing field IDs are rejected before edits.
- All managed fields are concealed, including IDs, endpoints, and markers; legacy
  types are migrated without changing values or field IDs.
- One bounded Bash parent is reused for each credential command. Startup files and
  exported functions are disabled; pipeline failures, broken pipes, and stubborn
  descendants fail safely. Failed sessions cannot automatically retry a write.
- Root and installer precommit aliases now correctly use `--warnings-as-errors`.

## Verification performed

- Root precommit: **115 tests passed**. Installer precommit: **6 tests passed**.
  Both enforce compiler warnings and formatting, with failure-path regressions.
- Generated-project smoke: compilation, tests, assets, release, sync/idempotence,
  doctor, YAML/credential-role checks, and synthetic CLI/vault integration.
- Real pinned-binary SQLite WAL backup/restore with a local replica.
- Real 1Password field concealment with unchanged values/IDs; whole-item/version
  preservation on rerun using the persistent CLI parent.
- Real Cloudflare account-token policies: active, object-only, exactly one bucket.
- Real generated R2 adapter upload and byte-for-byte download.
- Both directions of cross-bucket access denial (HTTP 403).
- Backup bucket r2.dev/custom-domain privacy checks.
- Two real Litestream snapshots to R2 while committed data was in SQLite WAL;
  restore included both rows and passed full integrity checks. Restoring over the
  live database or an existing destination was refused.
- Real `tamayotchi.new` with SQLite but no Kamal/application R2: default credential
  provisioning, generated tests, and doctor succeeded.
- Native Kamal 2.10.1 loaded all concealed fields through its in-process dotenv
  adapter. Do not execute/source `.kamal/secrets` as a standalone shell script.
- GitHub identity and GHCR bearer authentication succeeded. Registry tokens were
  treated as opaque; no push/pull of an image was performed.
- Full generated Docker image built locally; non-root UID, writable SQLite storage,
  pinned runtime tools, and cron syntax verified with networking disabled.
- A live-value scan found no matching credentials in source, generated project
  files, review scripts, or logs. Provider values were loaded only into memory.
- `mix hex.audit`: no retired dependencies in root or installer. This is a
  retirement check, not a comprehensive vulnerability audit.

Temporary evidence and fixtures: `/tmp/tamayotchi-review-gVZ0fR/`. These contain
scripts, redacted logs, and synthetic test databases, never credential values.
The workspace is temporary and can disappear; the assertions above record the
review result rather than depending on those files for future operation.

## Required before production rollout

1. **Narrow the GitHub PAT.** The tested credential has `repo, write:packages`.
   Remove `repo`; GHCR needs only package read/write permissions. The tool checks
   bootstrap PAT format, not remote permission scope. No credential was rotated.
   If replacing the PAT instead of editing its scopes, explicitly update both the
   bootstrap item and existing app items: missing-only setup never rotates them.
2. Restrict the powerful Cloudflare bootstrap authorization to the intended account
   and required permissions where possible. The generated app tokens were verified
   to be narrow even though the bootstrap token is broadly authorized.
3. Review real hosts, SSH access, registry namespace, volume, bucket/prefix, and
   network/proxy configuration. Defaults are conventions, not a universal deployment.
4. Deploy both web and backup roles, confirm the running scheduler/timezone, perform
   a restore drill with representative data, and configure missed-job alerts.
   Daily snapshots can lose changes since the last successful job. Doctor does not
   prove freshness, monitoring, or scheduling on a live host.
5. Complete an actual registry build/push/pull/deploy test after credential scope
   review. The local Docker build and registry authentication do not prove rollout.

Do not extend this review to umbrellas, multiple repositories/databases/hosts,
other architectures, custom S3 providers, or heavily customized deployment layouts
without separate validation. App-owned changes are preserved; inspect conflicts
and generated diffs rather than force-overwriting them.

## Retained test resources

Nothing was deployed, rotated, revoked, or automatically deleted. For optional
manual cleanup, inspect these test resources first:

- `SERVER/TL_PHOENIX_09051559_890DC6`
- `SERVER/TL_FULL_09051559_890DC6`
- `SERVER/TL_SQLITE_09051559_890DC6`
- R2 buckets `tl-full-09051559-890dc6`,
  `tl-full-09051559-890dc6-db-backups`, and
  `tl-sqlite-09051559-890dc6-db-backups`.
- The full app's storage probe and SQLite replica use `tamayotchi-integration/`
  prefixes. Test token names are recorded in each app item's concealed provisioning
  markers; reconcile those markers before removing or recreating credentials.
- Local image `tamayotchi-live-review:0909`.

Keep `SERVER/TAMAYOTCHI_BOOTSTRAP`; it is shared provisioning authorization, not
an application-specific disposable test item.
