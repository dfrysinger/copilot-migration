#!/bin/bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
# shellcheck source=common.sh
. "$SCRIPT_DIR/common.sh"

usage() {
  cat <<'EOF'
Usage: rehydrate.sh --bundle PATH [options]

Report portable Copilot environment state and optionally reinstall plugins.

Options:
  --bundle PATH          Bundle created with --include-environment
  --copilot-home PATH    Destination state directory (default: ~/.copilot)
  --install-plugins      Install missing plugins from recorded sources
  -h, --help             Show this help

This command does not migrate credentials, OAuth state, Keychain entries, or
external MCP server runtimes.
EOF
}

BUNDLE=
COPILOT_HOME="${COPILOT_HOME:-$HOME/.copilot}"
INSTALL_PLUGINS=0

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
    --install-plugins)
      INSTALL_PLUGINS=1
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

[ -n "$BUNDLE" ] || die "--bundle is required"
require_macos
require_command plutil

BUNDLE=$(existing_absolute_path "$BUNDLE")
COPILOT_HOME=$(absolute_path "$COPILOT_HOME")
"$SCRIPT_DIR/verify.sh" "$BUNDLE" >/dev/null
grep -q '^includes_environment=1$' "$BUNDLE/metadata.txt" ||
  die "bundle was not created with --include-environment"
PLUGINS="$BUNDLE/payload/plugins.txt"
[ -f "$PLUGINS" ] ||
  die "bundle does not contain environment plugin declarations"

if [ "$INSTALL_PLUGINS" -eq 1 ]; then
  DEFAULT_COPILOT_HOME=$(existing_absolute_path "$HOME/.copilot")
  [ "$COPILOT_HOME" = "$DEFAULT_COPILOT_HOME" ] ||
    die "--install-plugins requires --copilot-home $DEFAULT_COPILOT_HOME"
  require_command copilot
fi

plugin_is_installed() {
  local source="$1"
  local owner
  local repo
  local direct

  case "$source" in
    *@*)
      COPILOT_HOME="$COPILOT_HOME" copilot plugin list 2>/dev/null |
        grep -F "  • $source " >/dev/null 2>&1
      ;;
    */*)
      owner=${source%%/*}
      repo=${source#*/}
      repo=${repo%%:*}
      repo=${repo%.git}
      direct="$COPILOT_HOME/installed-plugins/_direct/$owner--$repo"
      [ -d "$direct" ]
      ;;
    *)
      return 1
      ;;
  esac
}

if [ "$INSTALL_PLUGINS" -eq 1 ]; then
  failures=0
  while IFS= read -r source; do
    [ -n "$source" ] || continue
    if plugin_is_installed "$source"; then
      note "Plugin already installed: $source"
      continue
    fi
    note "Installing plugin: $source"
    if ! COPILOT_HOME="$COPILOT_HOME" copilot plugin install "$source"; then
      note "Plugin installation failed: $source" >&2
      failures=$((failures + 1))
    fi
  done < "$PLUGINS"
  [ "$failures" -eq 0 ] ||
    die "$failures plugin installation(s) failed"
fi

note ""
note "Recorded plugin sources:"
if [ -s "$PLUGINS" ]; then
  sed 's/^/  - /' "$PLUGINS"
else
  note "  (none)"
fi

note ""
note "Configured MCP servers:"
MISSING_PATHS=$(mktemp "${TMPDIR:-/tmp}/copilot-mcp-missing.XXXXXX")
JSON_CONFIG=$(mktemp "${TMPDIR:-/tmp}/copilot-environment-json.XXXXXX")
NORMALIZED_JSON=$(mktemp "${TMPDIR:-/tmp}/copilot-environment-normalized.XXXXXX")
trap 'rm -f "$MISSING_PATHS" "$JSON_CONFIG" "$NORMALIZED_JSON"' EXIT
MCP_CONFIG="$COPILOT_HOME/mcp-config.json"
if [ -f "$MCP_CONFIG" ]; then
  if ! plutil -extract mcpServers raw -o - "$MCP_CONFIG" 2>/dev/null |
    sed 's/^/  - /'; then
    note "  (configuration could not be read)"
  fi
  plutil -convert json -o "$JSON_CONFIG" "$MCP_CONFIG"
  sed 's#\\/#/#g' "$JSON_CONFIG" > "$NORMALIZED_JSON"
  { grep -Eo '"command":"[^"]+"' "$NORMALIZED_JSON" 2>/dev/null || true; } |
    sed 's/^"command":"//; s/"$//' |
    while IFS= read -r executable; do
      case "$executable" in
        /*)
          [ -e "$executable" ] ||
            printf '%s\t%s\n' "mcp-config.json" "$executable" >> "$MISSING_PATHS"
          ;;
        *)
          command -v "$executable" >/dev/null 2>&1 ||
            printf '%s\t%s\n' "mcp-config.json" "$executable" >> "$MISSING_PATHS"
          ;;
      esac
    done
else
  note "  (none)"
fi

for config in "$MCP_CONFIG" "$COPILOT_HOME/settings.json"; do
  [ -f "$config" ] || continue
  plutil -convert json -o "$JSON_CONFIG" "$config"
  sed 's#\\/#/#g' "$JSON_CONFIG" > "$NORMALIZED_JSON"
  { grep -Eo '"/[^"]+"' "$NORMALIZED_JSON" 2>/dev/null || true; } |
    sed 's/^"//; s/"$//' |
    while IFS= read -r path; do
      [ -e "$path" ] ||
        printf '%s\t%s\n' "$(basename "$config")" "$path" >> "$MISSING_PATHS"
    done
done

LC_ALL=C sort -u "$MISSING_PATHS" -o "$MISSING_PATHS"

note ""
if [ -s "$MISSING_PATHS" ]; then
  note "Unresolved commands or absolute configuration paths:"
  while IFS="$(printf '\t')" read -r name path; do
    note "  - $name: $path"
  done < "$MISSING_PATHS"
else
  note "No unresolved commands or absolute configuration paths detected."
fi
note "Remote MCP sign-ins and local runtimes may still require setup."
