#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

usage() {
  cat <<'EOF'
Usage: restore.sh --bundle PATH [options]

Restore or merge a macOS Copilot CLI migration bundle.

Options:
  --bundle PATH              Bundle created by backup.sh
  --copilot-home PATH        Destination state directory (default: ~/.copilot)
  --session-conflict MODE    abort, keep, or replace (default: abort)
  --replace-databases        Replace existing session index databases
  --restore-config           Restore included configuration
  --restore-skills           Restore included skills and skill state
  --restore-mailbox          Restore included mailbox state
  -h, --help                 Show this help

Existing data replaced during restore is moved to a timestamped backup.
EOF
}

BUNDLE=
COPILOT_HOME="${COPILOT_HOME:-$HOME/.copilot}"
SESSION_CONFLICT=abort
REPLACE_DATABASES=0
RESTORE_CONFIG=0
RESTORE_SKILLS=0
RESTORE_MAILBOX=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --bundle)
      [ "$#" -ge 2 ] || die "--bundle requires a path"
      BUNDLE="$2"
      shift 2
      ;;
    --copilot-home)
      [ "$#" -ge 2 ] || die "--copilot-home requires a path"
      COPILOT_HOME="$2"
      shift 2
      ;;
    --session-conflict)
      [ "$#" -ge 2 ] || die "--session-conflict requires a mode"
      SESSION_CONFLICT="$2"
      shift 2
      ;;
    --replace-databases)
      REPLACE_DATABASES=1
      shift
      ;;
    --restore-config)
      RESTORE_CONFIG=1
      shift
      ;;
    --restore-skills)
      RESTORE_SKILLS=1
      shift
      ;;
    --restore-mailbox)
      RESTORE_MAILBOX=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

case "$SESSION_CONFLICT" in
  abort|keep|replace) ;;
  *) die "--session-conflict must be abort, keep, or replace" ;;
esac

[ -n "$BUNDLE" ] || die "--bundle is required"
require_macos
require_command tar
require_command shasum
require_command diff

BUNDLE=$(absolute_path "$BUNDLE")
COPILOT_HOME=$(absolute_path "$COPILOT_HOME")
"$SCRIPT_DIR/verify.sh" "$BUNDLE" >/dev/null

mkdir -p "$COPILOT_HOME"
refuse_live_sessions "$COPILOT_HOME/session-state"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/copilot-migration-restore.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
BACKUP_ROOT="$COPILOT_HOME/migration-backup-$(date -u +%Y%m%dT%H%M%SZ)"

tar -xzf "$BUNDLE/payload/session-state.tar.gz" -C "$WORK"
SOURCE_SESSIONS="$WORK/session-state"
TARGET_SESSIONS="$COPILOT_HOME/session-state"
mkdir -p "$TARGET_SESSIONS"

# Preflight every collision before changing the destination.
for source in "$SOURCE_SESSIONS"/*; do
  [ -d "$source" ] || continue
  id=$(basename "$source")
  target="$TARGET_SESSIONS/$id"
  [ -d "$target" ] || continue
  if diff -qr -x 'inuse.*.lock' "$source" "$target" >/dev/null 2>&1; then
    continue
  fi
  if [ "$SESSION_CONFLICT" = "abort" ]; then
    die "session $id differs at destination; choose --session-conflict keep or replace"
  fi
done

restored=0
skipped=0
replaced=0
for source in "$SOURCE_SESSIONS"/*; do
  [ -d "$source" ] || continue
  id=$(basename "$source")
  target="$TARGET_SESSIONS/$id"
  if [ ! -e "$target" ]; then
    cp -pR "$source" "$target"
    restored=$((restored + 1))
    continue
  fi
  if diff -qr -x 'inuse.*.lock' "$source" "$target" >/dev/null 2>&1; then
    skipped=$((skipped + 1))
    continue
  fi
  if [ "$SESSION_CONFLICT" = "keep" ]; then
    skipped=$((skipped + 1))
  else
    backup_existing "$target" "$BACKUP_ROOT" "session-state/$id"
    cp -pR "$source" "$target"
    replaced=$((replaced + 1))
  fi
done

for name in session-store.db session-store.db-wal session-store.db-shm \
  data.db data.db-wal data.db-shm; do
  source="$BUNDLE/payload/$name"
  target="$COPILOT_HOME/$name"
  [ -f "$source" ] || continue
  if [ -e "$target" ] && [ "$REPLACE_DATABASES" -ne 1 ]; then
    note "Keeping existing database: $target"
    continue
  fi
  if [ -e "$target" ]; then
    backup_existing "$target" "$BACKUP_ROOT" "$name"
  fi
  cp -p "$source" "$target"
done

restore_archive() {
  local archive_name="$1"
  local requested="$2"
  local archive="$BUNDLE/payload/$archive_name"
  local stage="$WORK/${archive_name%.tar.gz}"
  local source
  local name
  local target

  [ "$requested" -eq 1 ] || return 0
  [ -f "$archive" ] || die "bundle does not contain $archive_name"
  mkdir -p "$stage"
  tar -xzf "$archive" -C "$stage"
  for source in "$stage"/*; do
    [ -e "$source" ] || continue
    name=$(basename "$source")
    target="$COPILOT_HOME/$name"
    if [ -e "$target" ]; then
      backup_existing "$target" "$BACKUP_ROOT" "$name"
    fi
    cp -pR "$source" "$target"
  done
}

restore_archive config.tar.gz "$RESTORE_CONFIG"
restore_archive skills.tar.gz "$RESTORE_SKILLS"
restore_archive mailbox.tar.gz "$RESTORE_MAILBOX"

note "Sessions restored: $restored"
note "Sessions unchanged or kept: $skipped"
note "Sessions replaced: $replaced"
if [ -d "$BACKUP_ROOT" ]; then
  note "Replaced destination data was saved to: $BACKUP_ROOT"
fi
note "Restore complete. Start Copilot CLI and resume a migrated session."

