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

BUNDLE=$(absolute_path "$1")
[ -d "$BUNDLE/payload" ] || die "bundle payload not found: $BUNDLE"
verify_manifest "$BUNDLE"

for archive in "$BUNDLE"/payload/*.tar.gz; do
  [ -e "$archive" ] || continue
  safe_archive_listing "$archive" ||
    die "archive contains an unsafe path: $(basename "$archive")"
  tar -tzf "$archive" >/dev/null
done

note "Bundle verified: $BUNDLE"

