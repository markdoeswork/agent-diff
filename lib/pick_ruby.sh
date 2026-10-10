#!/usr/bin/env bash
# Pick a Ruby 3+ interpreter, not an asdf/mise shim and not macOS /usr/bin/ruby
# (2.6), which cannot parse this module.
#
# Agent hooks run with a stripped environment. A PATH lookup of `ruby` then
# hits a version-manager shim that cannot resolve a version. Prefer a real
# binary that works under `env -i`.
#
# Sourced, not executed.
ruby_is_modern() {
  [ -x "$1" ] && "$1" -e 'exit RUBY_VERSION.to_f >= 3.0 ? 0 : 1' 2>/dev/null
}

pick_ruby() {
  local c
  for c in \
    /opt/homebrew/opt/ruby/bin/ruby \
    /opt/homebrew/bin/ruby \
    /usr/local/opt/ruby/bin/ruby \
    /usr/local/bin/ruby \
    /usr/bin/ruby
  do
    if ruby_is_modern "$c"; then
      printf '%s\n' "$c"
      return 0
    fi
  done
  # asdf/mise install trees (not the shim)
  for c in "$HOME"/.asdf/installs/ruby/*/bin/ruby \
           "$HOME"/.local/share/mise/installs/ruby/*/bin/ruby
  do
    if ruby_is_modern "$c"; then
      printf '%s\n' "$c"
      return 0
    fi
  done
  if command -v ruby >/dev/null 2>&1 && ruby_is_modern "$(command -v ruby)"; then
    command -v ruby
    return 0
  fi
  return 1
}
