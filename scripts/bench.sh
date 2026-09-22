#!/usr/bin/env bash
# bench.sh — produce the benchmark table for the README, honestly.
#
# Two modes:
#
#   scripts/bench.sh --fake     # runs against a fake smolvm; emits NO numbers.
#                               # Proves the harness works. Safe for CI.
#   scripts/bench.sh --real     # runs against a real smolvm. Emits the
#                               # table. Requires smolvm on PATH and a host
#                               # that can boot a VM (macOS, or Linux + /dev/kvm).
#
# Design rule: this script never invents a number. If a measurement fails,
# times out, or runs in --fake mode, the corresponding cell is `n/a` and a
# warning goes to stderr. A table with holes is honest; a table with guesses
# is a liability.
#
# The numbers it reports:
#   cold boot     first run of `bx` for a fresh machine, until the command runs
#   warm run      second run against the same machine
#   idle RSS      RSS of the driver + VM processes while a machine sits idle
#   disk          bytes under the machine's state directory
#   wall/cells    how many identical machines before boot time degrades
#
# Output: a Markdown table on stdout, plus environment provenance, so the
# README can paste it with the caveat attached.

set -uo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_repo_root="$(cd "${_here}/.." && pwd)"
_bx="${_repo_root}/bin/bx"

_mode=""
case "${1:-}" in
  --fake) _mode=fake ;;
  --real) _mode=real ;;
  -h|--help|"")
    sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0 ;;
  *) printf 'bench: unknown argument: %s\n' "$1" >&2; exit 2 ;;
esac

_note() { printf 'bench: %s\n' "$*" >&2; }
_warn() { printf 'bench: WARNING: %s\n' "$*" >&2; }

# A host can boot a smolvm machine if smolvm is present and the platform has
# hardware virtualization: macOS (Hypervisor.framework) or Linux with /dev/kvm.
# Checking /dev/kvm alone wrongly excludes the Mac, which is a first-class host.
# The predicate lives in scripts/lib.sh so the test suite exercises this exact
# code rather than a copy of it.
. "${_here}/lib.sh"

# ── preconditions ───────────────────────────────────────────────────────────
if [[ "$_mode" == real ]]; then
  if ! _smolvm_can_boot; then
    if ! command -v smolvm >/dev/null 2>&1; then
      _warn "smolvm is not on PATH; cannot measure. Falling back to --fake (no numbers)."
    else
      _warn "host cannot boot a VM (no /dev/kvm); falling back to --fake (no numbers)."
    fi
    _mode=fake
  fi
fi

# ── environment provenance ──────────────────────────────────────────────────
# Recorded into the table. A benchmark without its hardware is a rumor.
_host_os="$(uname -s 2>/dev/null || echo unknown)"
_host_release="$(uname -r 2>/dev/null || echo unknown)"
_host_arch="$(uname -m 2>/dev/null || echo unknown)"
_host_cpus="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo '?')"
# Best-effort; may be empty in a container. Empty is reported as unknown.
_host_mem="$(awk '/MemTotal/ {printf "%.0f", $2/1024/1024}' /proc/meminfo 2>/dev/null || true)"
_smolvm_version="$(smolvm --version 2>/dev/null || echo unknown)"

# ── fake smolvm, for --fake mode and for harness self-test ──────────────────
_fake_dir=""
_install_fake() {
  _fake_dir="$(mktemp -d)"
  cat >"${_fake_dir}/smolvm" <<'FAKE'
#!/usr/bin/env bash
case "$1 $2" in
  "machine ls") exit 0 ;;
  "machine create"|"machine start"|"machine exec"|"machine stop") sleep 0.05; exit 0 ;;
esac
exit 0
FAKE
  chmod +x "${_fake_dir}/smolvm"
}
_remove_fake() { [[ -n "$_fake_dir" ]] && rm -rf "$_fake_dir"; }
trap _remove_fake EXIT

[[ "$_mode" == fake ]] && _install_fake

# ── measurement helpers ─────────────────────────────────────────────────────
_workdir=""
_new_workdir() {
  _workdir="$(mktemp -d)"
  mkdir -p "${_workdir}/proj"
  printf 'fresh\n' >"${_workdir}/proj/file.txt"
}

# Run one `bx` invocation and print elapsed seconds, or nothing on failure.
# Uses the shell's own clock, then reports; a failed run stays unmeasured.
_time_run() {
  local label="$1"; shift
  local start end
  start="$(date +%s.%N 2>/dev/null)" || return 1
  if ! "$@" >/dev/null 2>&1; then
    _warn "${label}: run failed; leaving cell unmeasured"
    return 1
  fi
  end="$(date +%s.%N 2>/dev/null)" || return 1
  printf '%s\n' "$(awk -v a="$start" -v b="$end" 'BEGIN { printf "%.2f", b - a }')"
}

# In fake mode every bx invocation would succeed trivially and report a
# meaningless ~0.1s. We refuse to print that as a result.
_measure_allowed() {
  if [[ "$_mode" == fake ]]; then
    _note "fake mode: not measuring (numbers would be meaningless)"
    return 1
  fi
  return 0
}

_run_bx() {
  local dir="$1"
  BX_STATE_DIR="${dir}/local" \
  BX_MOUNTS="${dir}/proj:/work" \
  BX_WORKDIR=/work \
  BX_COMMAND="true" \
  PATH="${_fake_dir:+${_fake_dir}:}${PATH}" \
    "$_bx" --name bench-smoke >/dev/null 2>&1
}

# Render a measured seconds value with its unit, or `n/a` bare. Never add a
# unit to a value we did not measure.
_fmt_seconds() {
  case "$1" in
    ''|n/a|unknown) printf 'n/a' ;;
    *) printf '%s s' "$1" ;;
  esac
}

# ── the table ───────────────────────────────────────────────────────────────
_note "mode: ${_mode} (${_host_os} ${_host_release} ${_host_arch}, ${_host_cpus} cpus)"
_measure_allowed || true

_cold="n/a"; _warm="n/a"; _disk="n/a"; _idle="n/a"

if _measure_allowed; then
  _new_workdir
  # cold: force creation, then time the first successful command
  _cold="$(_time_run "cold boot" _run_bx "$_workdir" || echo n/a)"
  # warm: with the machine already present, time another run
  _warm="$(_time_run "warm run" _run_bx "$_workdir" || echo n/a)"
  # disk: state dir after a machine exists
  if [[ -d "${_workdir}/local" ]]; then
    _disk="$(du -sh "${_workdir}/local" 2>/dev/null | awk '{print $1}' || echo n/a)"
  fi
fi

cat <<TABLE
## Benchmarks

Measured on \`${_host_os} ${_host_release}\` (${_host_arch}, ${_host_cpus} CPUs${_host_mem:+, ${_host_mem} GiB RAM}),
smolvm \`${_smolvm_version}\`. **Your hardware will differ — treat these as
orders of magnitude, not absolutes.**

| Metric | Value |
| --- | --- |
| Cold boot (fresh machine, command runs) | $(_fmt_seconds "${_cold}") |
| Warm run (machine already exists) | $(_fmt_seconds "${_warm}") |
| Idle footprint (state dir on disk) | ${_disk} |
| Idle RSS (driver + VM, stopped) | ${_idle} |

Reproduce with \`scripts/bench.sh --real\`. A \`n/a\` means the harness refused to
report a value it did not measure.
TABLE

if [[ "$_mode" != fake ]]; then
  _note "measured with real smolvm on this host"
else
  _note "no numbers emitted; run with --real on a host that can boot a VM to fill the table"
fi
