#!/usr/bin/env bash
#
# Claude Code / Cursor hook -> agent_diff.
#
# Claude: UserPromptSubmit caches the prompt, Stop records the snapshot.
# Cursor: beforeSubmitPrompt caches the prompt, stop records the snapshot.
# Stop/stop payloads carry no prompt text, hence the two-event pairing.
#
# This must never fail or hang: a broken hook would stall every turn. agent-diff
# hook already swallows its own errors; the redirect and `|| true` are a second
# belt, and stderr goes to a log rather than into the transcript.
# $HOME can be unset in a stripped environment; fall back rather than writing
# to a bogus /.local path.
HOME_DIR="${AGENT_DIFF_HOME:-${HOME:-/tmp}/.local/share/agent_diff}"

# Cursor reaches this through ~/.cursor/hooks/agent-diff.sh, a symlink; bin/
# lives next to the real file, not the link.
SELF="${BASH_SOURCE[0]}"
while [ -L "$SELF" ]; do
  LINK="$(readlink "$SELF")"
  case "$LINK" in
    /*) SELF="$LINK" ;;
    *)  SELF="$(dirname -- "$SELF")/$LINK" ;;
  esac
done
BIN="$(dirname -- "$SELF")/../bin/agent-diff"

if ! mkdir -p "$HOME_DIR" 2>/dev/null; then
  exec "$BIN" hook 2>/dev/null || true
fi
exec "$BIN" hook 2>>"$HOME_DIR/hook.log" || true
