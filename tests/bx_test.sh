#!/usr/bin/env bash
# Tests for bx.
#
# These run entirely on the host with a fake `smolvm` on PATH, so they need no
# VM, no network, and no account. They pin the behavior that has actually
# broken: mount-shape reconciliation, the concurrency lock, exit-status
# propagation, dry-run determinism, and empty-input handling.
#
# Run: tests/bx_test.sh

set -uo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_repo_root="$(cd "${_here}/.." && pwd)"
_bx="${_repo_root}/bin/bx"

_passed=0
_failed=0
_current=""

_fail() { printf 'not ok - %s: %s\n' "$_current" "$*" >&2; _failed=$((_failed + 1)); }
_ok() { _passed=$((_passed + 1)); }

assert_eq() {
  if [[ "$1" == "$2" ]]; then _ok; else _fail "$3"$'\n'"    want: $1"$'\n'"    got:  $2"; fi
}
assert_contains() {
  if [[ "$2" == *"$1"* ]]; then _ok; else _fail "expected to contain '$1'"$'\n'"    got: $2"; fi
}
assert_not_contains() {
  if [[ "$2" != *"$1"* ]]; then _ok; else _fail "expected NOT to contain '$1'"$'\n'"    got: $2"; fi
}

# A fake smolvm that records its invocations and answers the small query
# surface the runner uses. `machine ls -q` reports the names in FAKE_VMS.
_fake_bin_dir=""
_fake_log=""
_install_fake_smolvm() {
  _fake_bin_dir="$(mktemp -d)"
  _fake_log="${_fake_bin_dir}/calls.log"
  : >"$_fake_log"
  cat >"${_fake_bin_dir}/smolvm" <<FAKE
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$(printf '%q' "$_fake_log")"
case "\$1 \$2" in
  "machine ls")
    for _n in \${FAKE_VMS:-}; do printf '%s\n' "\$_n"; done
    ;;
  "machine exec")
    exit "\${FAKE_EXEC_RC:-0}"
    ;;
esac
exit 0
FAKE
  chmod +x "${_fake_bin_dir}/smolvm"
}
_remove_fake_smolvm() { rm -rf "$_fake_bin_dir"; }

_new_workdir() {
  local d
  d="$(mktemp -d)"
  mkdir -p "$d/local"
  printf '%s\n' "$d"
}

# ── dry-run is deterministic and names the plan ─────────────────────────────
test_dry_run_plan() {
  _current="dry-run prints a stable plan"
  local d out again
  d="$(_new_workdir)"
  out="$(cd "$d" && BX_NAME=probe BX_DRY_RUN=1 \
    BX_MOUNTS="/a:/a" BX_COMMAND="true" \
    BX_STATE_DIR="$d/local" PATH="${_fake_bin_dir}:$PATH" \
    "$_bx" 2>/dev/null)"
  assert_contains "machine=probe" "$out" "names the machine"
  assert_contains "action=create" "$out" "would create"
  assert_contains "/a:/a" "$out" "lists mounts"
  assert_contains "lock=" "$out" "names the lock"
  if [[ "$out" != *".lock.d"* ]]; then
    _fail "the reported lock path should be the lock directory (.lock.d)"
  else
    _ok
  fi
  again="$(cd "$d" && BX_NAME=probe BX_DRY_RUN=1 \
    BX_MOUNTS="/a:/a" BX_COMMAND="true" \
    BX_STATE_DIR="$d/local" PATH="${_fake_bin_dir}:$PATH" \
    "$_bx" 2>/dev/null)"
  assert_eq "$out" "$again" "dry-run is byte-identical"
  rm -rf "$d"
}

# ── reconciliation ──────────────────────────────────────────────────────────
test_conflict_on_changed_mounts() {
  _current="a changed mount set is refused, not silently reused"
  local d rc out
  d="$(_new_workdir)"
  cat >"$d/local/m1.state" <<STATE
image=debian:bookworm-slim
cpus=4
mem=4096
net=1
mounts:
/only:/only
STATE
  out="$(cd "$d" && BX_NAME=m1 BX_MOUNTS="/two:/two" \
    BX_COMMAND="true" BX_STATE_DIR="$d/local" \
    FAKE_VMS="m1" PATH="${_fake_bin_dir}:$PATH" \
    "$_bx" 2>&1)"
  rc=$?
  assert_eq "1" "$rc" "exits nonzero"
  assert_contains "different shape" "$out" "explains the conflict"
  assert_contains "--reset" "$out" "names the fix"
  assert_contains "/two:/two" "$out" "shows what was wanted"
  rm -rf "$d"
}

test_reuse_on_unchanged_shape() {
  _current="an unchanged shape reuses the machine"
  local d out
  d="$(_new_workdir)"
  cat >"$d/local/m2.state" <<STATE
image=debian:bookworm-slim
cpus=4
mem=4096
net=1
mounts:
/only:/only
STATE
  out="$(cd "$d" && BX_NAME=m2 BX_MOUNTS="/only:/only" \
    BX_COMMAND="true" BX_STATE_DIR="$d/local" \
    FAKE_VMS="m2" PATH="${_fake_bin_dir}:$PATH" \
    "$_bx" 2>&1)"
  assert_contains "reusing machine m2" "$out" "reuses"
  assert_not_contains "creating machine" "$out" "does not recreate"
  rm -rf "$d"
}

test_reset_recreates() {
  _current="BX_RESET recreates over a mismatch"
  local d out
  d="$(_new_workdir)"
  printf 'image=other\n' >"$d/local/m3.state"
  out="$(cd "$d" && BX_NAME=m3 BX_RESET=1 BX_MOUNTS="/x:/x" \
    BX_COMMAND="true" BX_STATE_DIR="$d/local" \
    FAKE_VMS="m3" PATH="${_fake_bin_dir}:$PATH" \
    "$_bx" 2>&1)"
  assert_contains "recreating machine m3" "$out" "recreates"
  assert_contains "mounts:" "$(cat "$d/local/m3.state")" "records new shape"
  assert_contains "/x:/x" "$(cat "$d/local/m3.state")" "records new mounts"
  rm -rf "$d"
}

# ── lock ────────────────────────────────────────────────────────────────────
test_lock_blocks_live_holder() {
  _current="a live lock holder blocks a second launch"
  local d out rc
  d="$(_new_workdir)"
  mkdir -p "$d/local/m4.lock.d"
  printf '%s\n' "$$" >"$d/local/m4.lock.d/pid"
  out="$(cd "$d" && BX_NAME=m4 BX_COMMAND="true" \
    BX_STATE_DIR="$d/local" PATH="${_fake_bin_dir}:$PATH" \
    "$_bx" 2>&1)"
  rc=$?
  assert_eq "1" "$rc" "exits nonzero"
  assert_contains "already being driven by pid $$" "$out" "names the holder"
  rm -rf "$d"
}

test_lock_recovers_from_dead_holder() {
  _current="a stale lock (dead pid) is reclaimed"
  local d out rc
  d="$(_new_workdir)"
  mkdir -p "$d/local/m5.lock.d"
  printf '999999\n' >"$d/local/m5.lock.d/pid"
  out="$(cd "$d" && BX_NAME=m5 BX_COMMAND="true" \
    BX_STATE_DIR="$d/local" PATH="${_fake_bin_dir}:$PATH" \
    "$_bx" 2>&1)"
  rc=$?
  assert_eq "0" "$rc" "proceeds"
  assert_contains "creating machine m5" "$out" "creates"
  if [[ -d "$d/local/m5.lock.d" ]]; then
    _fail "lock was not released"
  else
    _ok
  fi
  rm -rf "$d"
}

# ── exit status ─────────────────────────────────────────────────────────────
test_guest_exit_status_propagates() {
  _current="the guest command's exit status is preserved"
  local d rc
  d="$(_new_workdir)"
  ( cd "$d" && BX_NAME=m6 BX_COMMAND="false" \
    BX_STATE_DIR="$d/local" FAKE_EXEC_RC=7 \
    PATH="${_fake_bin_dir}:$PATH" \
    "$_bx" >/dev/null 2>&1 )
  rc=$?
  assert_eq "7" "$rc" "propagates 7"
  rm -rf "$d"
}

test_empty_input_does_not_abort() {
  _current="empty mounts/env lists do not abort under set -e"
  local d rc
  d="$(_new_workdir)"
  ( cd "$d" && BX_NAME=m7 BX_MOUNTS="" BX_COMMAND="true" \
    BX_STATE_DIR="$d/local" \
    PATH="${_fake_bin_dir}:$PATH" \
    "$_bx" >/dev/null 2>&1 )
  rc=$?
  assert_eq "0" "$rc" "still succeeds"
  rm -rf "$d"
}

test_cpu_change_conflicts() {
  _current="changing cpus conflicts"
  local d out
  d="$(_new_workdir)"
  cat >"$d/local/m8.state" <<STATE
image=debian:bookworm-slim
cpus=4
mem=4096
net=1
mounts:
/a:/a
STATE
  out="$(cd "$d" && BX_NAME=m8 BX_CPUS=8 BX_MOUNTS="/a:/a" \
    BX_COMMAND="true" BX_STATE_DIR="$d/local" FAKE_VMS="m8" \
    PATH="${_fake_bin_dir}:$PATH" \
    "$_bx" 2>&1)"
  assert_contains "different shape" "$out" "conflicts"
  rm -rf "$d"
}

# ── unknown-option handling ─────────────────────────────────────────────────
test_unknown_option_is_rejected() {
  _current="an unknown option is rejected"
  local d out
  d="$(_new_workdir)"
  out="$(cd "$d" && BX_COMMAND="true" BX_STATE_DIR="$d/local" \
    PATH="${_fake_bin_dir}:$PATH" "$_bx" --nonsense 2>&1)"
  assert_contains "unknown option" "$out" "explains"
  rm -rf "$d"
}

# ── machine-name validation ─────────────────────────────────────────────────
test_invalid_machine_name_is_rejected() {
  _current="a machine name smolvm would reject is caught first"
  local d out
  d="$(_new_workdir)"
  out="$(cd "$d" && BX_NAME="pi-tmp.with.dot" BX_COMMAND="true" \
    BX_STATE_DIR="$d/local" PATH="${_fake_bin_dir}:$PATH" "$_bx" 2>&1)"
  assert_contains "machine name" "$out" "explains"
  assert_contains "invalid" "$out" "says what is wrong"
  rm -rf "$d"
}

_install_fake_smolvm
trap '_remove_fake_smolvm' EXIT

test_dry_run_plan
test_conflict_on_changed_mounts
test_reuse_on_unchanged_shape
test_reset_recreates
test_lock_blocks_live_holder
test_lock_recovers_from_dead_holder
test_guest_exit_status_propagates
test_empty_input_does_not_abort
test_cpu_change_conflicts
test_unknown_option_is_rejected
test_invalid_machine_name_is_rejected

printf '\n%d passed, %d failed\n' "$_passed" "$_failed"
[[ "$_failed" -eq 0 ]]
