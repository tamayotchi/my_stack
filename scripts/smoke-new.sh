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
  mix tamayotchi.new smoke_app --yes

cd "$app_path"
test -d .git
test -f config/deploy.yml
test -f .kamal/secrets
test -f rel/overlays/bin/docker-entrypoint
rg -q -- "- 192.168.1.39" config/deploy.yml
rg -q "host: smoke-app.tamayotchi.com" config/deploy.yml
rg -q -- "--from SERVER/SMOKE_APP KAMAL_REGISTRY_PASSWORD SECRET_KEY_BASE" .kamal/secrets
sh -n .kamal/secrets rel/overlays/bin/server rel/overlays/bin/migrate rel/overlays/bin/docker-entrypoint
ruby -e 'require "yaml"; YAML.safe_load_file("config/deploy.yml", aliases: true)'

mix compile --warnings-as-errors
mix assets.build
mix test
MIX_ENV=prod mix release
mix tamayotchi.sync --yes
mix tamayotchi.doctor --format json --check

echo "Tamayotchi Stack generated-project smoke test passed."
