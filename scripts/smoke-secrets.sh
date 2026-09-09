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
                'type': 'CONCEALED', 'value': 'ghp_' + 'a' * 36}]
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
    assert [f['label'] for f in result['fields']] == ['SECRET_KEY_BASE', 'KAMAL_REGISTRY_PASSWORD']
    result.update(id=item, vault={'id': vault}, version=1)
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

export PATH="$workspace/tools:$PATH"
export MIX_ARCHIVES="$workspace/archives"
export TAMAYOTCHI_STACK_DEV_PATH="$root"
export TSTACK_TEST_OP_STATE="$workspace/synthetic-vault.json"
unset SECRET_KEY_BASE KAMAL_REGISTRY_PASSWORD CLOUDFLARE_ACCOUNT_ID CLOUDFLARE_API_TOKEN OP_SERVICE_ACCOUNT_TOKEN

cd "$workspace"
# No --secrets flag and no separate manual secrets command: generation does it.
mix tamayotchi.new credential_app --no-sqlite --yes
cd credential_app
mix compile --warnings-as-errors
mix test

cp "$TSTACK_TEST_OP_STATE" "$workspace/before-dry-run.json"
mix tamayotchi.setup --dry-run --yes
cmp "$TSTACK_TEST_OP_STATE" "$workspace/before-dry-run.json"
mix tamayotchi.sync --yes
cmp "$TSTACK_TEST_OP_STATE" "$workspace/before-dry-run.json"
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
cmp "$TSTACK_TEST_OP_STATE" "$workspace/before-dry-run.json"
test -f config/deploy.yml

# A normal setup rerun checks the vault but never rotates either credential.
mix tamayotchi.setup --yes
mix tamayotchi.doctor --check --format json

python3 - "$TSTACK_TEST_OP_STATE" <<'PY'
import base64, json, pathlib, sys
state = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert state['writes'] == 1
fields = state['item']['fields']
assert len(fields) == 2 and all(f['type'] == 'CONCEALED' for f in fields)
values = {f['label']: f['value'] for f in fields}
assert len(base64.b64decode(values['SECRET_KEY_BASE'])) == 48
assert values['KAMAL_REGISTRY_PASSWORD'] == 'ghp_' + 'a' * 36
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
mix test
mix tamayotchi.sync --yes
mix tamayotchi.doctor --check --format json
cmp "$TSTACK_TEST_OP_STATE" "$workspace/before-plain.json"

echo "Automatic 1Password generated-project smoke test passed (synthetic vault only)."
