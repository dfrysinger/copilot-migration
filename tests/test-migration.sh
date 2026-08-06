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

make_source() {
  local home="$1"
  mkdir -p "$home/session-state/session-a/checkpoints"
  printf '{"type":"user.message"}\n' > "$home/session-state/session-a/events.jsonl"
  printf 'cwd: /tmp/example\n' > "$home/session-state/session-a/workspace.yaml"
  printf 'checkpoint\n' > "$home/session-state/session-a/checkpoints/001.md"
  printf 'session index\n' > "$home/session-store.db"
  printf 'data index\n' > "$home/data.db"
  printf 'instructions\n' > "$home/copilot-instructions.md"
  mkdir -p "$home/skills/example" "$home/skill-state" "$home/mailbox/pending"
  printf 'skill\n' > "$home/skills/example/SKILL.md"
  printf '{}\n' > "$home/skill-state/state.json"
  printf '{}\n' > "$home/mailbox/pending/message.json"
}

SOURCE="$TMP/source/.copilot"
BUNDLE="$TMP/bundle"
TARGET="$TMP/target/.copilot"
make_source "$SOURCE"

"$BACKUP" --copilot-home "$SOURCE" --output "$BUNDLE" \
  --include-config --include-skills --include-mailbox >/dev/null
"$VERIFY" "$BUNDLE" >/dev/null
"$RESTORE" --bundle "$BUNDLE" --copilot-home "$TARGET" \
  --restore-config --restore-skills --restore-mailbox >/dev/null

assert_file "$TARGET/session-state/session-a/events.jsonl"
assert_file "$TARGET/session-store.db"
assert_file "$TARGET/data.db"
assert_file "$TARGET/copilot-instructions.md"
assert_file "$TARGET/skills/example/SKILL.md"
assert_file "$TARGET/mailbox/pending/message.json"

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

printf 'destination version\n' > "$TARGET/session-state/session-a/events.jsonl"
if "$RESTORE" --bundle "$BUNDLE" --copilot-home "$TARGET" \
  >/dev/null 2>&1; then
  fail "restore accepted a conflicting session by default"
fi
grep -q 'destination version' "$TARGET/session-state/session-a/events.jsonl" ||
  fail "collision preflight modified the destination"

"$RESTORE" --bundle "$BUNDLE" --copilot-home "$TARGET" \
  --session-conflict replace >/dev/null
grep -q 'user.message' "$TARGET/session-state/session-a/events.jsonl" ||
  fail "replace mode did not restore the source session"

printf 'All migration tests passed.\n'
