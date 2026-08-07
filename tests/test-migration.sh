#!/bin/bash

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
BACKUP="$ROOT/scripts/backup.sh"
VERIFY="$ROOT/scripts/verify.sh"
RESTORE="$ROOT/scripts/restore.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/copilot-migration-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_file() {
  [ -f "$1" ] || fail "missing file: $1"
}

assert_contains() {
  grep -q "$2" "$1" || fail "$1 does not contain: $2"
}

assert_not_contains() {
  if grep -q "$2" "$1"; then
    fail "$1 unexpectedly contains: $2"
  fi
}

write_test_manifest() {
  local bundle="$1"
  (
    cd "$bundle"
    {
      printf '%s\n' metadata.txt
      find payload -type f -print
    } | LC_ALL=C sort |
      while IFS= read -r file; do
        shasum -a 256 "$file"
      done
  ) > "$bundle/MANIFEST.sha256"
}

make_source() {
  local home="$1"
  mkdir -p "$home/session-state/session-a/checkpoints" \
    "$home/session-state/.archive/archived-session"
  printf '{"type":"user.message"}\n' > "$home/session-state/session-a/events.jsonl"
  printf 'cwd: /tmp/example\n' > "$home/session-state/session-a/workspace.yaml"
  printf 'checkpoint\n' > "$home/session-state/session-a/checkpoints/001.md"
  printf 'archived\n' > "$home/session-state/.archive/archived-session/events.jsonl"
  printf 'session index\n' > "$home/session-store.db"
  printf 'session wal\n' > "$home/session-store.db-wal"
  printf 'data index\n' > "$home/data.db"
  printf 'instructions\n' > "$home/copilot-instructions.md"
  mkdir -p "$home/skills/example" "$home/skill-state" "$home/mailbox/pending" \
    "$home/agents" "$home/extensions/example" "$home/workflows"
  printf 'skill\n' > "$home/skills/example/SKILL.md"
  printf '{}\n' > "$home/skill-state/state.json"
  printf '{}\n' > "$home/mailbox/pending/message.json"
  printf '{}\n' > "$home/settings.json"
  printf '{"mcpServers":{}}\n' > "$home/mcp-config.json"
  printf 'agent\n' > "$home/agents/example.md"
  printf 'extension\n' > "$home/extensions/example/extension.mjs"
  printf 'workflow\n' > "$home/workflows/example.md"
}

SOURCE="$TMP/source/.copilot"
BUNDLE="$TMP/bundle"
TARGET="$TMP/target/.copilot"
make_source "$SOURCE"

"$BACKUP" --copilot-home "$SOURCE" --output "$BUNDLE" \
  --include-config --include-skills --include-mailbox >/dev/null
"$VERIFY" "$BUNDLE" >/dev/null
[ "$(stat -f '%OLp' "$BUNDLE")" = "700" ] ||
  fail "backup bundle permissions are not owner-only"
"$RESTORE" --bundle "$BUNDLE" --copilot-home "$TARGET" \
  --restore-config --restore-skills --restore-mailbox >/dev/null

assert_file "$TARGET/session-state/session-a/events.jsonl"
assert_file "$TARGET/session-state/.archive/archived-session/events.jsonl"
assert_file "$TARGET/session-store.db"
assert_file "$TARGET/session-store.db-wal"
assert_file "$TARGET/data.db"
assert_file "$TARGET/copilot-instructions.md"
assert_file "$TARGET/skills/example/SKILL.md"
assert_file "$TARGET/mailbox/pending/message.json"
assert_file "$TARGET/agents/example.md"
assert_file "$TARGET/extensions/example/extension.mjs"
assert_file "$TARGET/workflows/example.md"
assert_contains "$TARGET/session-state/session-a/events.jsonl" 'user.message'
assert_contains "$TARGET/copilot-instructions.md" 'instructions'

LOCKED="$TMP/locked/.copilot"
make_source "$LOCKED"
touch "$LOCKED/session-state/session-a/inuse.$$.lock"
if "$BACKUP" --copilot-home "$LOCKED" --output "$TMP/locked-bundle" \
  >/dev/null 2>&1; then
  fail "backup accepted an active session lock"
fi

cp -R "$BUNDLE" "$TMP/corrupt-bundle"
printf 'tamper\n' >> "$TMP/corrupt-bundle/payload/session-store.db"
if "$VERIFY" "$TMP/corrupt-bundle" >/dev/null 2>&1; then
  fail "verification accepted a modified payload"
fi

cp -R "$BUNDLE" "$TMP/extra-payload-bundle"
printf 'not in manifest\n' > "$TMP/extra-payload-bundle/payload/untracked.db"
if "$VERIFY" "$TMP/extra-payload-bundle" >/dev/null 2>&1; then
  fail "verification accepted an unmanifested payload"
fi

cp -R "$BUNDLE" "$TMP/tampered-metadata-bundle"
printf 'tamper=1\n' >> "$TMP/tampered-metadata-bundle/metadata.txt"
if "$VERIFY" "$TMP/tampered-metadata-bundle" >/dev/null 2>&1; then
  fail "verification accepted modified metadata"
fi

cp -R "$BUNDLE" "$TMP/unsafe-manifest-bundle"
printf '%064d  ../escape\n' 0 >> \
  "$TMP/unsafe-manifest-bundle/MANIFEST.sha256"
if "$VERIFY" "$TMP/unsafe-manifest-bundle" >/dev/null 2>&1; then
  fail "verification accepted an unsafe manifest path"
fi

cp -R "$BUNDLE" "$TMP/symlink-payload-bundle"
ln -s session-store.db "$TMP/symlink-payload-bundle/payload/index-link"
if "$VERIFY" "$TMP/symlink-payload-bundle" >/dev/null 2>&1; then
  fail "verification accepted an unmanifested payload symlink"
fi

cp -R "$BUNDLE" "$TMP/unsupported-payload-bundle"
printf 'unsupported\n' > "$TMP/unsupported-payload-bundle/payload/other.db"
write_test_manifest "$TMP/unsupported-payload-bundle"
if "$VERIFY" "$TMP/unsupported-payload-bundle" >/dev/null 2>&1; then
  fail "verification accepted a manifest-tracked unsupported payload"
fi

if "$BACKUP" --copilot-home "$SOURCE" \
  --output "$SOURCE/nested-backup" >/dev/null 2>&1; then
  fail "backup accepted output inside the source state directory"
fi

NO_OPTIONAL="$TMP/no-optional/.copilot"
mkdir -p "$NO_OPTIONAL/session-state/session-b"
printf 'session\n' > "$NO_OPTIONAL/session-state/session-b/events.jsonl"
if "$BACKUP" --copilot-home "$NO_OPTIONAL" \
  --output "$TMP/failed-optional-bundle" \
  --include-mailbox >/dev/null 2>&1; then
  fail "backup accepted a missing requested optional section"
fi
[ ! -e "$TMP/failed-optional-bundle" ] ||
  fail "failed backup left the requested output directory"

printf 'destination version\n' > "$TARGET/session-state/session-a/events.jsonl"
if "$RESTORE" --bundle "$BUNDLE" --copilot-home "$TARGET" \
  >/dev/null 2>&1; then
  fail "restore accepted a conflicting session by default"
fi
grep -q 'destination version' "$TARGET/session-state/session-a/events.jsonl" ||
  fail "collision preflight modified the destination"

"$RESTORE" --bundle "$BUNDLE" --copilot-home "$TARGET" \
  --session-conflict keep >/dev/null
assert_contains "$TARGET/session-state/session-a/events.jsonl" 'destination version'

printf 'destination db\n' > "$TARGET/session-store.db"
printf 'destination wal\n' > "$TARGET/session-store.db-wal"
"$RESTORE" --bundle "$BUNDLE" --copilot-home "$TARGET" \
  --session-conflict replace >/dev/null
assert_contains "$TARGET/session-state/session-a/events.jsonl" 'user.message'
assert_contains "$TARGET/session-store.db" 'destination db'
assert_contains "$TARGET/session-store.db-wal" 'destination wal'

printf 'stale shm\n' > "$TARGET/session-store.db-shm"
"$RESTORE" --bundle "$BUNDLE" --copilot-home "$TARGET" \
  --replace-databases >/dev/null
assert_contains "$TARGET/session-store.db" 'session index'
assert_contains "$TARGET/session-store.db-wal" 'session wal'
[ ! -e "$TARGET/session-store.db-shm" ] ||
  fail "database replacement retained a stale sidecar"

BACKUP_ROOT=$(find "$TARGET" -maxdepth 1 -type d -name 'migration-backup-*' |
  LC_ALL=C sort | tail -1)
[ -n "$BACKUP_ROOT" ] || fail "replacement did not create a backup directory"
assert_file "$BACKUP_ROOT/session-store.db"
assert_contains "$BACKUP_ROOT/session-store.db" 'destination db'

RESTORE_LOCK="$TARGET/session-state/session-a/inuse.$$.lock"
touch "$RESTORE_LOCK"
if "$RESTORE" --bundle "$BUNDLE" --copilot-home "$TARGET" \
  >/dev/null 2>&1; then
  fail "restore accepted an active destination session"
fi
rm -f "$RESTORE_LOCK"

SESSIONS_ONLY="$TMP/sessions-only"
"$BACKUP" --copilot-home "$SOURCE" --output "$SESSIONS_ONLY" >/dev/null
printf 'preflight marker\n' > "$TARGET/preflight-marker"
if "$RESTORE" --bundle "$SESSIONS_ONLY" --copilot-home "$TARGET" \
  --session-conflict keep --restore-mailbox >/dev/null 2>&1; then
  fail "restore accepted a requested archive that was absent"
fi
assert_contains "$TARGET/preflight-marker" 'preflight marker'

ENV_SOURCE="$TMP/environment-source/.copilot"
ENV_BUNDLE="$TMP/environment-bundle"
ENV_TARGET="$TMP/environment-target/.copilot"
make_source "$ENV_SOURCE"
cat > "$ENV_SOURCE/settings.json" <<'EOF'
{"enabledPlugins":{"demo@market":true},"skillDirectories":[]}
EOF
cat > "$ENV_SOURCE/config.json" <<'EOF'
{
  "installedPlugins": [
    {
      "name": "demo",
      "marketplace": "market",
      "enabled": true
    },
    {
      "name": "local-plugin",
      "marketplace": "",
      "enabled": true,
      "source": {
        "source": "github",
        "repo": "example/local-plugin"
      }
    },
    {
      "name": "stale-plugin",
      "marketplace": "",
      "enabled": false,
      "source": {
        "source": "github",
        "repo": "example/stale-plugin"
      }
    }
  ]
}
EOF
cat > "$ENV_SOURCE/mcp-config.json" <<'EOF'
{
  "mcpServers": {
    "local-example": {
      "type": "local",
      "command": "/missing/bin/node",
      "args": ["/missing/server.mjs"]
    },
    "relative-example": {
      "type": "local",
      "command": "missing-runtime",
      "args": ["--serve"]
    }
  }
}
EOF
mkdir -p "$ENV_SOURCE/installed-plugins/_direct/example--local-plugin"
printf '{"name":"local-plugin"}\n' > \
  "$ENV_SOURCE/installed-plugins/_direct/example--local-plugin/plugin.json"
FAKE_BIN="$TMP/fake-bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/copilot" <<'EOF'
#!/bin/bash
case "$1:$2" in
  plugin:list)
    printf 'Installed plugins:\n'
    ;;
  plugin:install)
    printf '%s\n' "$3" >> "$COPILOT_FAKE_LOG"
    ;;
  *)
    printf 'unexpected fake copilot command: %s\n' "$*" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$FAKE_BIN/copilot"

PATH="$FAKE_BIN:$PATH" \
  "$BACKUP" --copilot-home "$ENV_SOURCE" --output "$ENV_BUNDLE" \
  --include-environment >/dev/null
assert_contains "$ENV_BUNDLE/payload/plugins.txt" 'demo@market'
assert_contains "$ENV_BUNDLE/payload/plugins.txt" 'example/local-plugin'
assert_not_contains "$ENV_BUNDLE/payload/plugins.txt" 'example/stale-plugin'

cp -R "$ENV_BUNDLE" "$TMP/invalid-plugin-bundle"
printf '%s\n' '--malicious-option' > \
  "$TMP/invalid-plugin-bundle/payload/plugins.txt"
write_test_manifest "$TMP/invalid-plugin-bundle"
if "$VERIFY" "$TMP/invalid-plugin-bundle" >/dev/null 2>&1; then
  fail "verification accepted an unsafe plugin source"
fi

ENV_REPORT="$TMP/environment-report.txt"
PLUGIN_LOG="$TMP/plugin-installs.txt"
HOME="$TMP/environment-target" PATH="$FAKE_BIN:$PATH" \
  COPILOT_FAKE_LOG="$PLUGIN_LOG" \
  "$RESTORE" --bundle "$ENV_BUNDLE" --copilot-home "$ENV_TARGET" \
  --restore-environment --install-plugins > "$ENV_REPORT"
assert_file "$ENV_TARGET/settings.json"
assert_file "$ENV_TARGET/mcp-config.json"
assert_file "$ENV_TARGET/skills/example/SKILL.md"
assert_file "$ENV_TARGET/agents/example.md"
assert_file "$ENV_TARGET/extensions/example/extension.mjs"
assert_contains "$PLUGIN_LOG" 'demo@market'
assert_contains "$PLUGIN_LOG" 'example/local-plugin'
assert_contains "$ENV_REPORT" 'Unresolved commands or absolute configuration paths'
assert_contains "$ENV_REPORT" '/missing/bin/node'
assert_contains "$ENV_REPORT" '/missing/server.mjs'
assert_contains "$ENV_REPORT" 'missing-runtime'

ROLLBACK_TARGET="$TMP/rollback/.copilot"
mkdir -p "$ROLLBACK_TARGET/session-state"
printf 'preserve\n' > "$ROLLBACK_TARGET/marker"
WRAPPER_DIR="$TMP/wrappers"
mkdir -p "$WRAPPER_DIR"
cat > "$WRAPPER_DIR/mv" <<'EOF'
#!/bin/bash
count=0
[ ! -f "$MV_COUNTER" ] || count=$(cat "$MV_COUNTER")
count=$((count + 1))
printf '%s\n' "$count" > "$MV_COUNTER"
if [ "$count" -eq "$MV_FAIL_AT" ]; then
  exit 70
fi
exec /bin/mv "$@"
EOF
chmod +x "$WRAPPER_DIR/mv"
if PATH="$WRAPPER_DIR:$PATH" MV_COUNTER="$TMP/mv-counter" MV_FAIL_AT=2 \
  "$RESTORE" --bundle "$SESSIONS_ONLY" --copilot-home "$ROLLBACK_TARGET" \
  >/dev/null 2>&1; then
  fail "fault-injected restore unexpectedly succeeded"
fi
assert_contains "$ROLLBACK_TARGET/marker" 'preserve'
[ -z "$(find "$ROLLBACK_TARGET/session-state" -mindepth 1 -maxdepth 1 -print)" ] ||
  fail "failed restore did not roll back earlier session changes"

printf 'All migration tests passed.\n'
