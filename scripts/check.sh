#!/bin/sh
# Everything CI and a contributor should run before trusting a change.
set -eu
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck bin/bx install.sh tests/bx_test.sh scripts/bench.sh scripts/demo.sh
else
  echo "check: shellcheck not found; skipping lint" >&2
fi
# bx and the test suite are bash, not POSIX sh. Run them with bash explicitly
# so `sh` being dash does not break the suite.
bash tests/bx_test.sh
# The bench harness must at minimum run and refuse to invent numbers.
bash scripts/bench.sh --fake >/dev/null
