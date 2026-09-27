#!/bin/sh
# Everything CI and a contributor should run before trusting a change.
set -eu
if command -v shellcheck >/dev/null 2>&1; then
  # Gate on real problems. shellcheck also emits `info`-level style notes, and
  # a nonzero exit for one of those would abort this script before the tests
  # ever ran; the notes are worth seeing, not worth failing on.
  shellcheck --severity=warning bin/bx install.sh tests/bx_test.sh \
    tests/invariants.sh scripts/bench.sh scripts/demo.sh scripts/lib.sh
else
  echo "check: shellcheck not found; skipping lint" >&2
fi
# bx and the test suites are bash, not POSIX sh. Run them with bash explicitly
# so `sh` being dash does not break the suite.
bash tests/bx_test.sh
# The invariants harness turns the docs' never/only claims into assertions and
# greps everything bx writes for a sentinel secret. The real isolation suite is
# opt-in via BX_REAL=1, so this stays host-only and hermetic; when enabled it
# runs the fence on whatever backend can actually boot here (a vm on a
# hypervisor host, a container where podman works), not just smolvm.
bash tests/invariants.sh
# The bench harness must at minimum run and refuse to invent numbers.
bash scripts/bench.sh --fake >/dev/null
