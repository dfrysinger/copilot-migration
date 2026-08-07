#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

if [ "$#" -ne 1 ]; then
  printf 'Usage: verify.sh BUNDLE\n' >&2
  exit 2
fi

require_macos
require_command tar
require_command shasum

BUNDLE=$(existing_absolute_path "$1")
[ -d "$BUNDLE/payload" ] || die "bundle payload not found: $BUNDLE"
[ -f "$BUNDLE/metadata.txt" ] || die "missing metadata.txt"
grep -q '^format_version=1$' "$BUNDLE/metadata.txt" ||
  die "unsupported or missing bundle format_version"
[ -f "$BUNDLE/payload/session-state.tar.gz" ] ||
  die "missing payload/session-state.tar.gz"
verify_manifest "$BUNDLE"

PAYLOAD_LIST=$(mktemp "${TMPDIR:-/tmp}/copilot-payload-list.XXXXXX")
trap 'rm -f "$PAYLOAD_LIST"' EXIT
find "$BUNDLE/payload" -mindepth 1 -maxdepth 1 -print > "$PAYLOAD_LIST"
while IFS= read -r item; do
  [ -f "$item" ] || die "payload contains a non-file entry: $(basename "$item")"
  case "$(basename "$item")" in
    session-state.tar.gz|config.tar.gz|skills.tar.gz|mailbox.tar.gz|\
    session-store.db|session-store.db-wal|session-store.db-shm|\
    data.db|data.db-wal|data.db-shm)
      ;;
    *)
      die "payload contains an unsupported file: $(basename "$item")"
      ;;
  esac
done < "$PAYLOAD_LIST"

safe_archive_listing "$BUNDLE/payload/session-state.tar.gz" \
  '^session-state(/|$)'
[ ! -f "$BUNDLE/payload/config.tar.gz" ] ||
  safe_archive_listing "$BUNDLE/payload/config.tar.gz" \
    '^(copilot-instructions\.md|config\.json|settings\.json|permissions-config\.json|mcp-config\.json|instructions|agents)(/|$)'
[ ! -f "$BUNDLE/payload/skills.tar.gz" ] ||
  safe_archive_listing "$BUNDLE/payload/skills.tar.gz" \
    '^(skills|skill-state)(/|$)'
[ ! -f "$BUNDLE/payload/mailbox.tar.gz" ] ||
  safe_archive_listing "$BUNDLE/payload/mailbox.tar.gz" '^mailbox(/|$)'

for base in session-store.db data.db; do
  if { [ -e "$BUNDLE/payload/$base-wal" ] ||
       [ -e "$BUNDLE/payload/$base-shm" ]; } &&
     [ ! -f "$BUNDLE/payload/$base" ]; then
    die "database sidecar exists without its base file: $base"
  fi
done

trap - EXIT
rm -f "$PAYLOAD_LIST"
note "Bundle verified: $BUNDLE"
