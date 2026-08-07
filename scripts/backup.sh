#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

usage() {
  cat <<'EOF'
Usage: backup.sh [options]

Create a checksummed macOS Copilot CLI migration bundle.

Options:
  --output PATH          Bundle directory (default: ./copilot-backup-TIMESTAMP)
  --copilot-home PATH    Copilot state directory (default: ~/.copilot)
  --include-config       Include user configuration and instructions
  --include-skills       Include ~/.copilot/skills and skill-state
  --include-mailbox      Include ~/.copilot/mailbox
  -h, --help             Show this help

All Copilot CLI sessions must be closed before backup.
EOF
}

OUTPUT=
COPILOT_HOME="${COPILOT_HOME:-$HOME/.copilot}"
INCLUDE_CONFIG=0
INCLUDE_SKILLS=0
INCLUDE_MAILBOX=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --output)
      [ "$#" -ge 2 ] || die "--output requires a path"
      OUTPUT="$2"
      shift 2
      ;;
    --copilot-home)
      [ "$#" -ge 2 ] || die "--copilot-home requires a path"
      COPILOT_HOME="$2"
      shift 2
      ;;
    --include-config)
      INCLUDE_CONFIG=1
      shift
      ;;
    --include-skills)
      INCLUDE_SKILLS=1
      shift
      ;;
    --include-mailbox)
      INCLUDE_MAILBOX=1
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

require_macos
require_command tar
require_command shasum

COPILOT_HOME=$(existing_absolute_path "$COPILOT_HOME")
[ -d "$COPILOT_HOME" ] || die "Copilot state directory not found: $COPILOT_HOME"
[ -d "$COPILOT_HOME/session-state" ] ||
  die "session-state not found under $COPILOT_HOME"
refuse_live_sessions "$COPILOT_HOME/session-state"

if [ -z "$OUTPUT" ]; then
  OUTPUT="$PWD/copilot-backup-$(date -u +%Y%m%dT%H%M%SZ)"
fi
OUTPUT=$(absolute_path "$OUTPUT")
[ ! -e "$OUTPUT" ] || die "output already exists: $OUTPUT"
case "$OUTPUT/" in
  "$COPILOT_HOME/"*) die "output must not be inside the Copilot state directory" ;;
esac

umask 077
BUILD=$(mktemp -d "$(dirname "$OUTPUT")/.copilot-migration-build.XXXXXX")
trap 'rm -rf "$BUILD"' EXIT
mkdir -p "$BUILD/payload"

note "Archiving session directories..."
tar -C "$COPILOT_HOME" \
  --exclude='session-state/*/inuse.*.lock' \
  -czf "$BUILD/payload/session-state.tar.gz" session-state

note "Copying session indexes..."
for name in session-store.db session-store.db-wal session-store.db-shm \
  data.db data.db-wal data.db-shm; do
  if [ -f "$COPILOT_HOME/$name" ]; then
    cp -p "$COPILOT_HOME/$name" "$BUILD/payload/$name"
  fi
done

if [ "$INCLUDE_CONFIG" -eq 1 ]; then
  config_items=
  for name in copilot-instructions.md config.json settings.json \
    permissions-config.json mcp-config.json instructions agents; do
    if [ -e "$COPILOT_HOME/$name" ]; then
      config_items="$config_items $name"
    fi
  done
  [ -n "$config_items" ] || die "--include-config requested, but no supported config was found"
  # These names are fixed by this script and contain no shell metacharacters.
  # shellcheck disable=SC2086
  tar -C "$COPILOT_HOME" -czf "$BUILD/payload/config.tar.gz" $config_items
fi

if [ "$INCLUDE_SKILLS" -eq 1 ]; then
  skill_items=
  for name in skills skill-state; do
    if [ -e "$COPILOT_HOME/$name" ]; then
      skill_items="$skill_items $name"
    fi
  done
  [ -n "$skill_items" ] || die "--include-skills requested, but no skills or skill-state was found"
  # shellcheck disable=SC2086
  tar -C "$COPILOT_HOME" -czf "$BUILD/payload/skills.tar.gz" $skill_items
fi

if [ "$INCLUDE_MAILBOX" -eq 1 ]; then
  [ -d "$COPILOT_HOME/mailbox" ] ||
    die "--include-mailbox requested, but mailbox was not found"
  tar -C "$COPILOT_HOME" -czf "$BUILD/payload/mailbox.tar.gz" mailbox
fi

cat > "$BUILD/metadata.txt" <<EOF
format_version=1
created_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
source_macos=$(sw_vers -productVersion 2>/dev/null || printf unknown)
source_arch=$(uname -m)
includes_config=$INCLUDE_CONFIG
includes_skills=$INCLUDE_SKILLS
includes_mailbox=$INCLUDE_MAILBOX
EOF

write_manifest "$BUILD"
verify_manifest "$BUILD" >/dev/null
mv "$BUILD" "$OUTPUT"
trap - EXIT

note ""
note "Backup complete: $OUTPUT"
note "This bundle contains private conversation history. Store and transfer it securely."
