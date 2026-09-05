#!/usr/bin/env bash
# Exercise generated release scripts against a local Litestream replica, never a cloud bucket.
set -euo pipefail
release=${1:?Usage: smoke-backups.sh /path/to/generated/release}
release=$(realpath "$release")
workspace=$(mktemp -d "${TMPDIR:-/tmp}/tamayotchi-backups-smoke-XXXXXX")
writer_pid=
cleanup() {
  if [ -n "$writer_pid" ]; then kill "$writer_pid" 2>/dev/null || true; wait "$writer_pid" 2>/dev/null || true; fi
  rm -rf "$workspace"
}
trap cleanup EXIT

curl --fail --show-error --location --retry 3 \
  https://github.com/benbjohnson/litestream/releases/download/v0.5.17/litestream-0.5.17-linux-x86_64.tar.gz \
  -o "$workspace/litestream.tar.gz"
echo "cfb371176d164437ae869f8351cfde49bd1804ae71c61923f75c9cba9c9c006d  $workspace/litestream.tar.gz" | sha256sum -c -
tar -C "$workspace" -xzf "$workspace/litestream.tar.gz" litestream
curl --fail --show-error --location --retry 3 \
  https://github.com/aptible/supercronic/releases/download/v0.2.49/supercronic-linux-amd64 \
  -o "$workspace/supercronic"
echo "a53ae236602c7338aba3fbaff40bda6300eae3b9fedb8261eb06cfe3724430c1  $workspace/supercronic" | sha256sum -c -
chmod +x "$workspace/litestream" "$workspace/supercronic"
export PATH="$workspace:$PATH"
supercronic -test "$release/etc/backup.cron"

export DATABASE_PATH="$workspace/live.db" LITESTREAM_CONFIG="$workspace/local.yml"
# The generated env validator still runs; these dummy values are not used by the file replica.
export LITESTREAM_ENDPOINT=https://unused.example.test
export LITESTREAM_ACCESS_KEY_ID=test-only LITESTREAM_SECRET_ACCESS_KEY=test-only
printf 'snapshot:\n  interval: 24h\n  retention: 168h\ndbs:\n  - path: %s\n    replica:\n      type: file\n      path: %s\n' \
  "$DATABASE_PATH" "$workspace/replica" > "$LITESTREAM_CONFIG"

# Keep a SQLite connection open so committed data remains in WAL during backup.
python3 - "$DATABASE_PATH" "$workspace/ready" <<'PY' &
import pathlib, sqlite3, sys, time
connection = sqlite3.connect(sys.argv[1])
connection.execute('PRAGMA journal_mode=WAL')
connection.execute('PRAGMA wal_autocheckpoint=0')
connection.execute('CREATE TABLE items (value TEXT)')
connection.execute("INSERT INTO items VALUES ('first')")
connection.commit()
pathlib.Path(sys.argv[2]).touch()
time.sleep(600)
PY
writer_pid=$!
for _ in {1..100}; do
  [ -f "$workspace/ready" ] && break
  sleep 0.1
done
test -f "$workspace/ready"
test -s "$DATABASE_PATH-wal"

sh "$release/bin/litestream-backup"
sqlite3 "$DATABASE_PATH" "INSERT INTO items VALUES ('second');"
sh "$release/bin/litestream-backup"
sh "$release/bin/litestream-list"
sh "$release/bin/litestream-restore" "$workspace/restored.db"
test "$(sqlite3 "$workspace/restored.db" 'SELECT group_concat(value) FROM items;')" = first,second
test "$(sqlite3 "$workspace/restored.db" 'PRAGMA integrity_check;')" = ok

# Recovery must never overwrite a live or previously restored database.
if sh "$release/bin/litestream-restore" "$DATABASE_PATH"; then exit 1; fi
if sh "$release/bin/litestream-restore" "$workspace/restored.db"; then exit 1; fi
if DATABASE_PATH="$workspace/missing.db" sh "$release/bin/litestream-backup"; then exit 1; fi

echo 'SQLite WAL backup/restore smoke test passed (local replica, real pinned binaries).'
