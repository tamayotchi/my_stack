#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
workspace=$(mktemp -d "${TMPDIR:-/tmp}/tamayotchi-stack-smoke-XXXXXX")
trap 'rm -rf "$workspace"' EXIT

archive_dir="$workspace/archives"
app_path="$workspace/smoke_app"
mkdir -p "$archive_dir"

cd "$root/installer"
MIX_ENV=prod mix archive.build
installed_archives=$(mix archive | awk -F': ' '/Archives installed at:/ {print $2}')
cp -a "$installed_archives"/. "$archive_dir"/
MIX_ARCHIVES="$archive_dir" mix archive.install --force tamayotchi_stack_new-0.1.0.ez

cd "$workspace"
MIX_ARCHIVES="$archive_dir" TAMAYOTCHI_STACK_DEV_PATH="$root" \
  mix tamayotchi.new smoke_app --r2 --no-secrets --yes

cd "$app_path"
test -d .git
test -f config/deploy.yml
test -f .kamal/secrets
test -f rel/overlays/etc/backup.cron
test -f rel/overlays/bin/litestream-backup
rg -q 'backup: app exec --reuse --roles backup' config/deploy.yml
rg -q '^  server: ghcr.io$' config/deploy.yml
test ! -f .github/workflows/deploy.yml
rg -q 'LITESTREAM_SECRET_ACCESS_KEY' .kamal/secrets
test -f lib/smoke_app/storage/r2.ex
rg -q 'tamayotchi_r2_storage' config/runtime.exs
rg -q 'R2_BUCKET: smoke-app' config/deploy.yml
rg -q 'R2_SECRET_ACCESS_KEY' .kamal/secrets
test -f rel/overlays/bin/docker-entrypoint
rg -q -- "- home-server" config/deploy.yml
rg -q "host: smoke-app.tamayotchi.com" config/deploy.yml
rg -q -- "--from SERVER/SMOKE_APP KAMAL_REGISTRY_PASSWORD SECRET_KEY_BASE" .kamal/secrets
sh -n .kamal/secrets rel/overlays/bin/server rel/overlays/bin/migrate rel/overlays/bin/docker-entrypoint
ruby -e '
  require "yaml"
  config = YAML.safe_load_file("config/deploy.yml", aliases: true)
  abort "Wrong web host" unless config.fetch("servers").fetch("web") == ["home-server"]
  abort "Backup host differs from web host" unless config.fetch("servers").fetch("backup").fetch("hosts") == ["home-server"]
  backup_keys = %w[LITESTREAM_ENDPOINT LITESTREAM_ACCESS_KEY_ID LITESTREAM_SECRET_ACCESS_KEY]
  abort "Backup keys leaked to global/web environment" unless (config.fetch("env").fetch("secret") & backup_keys).empty?
  abort "Backup keys missing from role" unless (backup_keys - config.fetch("servers").fetch("backup").fetch("env").fetch("secret")).empty?
'

mix compile --warnings-as-errors
mix assets.build
mix test
MIX_ENV=prod mix release
bash "$root/scripts/smoke-backups.sh" "$app_path/_build/prod/rel/smoke_app"

# Exercise release-time R2 validation without making any storage requests.
SECRET_KEY_BASE=$(printf 'test-only-%.0s' {1..8}) \
DATABASE_PATH="$app_path/smoke.db" PHX_HOST=localhost \
R2_ACCOUNT_ID=test-account R2_BUCKET=test-bucket \
R2_ACCESS_KEY_ID=test-access-key R2_SECRET_ACCESS_KEY=test-secret-key \
  _build/prod/rel/smoke_app/bin/smoke_app eval \
  'unless Application.fetch_env!(:smoke_app, :storage)[:adapter] == SmokeApp.Storage.R2, do: raise("wrong release storage adapter")'

mix help tamayotchi.secrets > /dev/null
mix tamayotchi.sync --yes
mix tamayotchi.doctor --format json --check

bash "$root/scripts/smoke-secrets.sh"
echo "Tamayotchi Stack generated-project smoke test passed."
