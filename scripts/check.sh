#!/bin/sh
# Everything CI and a contributor should run before trusting a change.
set -eu
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck bin/bx install.sh tests/bx_test.sh tests/invariants.sh \
    scripts/bench.sh scripts/demo.sh scripts/lib.sh
else
  echo "check: shellcheck not found; skipping lint" >&2
fi
# bx and the test suites are bash, not POSIX sh. Run them with bash explicitly
# so `sh` being dash does not break the suite.
bash tests/bx_test.sh
# The invariants harness turns the docs' never/only claims into assertions and
# greps everything bx writes for a sentinel secret. The real isolation
# suite is opt-in via BX_REAL=1, so this stays host-only and hermetic.
bash tests/invariants.sh
# The bench harness must at minimum run and refuse to invent numbers.
bash scripts/bench.sh --fake >/dev/null
