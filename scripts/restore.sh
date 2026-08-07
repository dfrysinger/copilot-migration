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
  --replace-databases        Replace existing session index database families
  --restore-config           Restore included configuration
  --restore-skills           Restore included skills and skill state
  --restore-mailbox          Restore included mailbox state
  -h, --help                 Show this help

Existing data replaced during a successful restore is moved to a timestamped
backup. A failed restore rolls destination changes back.
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

BUNDLE=$(existing_absolute_path "$BUNDLE")
COPILOT_HOME=$(absolute_path "$COPILOT_HOME")
"$SCRIPT_DIR/verify.sh" "$BUNDLE"

for request in \
  "$RESTORE_CONFIG:config.tar.gz" \
  "$RESTORE_SKILLS:skills.tar.gz" \
  "$RESTORE_MAILBOX:mailbox.tar.gz"; do
  requested=${request%%:*}
  archive_name=${request#*:}
  if [ "$requested" -eq 1 ] && [ ! -f "$BUNDLE/payload/$archive_name" ]; then
    die "bundle does not contain $archive_name"
  fi
done

mkdir -p "$COPILOT_HOME"
refuse_live_sessions "$COPILOT_HOME/session-state"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/copilot-migration-restore.XXXXXX")
BACKUP_ROOT="$COPILOT_HOME/migration-backup-$(date -u +%Y%m%dT%H%M%SZ)-$$"
TRANSACTION_LOG="$WORK/transaction.tsv"
touch "$TRANSACTION_LOG"
COMMITTED=0
STAGE_COUNTER=0

rollback_restore() {
  local action
  local target
  local backup

  [ "$COMMITTED" -eq 0 ] || return 0
  [ -s "$TRANSACTION_LOG" ] || return 0
  note "Restore failed; rolling back destination changes." >&2
  tail -r "$TRANSACTION_LOG" |
    while IFS="$(printf '\t')" read -r action target backup; do
      case "$action" in
        new)
          rm -rf "$target"
          ;;
        replace)
          rm -rf "$target"
          if [ -e "$backup" ]; then
            mkdir -p "$(dirname "$target")"
            mv "$backup" "$target"
          fi
          ;;
      esac
    done
}

cleanup_restore() {
  status=$?
  trap - EXIT
  rollback_restore
  rm -rf "$WORK"
  exit "$status"
}
trap cleanup_restore EXIT

transaction_install() {
  local source="$1"
  local target="$2"
  local relative="$3"
  local stage
  local backup="$BACKUP_ROOT/$relative"

  STAGE_COUNTER=$((STAGE_COUNTER + 1))
  stage="$COPILOT_HOME/.migration-stage.$$.$STAGE_COUNTER"
  rm -rf "$stage"
  cp -pR "$source" "$stage"
  if [ -e "$target" ]; then
    mkdir -p "$(dirname "$backup")"
    mv "$target" "$backup"
    printf 'replace\t%s\t%s\n' "$target" "$backup" >> "$TRANSACTION_LOG"
  else
    printf 'new\t%s\t\n' "$target" >> "$TRANSACTION_LOG"
  fi
  mv "$stage" "$target"
}

paths_equal() {
  local left="$1"
  local right="$2"
  local status

  if [ -d "$left" ] && [ -d "$right" ]; then
    set +e
    diff -qr -x 'inuse.*.lock' "$left" "$right" >/dev/null 2>&1
    status=$?
    set -e
  elif [ -f "$left" ] && [ -f "$right" ]; then
    set +e
    cmp -s "$left" "$right"
    status=$?
    set -e
  else
    return 1
  fi
  [ "$status" -ne 2 ] || die "could not compare $left and $right"
  [ "$status" -eq 0 ]
}

tar -xzf "$BUNDLE/payload/session-state.tar.gz" -C "$WORK"
SOURCE_SESSIONS="$WORK/session-state"
TARGET_SESSIONS="$COPILOT_HOME/session-state"
[ -d "$SOURCE_SESSIONS" ] || die "session archive does not contain session-state"
mkdir -p "$TARGET_SESSIONS"
SESSION_LIST="$WORK/session-list.txt"
find "$SOURCE_SESSIONS" -mindepth 1 -maxdepth 1 -print > "$SESSION_LIST"

# Preflight every collision before changing session data.
while IFS= read -r source; do
  id=$(basename "$source")
  target="$TARGET_SESSIONS/$id"
  [ -e "$target" ] || continue
  if paths_equal "$source" "$target"; then
    continue
  fi
  if [ "$SESSION_CONFLICT" = "abort" ]; then
    die "session $id differs at destination; choose --session-conflict keep or replace"
  fi
done < "$SESSION_LIST"

restored=0
skipped=0
replaced=0
while IFS= read -r source; do
  id=$(basename "$source")
  target="$TARGET_SESSIONS/$id"
  if [ ! -e "$target" ]; then
    transaction_install "$source" "$target" "session-state/$id"
    restored=$((restored + 1))
    continue
  fi
  if paths_equal "$source" "$target"; then
    skipped=$((skipped + 1))
    continue
  fi
  if [ "$SESSION_CONFLICT" = "keep" ]; then
    skipped=$((skipped + 1))
  elif [ "$SESSION_CONFLICT" = "replace" ]; then
    transaction_install "$source" "$target" "session-state/$id"
    replaced=$((replaced + 1))
  else
    die "unexpected session conflict mode: $SESSION_CONFLICT"
  fi
done < "$SESSION_LIST"

# SQLite-style database files and their sidecars are one replacement unit.
for base in session-store.db data.db; do
  source_base="$BUNDLE/payload/$base"
  target_base="$COPILOT_HOME/$base"
  [ -f "$source_base" ] || continue
  if [ -e "$target_base" ] && [ "$REPLACE_DATABASES" -ne 1 ]; then
    note "Keeping existing database family: $target_base"
    continue
  fi

  for suffix in '' -wal -shm; do
    target="$COPILOT_HOME/$base$suffix"
    if [ -e "$target" ]; then
      backup="$BACKUP_ROOT/$base$suffix"
      mkdir -p "$(dirname "$backup")"
      mv "$target" "$backup"
      printf 'replace\t%s\t%s\n' "$target" "$backup" >> "$TRANSACTION_LOG"
    fi
  done
  for suffix in '' -wal -shm; do
    source="$BUNDLE/payload/$base$suffix"
    target="$COPILOT_HOME/$base$suffix"
    [ -f "$source" ] || continue
    transaction_install "$source" "$target" "$base$suffix"
  done
done

restore_archive() {
  local archive_name="$1"
  local requested="$2"
  local archive="$BUNDLE/payload/$archive_name"
  local stage="$WORK/${archive_name%.tar.gz}"
  local list="$WORK/${archive_name%.tar.gz}-list.txt"
  local source
  local name
  local target

  [ "$requested" -eq 1 ] || return 0
  mkdir -p "$stage"
  tar -xzf "$archive" -C "$stage"
  find "$stage" -mindepth 1 -maxdepth 1 -print > "$list"
  while IFS= read -r source; do
    name=$(basename "$source")
    target="$COPILOT_HOME/$name"
    transaction_install "$source" "$target" "$name"
  done < "$list"
}

restore_archive config.tar.gz "$RESTORE_CONFIG"
restore_archive skills.tar.gz "$RESTORE_SKILLS"
restore_archive mailbox.tar.gz "$RESTORE_MAILBOX"

COMMITTED=1
note "Sessions restored: $restored"
note "Sessions unchanged or kept: $skipped"
note "Sessions replaced: $replaced"
if [ -d "$BACKUP_ROOT" ]; then
  note "Replaced destination data was saved to: $BACKUP_ROOT"
fi
note "Restore complete. Start Copilot CLI and resume a migrated session."
