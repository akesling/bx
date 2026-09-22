#!/usr/bin/env bash
# demo.sh — a recording that *shows* the boundary instead of describing it.
#
# This is not a benchmark and not a test. It is the demo artifact the README
# links to: a viewer watches the wall appear, rather than reading a claim that
# it exists.
#
# Record it on a host with a real smolvm — macOS, or Linux with /dev/kvm:
#
#   asciinema rec --cols 80 --rows 24 demo.cast -c 'scripts/demo.sh'
#
# Then embed the result. The script itself is deterministic and safe to run
# anywhere, but the interesting steps (the fence tests) only *demonstrate* the
# fence on a real machine. Against a fake smolvm they will report "cannot
# verify" rather than pretending.
#
# The shape of the recording:
#   0:00  show what's on the host that should not be reachable
#   0:05  start the agent in a VM with only this directory mounted
#   0:12  ask it to read the secret -> it fails
#   0:20  ask it to do real work in the mount -> it succeeds
#   0:28  the point: same agent, no access

set -uo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_repo_root="$(cd "${_here}/.." && pwd)"
_bx="${_repo_root}/bin/bx"

# ── terminal-sized narration helpers ────────────────────────────────────────
_bold=""; _dim=""; _reset=""
if [[ -t 1 ]]; then _bold=$'\033[1m'; _dim=$'\033[2m'; _reset=$'\033[0m'; fi
_say()  { printf '\n%s%s%s\n' "$_bold" "$*" "$_reset"; }
_note() { printf '%s%s%s\n'  "$_dim"  "$*" "$_reset"; }
_ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
_no()   { printf '  \033[31m✗\033[0m %s\n' "$*"; }

# ── setup: a workdir with a secret beside it, like real life ────────────────
_work="$(mktemp -d)"
trap 'rm -rf "$_work"' EXIT
mkdir -p "${_work}/proj"
printf 'def add(a, b):\n    return a - b  # deliberate bug\n' \
  >"${_work}/proj/math.py"
printf 'PRIVATE KEY MATERIAL\n' >"${_work}/id_rsa"  # stand-in for ~/.ssh/id_rsa

# In a real recording, the "host secrets" are your actual home directory. Here
# we use a stand-in so the script is safe to run on anyone's machine.
_host_secret="${DEMO_HOST_SECRET:-${_work}/id_rsa}"

# `bx` has no --command flag; the command is a setting (BX_COMMAND or a recipe
# key). Pass it through the environment, as the docs describe.
_export_bx() {
  BX_STATE_DIR="${_work}/local" \
  BX_MOUNTS="${_work}/proj:/work" \
  BX_WORKDIR=/work \
  BX_COMMAND="echo guest-ready" \
    "$_bx" "$@"
}

_guest_exec() {
  # Run a shell command inside the machine that `bx` manages.
  smolvm machine exec "${BX_NAME:-demo}" -- sh -c "$1" 2>/dev/null
}

# The boot predicate lives in scripts/lib.sh so the test suite exercises the
# same code this demo gates on. See that file for why it is not a bare
# /dev/kvm check (which would wrongly skip macOS).
. "${_here}/lib.sh"

# ── the recording ───────────────────────────────────────────────────────────
clear
_say "Your agent runs as you. So it can read this:"
if [[ -r "$_host_secret" ]]; then
  head -c 40 "$_host_secret"; printf '\n'
else
  _note "(host secret not readable here; on your machine this is ~/.ssh/id_rsa)"
fi

_say "bx gives it one directory in a disposable VM instead."
_note "BX_COMMAND='echo guest-ready' bx --name demo --reset --keep"

# Start a machine and run a command in it. In a real demo this is `bx pi` with
# the agent; for a repeatable recording we use a shell command that exercises
# the same boundary without needing an agent account. What the recording
# proves is the *fence*, not the agent.
_export_bx --name demo --reset --keep >/dev/null 2>&1
_started=$?

if [[ $_started -ne 0 ]]; then
  _no "could not start a machine here (no smolvm/hypervisor)"
  _note "this recording must be made on a host with smolvm and hardware virtualization"
  exit 1
fi
_ok "machine up: only /work is visible"

if ! _smolvm_can_boot; then
  _no "cannot verify the fence without a real smolvm"
  exit 1
fi

_say "Now ask the guest to read your home directory:"
if _guest_exec 'cat ~/.ssh/id_rsa' ; then
  _no "UNEXPECTED: the guest could read a home-directory secret"
  _note "this is a bug; the fence is not holding"
else
  _ok "no such file — your home is not mounted"
fi

_say "And the same guest does the actual work:"
_guest_exec 'sed -i "s/a - b/a + b/" /work/math.py && cat /work/math.py'

_say "The guest can change the project. It cannot reach the rest of the host."
_note "bx --dry-run shows the whole plan before anything runs."
