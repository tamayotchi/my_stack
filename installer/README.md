# Tamayotchi Stack New

Global Mix archive providing `mix tamayotchi.new`.

```sh
MIX_ENV=prod mix archive.build
mix archive.install --force tamayotchi_stack_new-0.1.0.ez
mix tamayotchi.new my_app
```

The installer derives the target directory and root module from `my_app`, and
always initializes Git. It asks only about Phoenix, optional Cloudflare R2
storage, and whether to use `kamal-proxy`. Phoenix always includes SQLite,
GoatCounter, Kamal, and daily backups. There are no separate SQLite/Kamal/backup
flags or questions. `--no-phoenix` creates a plain Mix app without database or
deployment scaffolding, and omits the proxy question.
R2 defaults to off, including with `--yes`:

```sh
mix tamayotchi.new my_app --r2 --yes
mix tamayotchi.new my_app --no-r2 --yes
```

The generated app owns the storage behaviour and adapters, so another backend
such as S3 can be configured later without changing callers.

Backups have no separate flag or prompt and are independent of application R2
storage. Phoenix + SQLite gets a daily Litestream backup role automatically,
including pinned runtime tools and a recovery guide. Deploy the role and verify
a backup/restore before relying on the schedule.

Credentials are set up in 1Password **automatically by default**, after configuration.
Authenticate `op` and configure `SERVER/TAMAYOTCHI_BOOTSTRAP` once with your shared
package-scoped GitHub classic PAT and Cloudflare provisioning authorization. Subsequent projects get
new Phoenix secrets, separate bucket-scoped R2/backup keys, and their GoatCounter
site without another command. Set `GOATCOUNTER_SITE_URL` and `GOATCOUNTER_API_TOKEN`
in that bootstrap item once, with Read sites/Create sites permissions. Existing values are preserved. See [the bootstrap guide](../docs/secrets.md).
Use `--no-secrets` for offline/file-only generation; this does not disable backups.

Kamal runs locally and uses `ghcr.io/tamayotchi/<app-slug>` as the registry. No
GitHub Actions workflow is generated. Set bootstrap credentials once; subsequent
apps get their credentials in `SERVER/<UPPERCASE_APP>`. The GitHub PAT and Cloudflare
provisioning token only need replacement when they expire or are revoked.
