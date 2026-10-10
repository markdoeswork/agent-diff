#!/usr/bin/env bash
# Run the whole suite:  ./test/run.sh
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
# shellcheck source=../lib/pick_ruby.sh
. lib/pick_ruby.sh
RUBY="${RUBY:-$(pick_ruby)}" || {
  echo "test/run.sh: no ruby found" >&2
  exit 127
}
fail=0
for t in test/*_test.rb; do
  echo "── $t"
  "$RUBY" "$t" || fail=1
done

exit "$fail"
