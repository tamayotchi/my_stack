#!/usr/bin/env bash
set -euo pipefail

# End-to-end automatic setup, using a synthetic vault and no cloud integration.
# The fake is first on PATH; no real op invocation or credential import is allowed.
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
workspace=$(mktemp -d "${TMPDIR:-/tmp}/tamayotchi-secrets-smoke-XXXXXX")
trap 'rm -rf "$workspace"' EXIT
mkdir -p "$workspace/archives" "$workspace/tools"

cd "$root/installer"
MIX_ENV=prod mix archive.build
installed_archives=$(mix archive | awk -F': ' '/Archives installed at:/ {print $2}')
cp -a "$installed_archives"/. "$workspace/archives"/
MIX_ARCHIVES="$workspace/archives" mix archive.install --force tamayotchi_stack_new-0.1.0.ez

python3 - "$workspace/tools/op" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
path.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
path = pathlib.Path(os.environ['TSTACK_TEST_OP_STATE'])
state = json.loads(path.read_text()) if path.exists() else {'writes': 0, 'reads': 0, 'item': None}
args = sys.argv[1:]
vault, item = 'v' * 26, 'i' * 26
bootstrap = {
    'id': 'b' * 26, 'title': 'TAMAYOTCHI_BOOTSTRAP', 'category': 'SECURE_NOTE',
    'vault': {'id': vault}, 'version': 1,
    'fields': [{'id': 'r' * 26, 'label': 'KAMAL_REGISTRY_PASSWORD',
                'type': 'CONCEALED', 'value': 'ghp_' + 'a' * 36},
               {'id': 'u' * 26, 'label': 'GOATCOUNTER_SITE_URL', 'type': 'CONCEALED',
                'value': 'https://smoke-parent.goatcounter.com'},
               {'id': 'g' * 26, 'label': 'GOATCOUNTER_API_TOKEN', 'type': 'CONCEALED',
                'value': 'g' * 48}]
}
if args[0] == 'signin':
    sys.exit(0)
elif args[0] == 'whoami':
    result = {'url': 'instaleap-llc.1password.com'}
elif args[:2] == ['vault', 'get']:
    result = {'id': vault}
elif args[:2] == ['item', 'list']:
    result = [bootstrap] + ([state['item']] if state['item'] else [])
elif args[:2] == ['item', 'get']:
    assert args[2] in (item, bootstrap['id'])
    result = bootstrap if args[2] == bootstrap['id'] else state['item']
elif args[:2] == ['item', 'create']:
    assert state['item'] is None
    result = json.load(sys.stdin)
    assert result['title'] == 'CREDENTIAL_APP'
    assert [f['label'] for f in result['fields']] == ['SECRET_KEY_BASE', 'KAMAL_REGISTRY_PASSWORD', 'LITESTREAM_ENDPOINT', 'LITESTREAM_ACCESS_KEY_ID', 'LITESTREAM_SECRET_ACCESS_KEY']
    result.update(id=item, vault={'id': vault}, version=1)
    state['writes'] += 1
    state['item'] = result
elif args[:2] == ['item', 'edit']:
    assert args[2] == item
    result = json.load(sys.stdin)
    assert all(f in result['fields'] for f in state['item']['fields'])
    assert len(result['fields']) == 6
    assert result['fields'][-1]['label'] == 'TAMAYOTCHI_GOATCOUNTER_PROVISIONING'
    result.update(id=item, vault={'id': vault}, version=state['item']['version'] + 1)
    state['writes'] += 1
    state['item'] = result
else:
    sys.exit(1)
state['reads'] += 1
path.write_text(json.dumps(state))
print(json.dumps(result))
''')
path.chmod(0o755)
PY

# Inject only the HTTP transport in a disposable source copy. There is no test
# provider override in the shipped CLI, and no request reaches GoatCounter.
mkdir -p "$workspace/stack"
cp -a "$root/lib" "$root/priv" "$root/mix.exs" "$root/mix.lock" "$workspace/stack/"
python3 - "$workspace/stack" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
http = root / 'lib/tamayotchi_stack/secrets/goat_counter_http.ex'
source = http.read_text()
assert source.count('&Req.request/1') == 1
http.write_text(source.replace('&Req.request/1', '&TamayotchiStack.SmokeGoatTransport.request/1'))
(root / 'lib/tamayotchi_stack/smoke_goat_transport.ex').write_text('''
defmodule TamayotchiStack.SmokeGoatTransport do
  def request(options) do
    true = options[:url] in ["https://smoke-parent.goatcounter.com/api/v0/me", "https://smoke-parent.goatcounter.com/api/v0/sites"]
    true = {"authorization", "Bearer " <> String.duplicate("g", 48)} in options[:headers]
    path = System.fetch_env!("TSTACK_TEST_OP_STATE")
    state = path |> File.read!() |> Jason.decode!()
    sites = Map.get(state, "goat_sites", [%{"id" => 1, "code" => "smoke-parent", "parent" => nil, "state" => "a"}])
    {response, state} = case {options[:method], URI.parse(options[:url]).path} do
      {:get, "/api/v0/me"} -> {%{"token" => %{"permissions" => 24}}, state}
      {:get, "/api/v0/sites"} -> {%{"sites" => sites}, state}
      {:put, "/api/v0/sites"} ->
        payload = Jason.decode!(options[:body])
        "credential-app" = payload["code"]
        false = Enum.any?(sites, &(&1["code"] == payload["code"]))
        created = Map.merge(payload, %{"id" => 2, "parent" => 1, "state" => "a"})
        {created, state |> Map.put("goat_sites", sites ++ [created]) |> Map.update("goat_writes", 1, &(&1 + 1))}
    end
    state = Map.update(state, "goat_requests", 1, &(&1 + 1))
    File.write!(path, Jason.encode!(state))
    {:ok, %{status: 200, body: Jason.encode!(response)}}
  end
end
''')
PY

export PATH="$workspace/tools:$PATH"
export MIX_ARCHIVES="$workspace/archives"
export TAMAYOTCHI_STACK_DEV_PATH="$workspace/stack"
export TSTACK_TEST_OP_STATE="$workspace/synthetic-vault.json"
unset SECRET_KEY_BASE KAMAL_REGISTRY_PASSWORD CLOUDFLARE_ACCOUNT_ID CLOUDFLARE_API_TOKEN OP_SERVICE_ACCOUNT_TOKEN GOATCOUNTER_SITE_URL GOATCOUNTER_API_TOKEN
# Import synthetic backup credentials so the real generator never contacts Cloudflare.
export LITESTREAM_ENDPOINT=https://synthetic-account.r2.cloudflarestorage.com
export LITESTREAM_ACCESS_KEY_ID=synthetic-backup-access
export LITESTREAM_SECRET_ACCESS_KEY=synthetic-backup-secret

cd "$workspace"
# No --secrets flag and no separate manual secrets command: generation does it.
mix tamayotchi.new credential_app --yes
cd credential_app
mix compile --warnings-as-errors
mix test

cp "$TSTACK_TEST_OP_STATE" "$workspace/before-file-only.json"
# Removed options must fail, never silently apply changes or contact providers.
for task in tamayotchi.setup tamayotchi_stack.install tamayotchi.sync tamayotchi.secrets; do
  if mix "$task" --dry-run --yes > "$workspace/removed-option.log" 2>&1; then
    echo "$task incorrectly accepted --dry-run" >&2
    exit 1
  fi
  rg -q 'no longer support --dry-run|Invalid secrets options' "$workspace/removed-option.log"
  cmp "$TSTACK_TEST_OP_STATE" "$workspace/before-file-only.json"
done
mix tamayotchi.setup --no-secrets --yes
cmp "$TSTACK_TEST_OP_STATE" "$workspace/before-file-only.json"
mix tamayotchi.sync --yes
cmp "$TSTACK_TEST_OP_STATE" "$workspace/before-file-only.json"
# An older Phoenix app without Kamal is unhealthy until sync installs it.
# Sync must not read the synthetic vault or provision anything.
printf '[schema: 1, app: :credential_app, features: [phoenix: []]]\n' > .tamayotchi.exs
rm Dockerfile .dockerignore config/deploy.yml .kamal/secrets rel/overlays/bin/server
if mix tamayotchi.doctor --check --format json > "$workspace/legacy-doctor.json"; then
  echo "Doctor incorrectly accepted Phoenix without Kamal" >&2
  exit 1
fi
rg -q '"managed_kamal": true' "$workspace/legacy-doctor.json"
rg -q '"kamal": false' "$workspace/legacy-doctor.json"
mix tamayotchi.sync --yes
cmp "$TSTACK_TEST_OP_STATE" "$workspace/before-file-only.json"
test -f config/deploy.yml

# A normal setup rerun checks the vault but never rotates any credential.
mix tamayotchi.setup --yes
mix tamayotchi.doctor --check --format json

python3 - "$TSTACK_TEST_OP_STATE" <<'PY'
import base64, json, pathlib, sys
state = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert state['writes'] == 2
assert state['goat_writes'] == 1
assert len(state['goat_sites']) == 2
fields = state['item']['fields']
assert len(fields) == 6 and all(f['type'] == 'CONCEALED' for f in fields)
values = {f['label']: f['value'] for f in fields}
assert len(base64.b64decode(values['SECRET_KEY_BASE'])) == 48
assert values['KAMAL_REGISTRY_PASSWORD'] == 'ghp_' + 'a' * 36
assert values['LITESTREAM_ENDPOINT'] == 'https://synthetic-account.r2.cloudflarestorage.com'
assert values['LITESTREAM_ACCESS_KEY_ID'] == 'synthetic-backup-access'
assert values['LITESTREAM_SECRET_ACCESS_KEY'] == 'synthetic-backup-secret'
# No synthetic credential may appear in a generated/source-controlled file either.
for path in pathlib.Path('.').rglob('*'):
    if path.is_file() and not any(p in {'_build', 'deps', '.git'} for p in path.parts):
        assert all(v.encode() not in path.read_bytes() for v in values.values()), str(path)
PY

# Plain Mix applications have neither Kamal nor deployment credentials.
cd "$workspace"
cp "$TSTACK_TEST_OP_STATE" "$workspace/before-plain.json"
mix tamayotchi.new plain_app --no-phoenix --yes
cmp "$TSTACK_TEST_OP_STATE" "$workspace/before-plain.json"
cd plain_app
test ! -f Dockerfile
test ! -f config/deploy.yml
test ! -f .kamal/secrets
test ! -f lib/plain_app/repo.ex
test ! -f rel/overlays/etc/backup.cron
mix test
mix tamayotchi.sync --yes
mix tamayotchi.doctor --check --format json
cmp "$TSTACK_TEST_OP_STATE" "$workspace/before-plain.json"

echo "Automatic 1Password generated-project smoke test passed (synthetic vault only)."
