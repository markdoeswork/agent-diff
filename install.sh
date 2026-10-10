#!/usr/bin/env bash
#
# Install agent-diff from this checkout.
#
#   ./install.sh               link bin/agent-diff onto PATH, install hooks
#   ./install.sh --no-hooks    link only
#   ./install.sh --uninstall   remove the link and the hooks (history is kept)
#
# BIN_DIR overrides where the command is linked (default ~/.local/bin).
# Safe to re-run; re-running after moving the checkout re-points everything.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
HOOKS=1
UNINSTALL=0
for arg in "$@"; do
  case "$arg" in
    --no-hooks) HOOKS=0 ;;
    --uninstall) UNINSTALL=1 ;;
    -h|--help) sed -n '3,10p' "$0"; exit 0 ;;
    *) echo "install.sh: unknown option $arg" >&2; exit 2 ;;
  esac
done

# shellcheck source=lib/pick_ruby.sh
. "$ROOT/lib/pick_ruby.sh"
RUBY="$(pick_ruby)" || {
  echo "install.sh: agent-diff needs Ruby 3.0 or newer, and none was found." >&2
  exit 1
}
command -v git >/dev/null || { echo "install.sh: git is required." >&2; exit 1; }

if [ "$UNINSTALL" = 1 ]; then
  [ -L "$BIN_DIR/agent-diff" ] && rm "$BIN_DIR/agent-diff" && echo "removed $BIN_DIR/agent-diff"
  "$RUBY" "$ROOT/hooks/install_claude_hooks.rb" --uninstall
  [ -d "$HOME/.cursor" ] && "$RUBY" "$ROOT/hooks/install_cursor_hooks.rb" --uninstall
  echo "recorded history is left in ${AGENT_DIFF_HOME:-$HOME/.local/share/agent_diff}"
  exit 0
fi

mkdir -p "$BIN_DIR"
ln -sfn "$ROOT/bin/agent-diff" "$BIN_DIR/agent-diff"
echo "linked $BIN_DIR/agent-diff"
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "note: $BIN_DIR is not on your PATH" ;;
esac

if [ "$HOOKS" = 1 ]; then
  echo "hooks:"
  "$RUBY" "$ROOT/hooks/install_claude_hooks.rb"
  if [ -d "$HOME/.cursor" ]; then
    "$RUBY" "$ROOT/hooks/install_cursor_hooks.rb"
  fi
fi

echo
echo "done. Start an agent in a git repo, then run: agent-diff"
