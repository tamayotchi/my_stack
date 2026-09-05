# Tamayotchi Stack New

Global Mix archive providing `mix tamayotchi.new`.

```sh
MIX_ENV=prod mix archive.build
mix archive.install --force tamayotchi_stack_new-0.1.0.ez
mix tamayotchi.new my_app
```

The installer derives the target directory and root module from `my_app`, and
always initializes Git. It asks about Phoenix, SQLite, optional Cloudflare R2
storage, Kamal, whether Kamal should use `kamal-proxy`, and optional daily SQLite
backups when both SQLite and Kamal are selected. GoatCounter is always
included with Phoenix. R2 defaults to off, including with `--yes`:

```sh
mix tamayotchi.new my_app --r2 --yes
mix tamayotchi.new my_app --no-r2 --yes
mix tamayotchi.new my_app --backups --yes
```

The generated app owns the storage behaviour and adapters, so another backend
such as S3 can be configured later without changing callers.

Backups default to off (`--backups` / `--no-backups`) and are independent of
application R2 storage. They generate a daily Litestream backup role, safe
restore scripts, and an app-owned provisioning/recovery guide.
