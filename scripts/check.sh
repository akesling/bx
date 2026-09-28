#!/bin/sh
# Everything CI and a contributor should run before trusting a change.
#
# Each phase is announced before it runs: this script can take minutes (a test
# that boots a machine is the slow part), and a silent terminal reads as a
# hang. The phase lines go to stderr so a piped run's stdout stays the tests'
# own output; set CHECK_QUIET=1 to suppress them.
set -eu

_say() { [ -n "${CHECK_QUIET:-}" ] || printf 'check: %s\n' "$*" >&2; }

_say "linting (shellcheck)"
if command -v shellcheck >/dev/null 2>&1; then
  # Gate on real problems. shellcheck also emits `info`-level style notes, and
  # a nonzero exit for one of those would abort this script before the tests
  # ever ran; the notes are worth seeing, not worth failing on.
  shellcheck --severity=warning bin/bx install.sh tests/bx_test.sh \
    tests/invariants.sh scripts/bench.sh scripts/demo.sh scripts/lib.sh
else
  _say "shellcheck not found; skipping lint"
fi
# bx and the test suites are bash, not POSIX sh. Run them with bash explicitly
# so `sh` being dash does not break the suite.
_say "unit tests (tests/bx_test.sh)"
bash tests/bx_test.sh
# The invariants harness turns the docs' never/only claims into assertions and
# greps everything bx writes for a sentinel secret. The real isolation suite is
# opt-in via BX_REAL=1, so this stays host-only and hermetic; when enabled it
# runs the fence on whatever backend can actually boot here (a vm on a
# hypervisor host, a container where podman works), not just smolvm.
if [ "${BX_REAL:-0}" = "1" ]; then
  _say "invariants + real isolation suite (this boots machines; expect minutes)"
else
  _say "invariants (host-only; BX_REAL=1 adds the real fence)"
fi
bash tests/invariants.sh
# The bench harness must at minimum run and refuse to invent numbers.
_say "bench harness (fake mode)"
bash scripts/bench.sh --fake >/dev/null
_say "all phases passed"
