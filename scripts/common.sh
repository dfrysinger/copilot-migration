#!/bin/bash

set -euo pipefail

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

note() {
  printf '%s\n' "$*"
}

require_macos() {
  [ "$(uname -s)" = "Darwin" ] || die "this tool supports macOS only"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

absolute_path() {
  local path="$1"
  local parent
  local name
  parent=$(dirname "$path")
  name=$(basename "$path")
  mkdir -p "$parent"
  parent=$(cd "$parent" && pwd -P)
  printf '%s/%s\n' "$parent" "$name"
}

existing_absolute_path() {
  local path="$1"
  local parent
  local name
  parent=$(dirname "$path")
  name=$(basename "$path")
  [ -d "$parent" ] || die "parent directory not found: $parent"
  parent=$(cd "$parent" && pwd -P)
  printf '%s/%s\n' "$parent" "$name"
}

live_session_locks() {
  local session_root="$1"
  local lock
  local name
  local pid

  [ -d "$session_root" ] || return 0
  find "$session_root" -maxdepth 2 -type f -name 'inuse.*.lock' -print |
    while IFS= read -r lock; do
      name=$(basename "$lock")
      pid=${name#inuse.}
      pid=${pid%.lock}
      case "$pid" in
        ''|*[!0-9]*) continue ;;
      esac
      if kill -0 "$pid" 2>/dev/null; then
        printf '%s\n' "$lock"
      fi
    done
}

refuse_live_sessions() {
  local session_root="$1"
  local locks
  locks=$(live_session_locks "$session_root")
  if [ -n "$locks" ]; then
    printf '%s\n' "Active Copilot CLI sessions were detected:" >&2
    printf '%s\n' "$locks" >&2
    die "close Copilot CLI sessions before backup or restore"
  fi
}

safe_archive_listing() {
  local archive="$1"
  local allowed_paths="$2"
  local listing
  listing=$(mktemp "${TMPDIR:-/tmp}/copilot-archive-list.XXXXXX")
  if ! tar -tzf "$archive" > "$listing"; then
    rm -f "$listing"
    die "archive cannot be read: $(basename "$archive")"
  fi
  if ! awk '
    BEGIN { bad = 0 }
    /^\/|(^|\/)\.\.(\/|$)/ { bad = 1 }
    END { exit bad }
  ' "$listing"; then
    rm -f "$listing"
    die "archive contains an unsafe path: $(basename "$archive")"
  fi
  if ! awk -v allowed="$allowed_paths" '
    {
      path = $0
      sub(/\/$/, "", path)
      if (path !~ allowed) bad = 1
    }
    END { exit bad }
  ' "$listing"; then
    rm -f "$listing"
    die "archive contains an unexpected path: $(basename "$archive")"
  fi
  rm -f "$listing"

  if ! tar -tvzf "$archive" | awk '
    {
      type = substr($1, 1, 1)
      if (type != "-" && type != "d") bad = 1
    }
    END { exit bad }
  '; then
    die "archive contains a non-file entry: $(basename "$archive")"
  fi
}

write_manifest() {
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

verify_manifest() {
  local bundle="$1"
  local expected
  local actual
  [ -f "$bundle/MANIFEST.sha256" ] || die "missing MANIFEST.sha256"
  if ! awk '
    length($1) != 64 || $1 !~ /^[0-9a-f]+$/ { bad = 1 }
    {
      path = substr($0, 67)
      if (path != "metadata.txt" && path !~ /^payload\//) bad = 1
      if (path ~ /(^|\/)\.\.(\/|$)/ || path ~ /^\//) bad = 1
    }
    END { exit bad }
  ' "$bundle/MANIFEST.sha256"; then
    die "MANIFEST.sha256 contains an unsafe or malformed entry"
  fi
  (
    cd "$bundle"
    shasum -a 256 -c MANIFEST.sha256
  )

  expected=$(mktemp "${TMPDIR:-/tmp}/copilot-manifest-expected.XXXXXX")
  actual=$(mktemp "${TMPDIR:-/tmp}/copilot-manifest-actual.XXXXXX")
  (
    cd "$bundle"
    sed -E 's/^[0-9a-f]{64}  //' MANIFEST.sha256 | LC_ALL=C sort > "$expected"
    {
      printf '%s\n' metadata.txt
      find payload ! -type d -print
    } | LC_ALL=C sort > "$actual"
  )
  if ! cmp -s "$expected" "$actual"; then
    rm -f "$expected" "$actual"
    die "bundle payload does not exactly match MANIFEST.sha256"
  fi
  rm -f "$expected" "$actual"
}

backup_existing() {
  local target="$1"
  local backup_root="$2"
  local relative="$3"

  [ -e "$target" ] || return 0
  mkdir -p "$backup_root/$(dirname "$relative")"
  mv "$target" "$backup_root/$relative"
}
