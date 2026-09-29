#!/bin/sh
# Everything CI and a contributor should run before trusting a change.
#
# Each phase is announced before it runs: this script can take minutes (a test
# that boots a machine is the slow part), and a silent terminal reads as a
# hang. The phase lines go to stderr so a piped run's stdout stays the tests'
# own output.
#
# Usage:
#   scripts/check.sh              # lint, unit, host invariants, bench
#   scripts/check.sh --real       # also boot machines to test the fence
#   scripts/check.sh --quiet      # no phase lines, only the tests' own output
#
# `--real` is the same thing as BX_REAL=1; it is accepted as a flag because
# `BX_REAL=1 scripts/check.sh` is easy to forget and its absence is invisible
# (the suite simply runs less). Anything after `--` is passed to the suites
# untouched.
set -eu

_bx_real="${BX_REAL:-0}"
_check_quiet="${CHECK_QUIET:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --real)  _bx_real=1 ;;
    --quiet) _check_quiet=1 ;;
    --)      shift; break ;;
    -h|--help)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      printf 'check: unknown argument %s (try --help)\n' "$1" >&2
      exit 2
      ;;
  esac
  shift
done
# `$@` now holds anything after `--`; the suites currently take no arguments,
# but a future one might, and swallowing them silently would be the same class
# of bug as ignoring `--real`.
_extra_args="$*"

_say() { [ -n "$_check_quiet" ] || printf 'check: %s\n' "$*" >&2; }

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
# shellcheck disable=SC2086  # word-splitting is intended for the pass-through
bash tests/bx_test.sh $_extra_args
# The invariants harness turns the docs' never/only claims into assertions and
# greps everything bx writes for a sentinel secret. The real isolation suite is
# opt-in (--real / BX_REAL=1), so this stays host-only and hermetic by default;
# when enabled it runs the fence on whatever backend can actually boot here (a
# vm on a hypervisor host, a container where podman works), not just smolvm.
if [ "$_bx_real" = "1" ]; then
  _say "invariants + real isolation suite (this boots machines; expect minutes)"
else
  _say "invariants (host-only; --real adds the fence)"
fi
# shellcheck disable=SC2086
BX_REAL="$_bx_real" bash tests/invariants.sh $_extra_args
# The bench harness must at minimum run and refuse to invent numbers.
_say "bench harness (fake mode)"
bash scripts/bench.sh --fake >/dev/null
_say "all phases passed"
