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

# These tests drive the smolvm lifecycle on a host that (in a real environment)
# may also have podman installed. Choosing a backend is now a user decision when
# it is ambiguous, so the harness pins the vm backend here; a recipe's own
# `backend` key still wins, which is how the container tests run podman.
export BX_BACKEND=smolvm

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_repo_root="$(cd "${_here}/.." && pwd)"
_bx="${_repo_root}/bin/bx"

_passed=0
_failed=0
_current=""
# Set by `_backend_free_path` on first use; initialised so the EXIT trap can
# reference it safely under `set -u` even when no test asked for it.
_backend_free_bin=""

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

# A fake podman, the same shape of thing: it records invocations and answers
# the query surface the container backend uses. `ps -a --format` reports the
# names in FAKE_CONTAINERS. This is what lets the container backend be tested
# on the host, with no podman, no container, and no network.
_fake_podman_dir=""
_install_fake_podman() {
  _fake_podman_dir="$(mktemp -d)"
  _fake_podman_log="${_fake_podman_dir}/calls.log"
  : >"$_fake_podman_log"
  cat >"${_fake_podman_dir}/podman" <<FAKE
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$(printf '%q' "$_fake_podman_log")"
case "\$1" in
  ps)
    # The -a form lists every container; without it, only running ones. Keep
    # them separately controllable so a test can tell a stopped machine from a
    # running one — exec attaches only to the running set.
    if [[ "\$*" == *" -a "* || "\$*" == *" -a"* ]]; then
      for _n in \${FAKE_CONTAINERS:-}; do printf '%s\n' "\$_n"; done
    else
      for _n in \${FAKE_RUNNING:-\${FAKE_CONTAINERS:-}}; do printf '%s\n' "\$_n"; done
    fi
    ;;
  image)
    [[ "\${FAKE_IMAGE_CACHED:-0}" == "1" ]] && exit 0 || exit 1
    ;;
  exec)
    exit "\${FAKE_EXEC_RC:-0}"
    ;;
esac
exit 0
FAKE
  chmod +x "${_fake_podman_dir}/podman"
}
_remove_fake_podman() { rm -rf "$_fake_podman_dir"; }

# ── nesting: composition, proved by running a second bx ─────────────────────
# The point of `runtime_args` is that a machine can host a second bx. That is a
# claim about *composition* — the two levels must not share a lock, a state
# dir, or a machine name — and it can be proved on the host by making the
# fake's `exec` actually run a real inner bx instead of faking it. A fake that
# returned 0 would prove nothing about the second level; this one hands the
# wheel to the other half of the tree.
#
# The fake also stands in for the guest filesystem: the outer recipe mounts
# `$hostdir:/work`, so the fake maps the guest's `/work` back to `$hostdir`
# before running the command. Without that the inner bx would look for its
# recipe at the host's literal `/work` and find the wrong tree.
_fake_nesting_dir=""
_fake_nesting_mount=""
_install_fake_nesting() {
  _fake_nesting_dir="$(mktemp -d)"
  cat >"${_fake_nesting_dir}/podman" <<'FAKE'
#!/usr/bin/env bash
# `exec -i [-e VAL ...] NAME bash -lc CMD` runs CMD here, in the *outer*
# "guest", which in this test is the host. Parsed by flag arity, since `-e`
# takes a separate value.
if [[ "$1" == "exec" ]]; then
  shift
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      -i|-t) shift ;;
      -e)    shift 2 ;;
      -*)    shift ;;
      *)     break ;;
    esac
  done
  [[ "$#" -gt 0 ]] && shift            # the machine name
  while [[ "$#" -gt 0 && "$1" != "bash" ]]; do shift; done
  [[ "$#" -gt 0 ]] && shift            # bash
  [[ "$#" -gt 0 ]] && shift            # -lc
  # The guest's /work is the host's $BX_FAKE_GUEST_WORK; model the mount by
  # running there, exactly as the container would.
  if [[ -n "${BX_FAKE_GUEST_WORK:-}" ]]; then
    cd "$BX_FAKE_GUEST_WORK" || exit 1
  fi
  exec bash -lc "${1:-true}"
fi
case "$1" in
  ps) for _n in ${FAKE_CONTAINERS:-}; do printf '%s\n' "$_n"; done ;;
  image) exit 1 ;;
  size) printf '0\n' ;;
  exists) exit 0 ;;
esac
exit 0
FAKE
  chmod +x "${_fake_nesting_dir}/podman"
}
_remove_fake_nesting() { rm -rf "$_fake_nesting_dir"; }

test_bx_in_bx_composes() {
  _current="a second bx runs inside a bx machine, with its own state"
  local d out
  d="$(_new_workdir)"
  # The inner recipe and its workspace live inside the outer machine's mount.
  mkdir -p "$d/work"
  cat >"$d/work/.bx.conf" <<'CONF'
[inner]
backend = podman
image   = debian:bookworm-slim
command = printf 'INNER-OK:%s\n' "$(pwd)"
CONF
  # The outer command runs the inner bx against the inner recipe. The fake
  # models the mount, so the command's cwd is the workspace; a *relative*
  # state dir therefore lands inside it, which is what a real guest would get
  # from `/work/inner-state`.
  cat >"$d/.bx.conf" <<CONF
[outer]
backend      = podman
image        = debian:bookworm-slim
runtime_args = --privileged
mounts       = $d/work:/work
command      = BX_BACKEND=podman BX_STATE_DIR=inner-state BX_NAME=inner \
                 PATH=$_fake_nesting_dir:\$PATH ${_bx} inner
CONF
  out="$(cd "$d" && BX_BACKEND=podman BX_NAME=outer BX_STATE_DIR="$d/outer-state" \
    BX_FAKE_GUEST_WORK="$d/work" PATH="${_fake_nesting_dir}:$PATH" "$_bx" outer 2>&1)"
  assert_contains "INNER-OK:" "$out" "the inner bx ran and exec'd its command"
  # The two levels must not share state.
  if [[ -f "$d/outer-state/outer.state" && -f "$d/work/inner-state/inner.state" ]]; then
    _ok
  else
    _fail "the two levels should record separate state files"
  fi
  # The outer machine's recorded shape must carry the widening flag, so the
  # nesting capability is auditable at the level that declared it.
  assert_contains "--privileged" "$(cat "$d/outer-state/outer.state")" \
    "the outer shape records the runtime_args that enable nesting"
  rm -rf "$d"
}

# The lock is per machine *name*, and names are per level, so an inner machine
# must stay reachable even while an outer one is held. This is the property
# that makes recursion safe rather than merely possible.
test_bx_in_bx_locks_are_per_level() {
  _current="inner and outer locks are independent"
  local d out rc
  d="$(_new_workdir)"
  mkdir -p "$d/work"
  cat >"$d/work/.bx.conf" <<'CONF'
[inner]
backend = podman
image   = debian:bookworm-slim
command = true
CONF
  # Hold the OUTER machine's lock, then run the inner bx. The outer run is
  # blocked (expected); the inner one must not be.
  mkdir -p "$d/state/outer.lock.d"
  printf '%s\n' "$$" >"$d/state/outer.lock.d/pid"
  cat >"$d/.bx.conf" <<CONF
[outer]
backend = podman
image   = debian:bookworm-slim
mounts  = $d/work:/work
command = BX_BACKEND=podman BX_STATE_DIR=inner-state BX_NAME=inner \
            PATH=$_fake_nesting_dir:\$PATH ${_bx} inner
CONF
  out="$(cd "$d" && BX_BACKEND=podman BX_NAME=outer BX_STATE_DIR="$d/state" \
    PATH="${_fake_nesting_dir}:$PATH" "$_bx" outer 2>&1)"
  rc=$?
  assert_eq "1" "$rc" "the held outer lock blocks the outer run"
  assert_contains "already being driven" "$out" "the outer run names the holder"
  # The inner name is free, because it is a different machine at a different
  # level with its own state dir.
  out="$(cd "$d/work" && BX_BACKEND=podman BX_NAME=inner \
    BX_STATE_DIR="$d/work/inner-state" PATH="${_fake_nesting_dir}:$PATH" \
    "$_bx" inner 2>&1)"
  rc=$?
  assert_eq "0" "$rc" "the inner machine's name is independent of the outer's"
  rm -rf "$d"
}

_install_fake_smolvm
_install_fake_nesting
trap '_remove_fake_smolvm; _remove_fake_podman; _remove_fake_nesting; [[ -n "$_backend_free_bin" ]] && rm -rf "$_backend_free_bin"' EXIT

_new_workdir() {
  local d
  d="$(mktemp -d)"
  mkdir -p "$d/local"
  printf '%s\n' "$d"
}

# A PATH holding the tools bx needs but no runtime backend. A test whose point
# is "only podman is installed" must not see the host's smolvm, and a developer
# with smolvm installed system-wide would otherwise get a false failure that
# has nothing to do with bx: a backend in `/usr/bin` (or a real one) turns the
# intended single-backend case into an ambiguous one. Symlinking the handful of
# tools bx and the harness use is stable; excluding whole system directories is
# not, because it would also drop the tools.
_backend_free_path() {
  if [[ -z "$_backend_free_bin" ]]; then
    _backend_free_bin="$(mktemp -d)"
    local _t _p
    for _t in bash sh env printf test \
              sed grep awk tr cut sort uniq head tail wc \
              cat ls mkdir rmdir rm cp mv ln pwd dirname basename \
              mktemp chmod touch id uname date sleep kill; do
      _p="$(command -v "$_t" 2>/dev/null)" || continue
      ln -sf "$_p" "${_backend_free_bin}/${_t}"
    done
  fi
  printf '%s' "$_backend_free_bin"
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
net=bridge
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
net=bridge
mounts:
/only:/only
STATE
  out="$(cd "$d" && BX_NAME=m2 BX_MOUNTS="/only:/only" \
    BX_COMMAND="true" BX_STATE_DIR="$d/local" \
    FAKE_VMS="m2" PATH="${_fake_bin_dir}:$PATH" \
    "$_bx" 2>&1)"
  assert_not_contains "creating" "$out" "does not recreate"
  assert_not_contains "reusing" "$out" "stays quiet about reuse"
  # The trace is still available, and is where "reusing" lives now.
  out="$(cd "$d" && BX_VERBOSE=2 BX_NAME=m2 BX_MOUNTS="/only:/only" \
    BX_COMMAND="true" BX_STATE_DIR="$d/local" \
    FAKE_VMS="m2" PATH="${_fake_bin_dir}:$PATH" \
    "$_bx" 2>&1)"
  assert_contains "reusing machine m2" "$out" "traces the reuse under -v"
  rm -rf "$d"
}

test_reset_recreates() {
  _current="BX_RESET recreates over a mismatch"
  local d out
  d="$(_new_workdir)"
  printf 'image=other\n' >"$d/local/m3.state"
  out="$(cd "$d" && BX_VERBOSE=1 BX_NAME=m3 BX_RESET=1 BX_MOUNTS="/x:/x" \
    BX_COMMAND="true" BX_STATE_DIR="$d/local" \
    FAKE_VMS="m3" PATH="${_fake_bin_dir}:$PATH" \
    "$_bx" 2>&1)"
  assert_contains "recreating m3" "$out" "recreates"
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
  out="$(cd "$d" && BX_VERBOSE=1 BX_NAME=m5 BX_COMMAND="true" \
    BX_STATE_DIR="$d/local" PATH="${_fake_bin_dir}:$PATH" \
    "$_bx" 2>&1)"
  rc=$?
  assert_eq "0" "$rc" "proceeds"
  assert_contains "creating m5" "$out" "creates"
  if [[ -d "$d/local/m5.lock.d" ]]; then
    _fail "lock was not released"
  else
    _ok
  fi
  rm -rf "$d"
}

# ── verbosity ───────────────────────────────────────────────────────────────
test_quiet_silences_notes_but_not_errors() {
  _current="--quiet silences status but not errors"
  local d out
  d="$(_new_workdir)"
  # A fresh name the fake does not report, so bx creates and would normally
  # say so; --quiet must swallow that.
  out="$(cd "$d" && BX_VERBOSE=0 BX_NAME=mq BX_COMMAND="true" \
    BX_STATE_DIR="$d/local" \
    PATH="${_fake_bin_dir}:$PATH" \
    "$_bx" 2>&1)"
  assert_eq "" "$out" "no chatter on a quiet run"
  # A genuine resolution error still speaks, even at --quiet.
  printf '[nowhere]\ncommand = true\n' >"$d/.bx.conf"
  out="$(cd "$d" && BX_VERBOSE=0 PATH="${_fake_bin_dir}:$PATH" \
    "$_bx" --machine ghost nowhere 2>&1)"
  assert_contains "not defined" "$out" "errors survive --quiet"
  rm -rf "$d"
}

# ── fidelity ────────────────────────────────────────────────────────────────
test_piped_run_is_quiet() {
  _current="a run with stderr not a tty emits no narration"
  local d out
  d="$(_new_workdir)"
  # The fake reports no machine, so this run would normally say "creating".
  # Captured stderr is not a tty, so run narration must be suppressed.
  out="$(cd "$d" && BX_NAME=pipe BX_COMMAND="true" \
    BX_STATE_DIR="$d/local" \
    PATH="${_fake_bin_dir}:$PATH" \
    "$_bx" 2>&1 >/dev/null)"
  assert_not_contains "creating" "$out" "no create narration when piped"
  assert_not_contains "bx:" "$out" "no bx-prefixed line when piped"
  rm -rf "$d"
}

test_env_passthrough_is_curated() {
  _current="only the curated host env is forwarded"
  local d calls
  d="$(_new_workdir)"
  ( cd "$d" && TERM=xterm-fake LANG=en_US.UTF-8 TZ=UTC \
      AWS_SECRET_ACCESS_KEY="BXSECRET_$RANDOM$RANDOM" EDITOR=ed \
      BX_NAME=envf BX_COMMAND="true" BX_STATE_DIR="$d/local" \
      PATH="${_fake_bin_dir}:$PATH" "$_bx" >/dev/null 2>&1 )
  calls="$(cat "$_fake_log")"
  assert_contains "--env TERM=xterm-fake" "$calls" "TERM forwarded"
  assert_contains "--env LANG=en_US.UTF-8" "$calls" "LANG forwarded"
  assert_not_contains "EDITOR=ed" "$calls" "non-allowlisted var dropped"
  rm -rf "$d"
}

test_signal_reaches_foreground_job() {
  _current="a signal to the foreground job reaches the guest exec"
  local d sig started
  d="$(_new_workdir)"
  sig="$d/sig.txt"
  started="$d/started.txt"
  mkdir -p "$d/bin"
  # A fake smolvm whose machine exec blocks until it is signalled, recording
  # which signal it received. This exercises the signal path without a VM.
  cat >"$d/bin/smolvm" <<FAKE
#!/usr/bin/env bash
sig=$(printf '%q' "$sig")
started=$(printf '%q' "$started")
case "\$1 \$2" in
  "machine ls") ;;
  "machine exec")
    trap 'printf TERM >"\$sig"; exit 143' TERM
    trap 'printf INT  >"\$sig"; exit 130' INT
    : >"\$started"
    while :; do sleep 0.1; done ;;
  *) exit 0 ;;
esac
exit 0
FAKE
  chmod +x "$d/bin/smolvm"
  printf '[f]\nimage = debian:bookworm-slim\nmounts = /tmp:/work\ncommand = sleep 9\n' \
    >"$d/.bx.conf"
  # Job control puts bx in its own process group, which is what a terminal
  # does for the foreground job. A terminal's Ctrl-C/Term then goes to the
  # whole group, so smolvm — running in the foreground of that group — gets it
  # directly, with no forwarding needed. Signal the group, not just bx.
  set -m
  ( cd "$d" && exec env BX_NAME=sigf BX_STATE_DIR="$d/local" \
      PATH="$d/bin:$PATH" "$_bx" f ) >/dev/null 2>&1 &
  local bxpid=$!
  set +m
  local _tries=0
  while [[ ! -f "$started" && "$_tries" -lt 50 ]]; do
    sleep 0.1; _tries=$((_tries + 1))
  done
  kill -TERM -- "-$bxpid" 2>/dev/null || true
  wait "$bxpid" 2>/dev/null || true
  local got=""
  _tries=0
  while [[ ! -s "$sig" && "$_tries" -lt 20 ]]; do
    sleep 0.1; _tries=$((_tries + 1))
  done
  [[ -s "$sig" ]] && got="$(cat "$sig")"
  assert_eq "TERM" "$got" "TERM reached the guest exec"
  rm -rf "$d"
}

test_verbose_shows_smolvm_commands() {
  _current="--verbose shows the smolvm commands bx runs"
  local d out
  d="$(_new_workdir)"
  # First run creates (fake reports no machine).
  out="$(cd "$d" && BX_VERBOSE=2 BX_NAME=mv BX_COMMAND="true" \
    BX_STATE_DIR="$d/local" \
    PATH="${_fake_bin_dir}:$PATH" \
    "$_bx" 2>&1)"
  assert_contains "bx: run:" "$out" "traces commands"
  # Second run reuses: tell the fake the machine now exists.
  out="$(cd "$d" && BX_VERBOSE=2 BX_NAME=mv BX_COMMAND="true" \
    BX_STATE_DIR="$d/local" FAKE_VMS="mv" \
    PATH="${_fake_bin_dir}:$PATH" \
    "$_bx" 2>&1)"
  assert_contains "reusing machine mv" "$out" "traces the reuse"
  rm -rf "$d"
}

test_bootstrap_comment_does_not_end_value() {
  _current="an indented comment inside a bootstrap stays in the value"
  local d out
  d="$(_new_workdir)"
  cat >"$d/.bx.conf" <<'CONF'
[commented]
image    = alpine
mounts   = /a:/a
bootstrap = set -e
    # a comment with = in it
    echo hi
command  = true
CONF
  out="$(cd "$d" && PATH="${_fake_bin_dir}:$PATH" \
    "$_bx" --show commented 2>&1)"
  assert_not_contains "unknown key" "$out" "the comment is not parsed as a key"
  assert_contains "bootstrap=<" "$out" "the bootstrap is still set"
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

# ── a failing step must name itself ─────────────────────────────────────────
# A regression that shipped: a `pre_command` that fails under `set -e` aborted
# bx with its raw status and printed nothing, so `bx pi` looked like a silent
# `exit 1`. The resolver's own pre_command redirected to /dev/null, which hid
# even the runtime's message. These pin that a failed step is reported, that
# its status is preserved, and that the normal path is untouched.
test_failing_pre_command_is_reported() {
  _current="a failing pre_command is reported, not a silent exit"
  local d out rc
  d="$(_new_workdir)"
  out="$(cd "$d" && BX_NAME=mpre BX_COMMAND="true" \
    BX_PRE_COMMAND="exit 3" \
    BX_STATE_DIR="$d/local" PATH="${_fake_bin_dir}:$PATH" \
    "$_bx" 2>&1)"
  rc=$?
  assert_eq "1" "$rc" "bx exits 1 (its own error), not the raw command status"
  assert_contains "pre_command failed" "$out" "the failing step is named"
  assert_contains "exit 3" "$out" "the failing command is shown"
  rm -rf "$d"
}

# The same failure with output redirected — which is how the pi resolver writes
# it — must still be reported by bx, because bx, not the command, is speaking.
test_redirected_pre_command_failure_is_still_reported() {
  _current="a pre_command that redirects its output is still reported"
  local d out rc
  d="$(_new_workdir)"
  out="$(cd "$d" && BX_NAME=mpre2 BX_COMMAND="true" \
    BX_PRE_COMMAND="false >/dev/null 2>&1" \
    BX_STATE_DIR="$d/local" PATH="${_fake_bin_dir}:$PATH" \
    "$_bx" 2>&1)"
  rc=$?
  assert_eq "1" "$rc" "exit status is bx's error, not a silent leak"
  assert_contains "pre_command failed" "$out" "the redirect cannot hide the failure"
  rm -rf "$d"
}

test_failing_bootstrap_is_reported() {
  _current="a failing bootstrap is reported, not a silent exit"
  local d out rc
  d="$(_new_workdir)"
  # FAKE_EXEC_RC drives the fake's `machine exec`, which is the bootstrap.
  out="$(cd "$d" && BX_NAME=mboot BX_COMMAND="true" \
    BX_BOOTSTRAP="echo hi" BX_STATE_DIR="$d/local" \
    FAKE_EXEC_RC=5 PATH="${_fake_bin_dir}:$PATH" \
    "$_bx" 2>&1)"
  rc=$?
  assert_eq "1" "$rc" "bx reports its own failure rather than leaking 5"
  assert_contains "bootstrap failed" "$out" "the failing step is named"
  assert_contains "status 5" "$out" "the underlying status is shown"
  rm -rf "$d"
}

# The normal path must stay faithful: a pre_command that succeeds is silent,
# and the guest's status still passes through untouched.
test_successful_pre_command_is_silent_and_status_passes_through() {
  _current="a succeeding pre_command is silent and the guest status survives"
  local d out rc
  d="$(_new_workdir)"
  out="$(cd "$d" && BX_NAME=mpre3 BX_COMMAND="false" \
    BX_PRE_COMMAND="true" BX_STATE_DIR="$d/local" \
    FAKE_EXEC_RC=9 PATH="${_fake_bin_dir}:$PATH" \
    "$_bx" 2>&1)"
  rc=$?
  assert_eq "9" "$rc" "the guest status is still propagated verbatim"
  assert_not_contains "pre_command" "$out" "a successful pre_command says nothing"
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
net=bridge
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

# ── recipes ─────────────────────────────────────────────────────────────────
# Recipe tests isolate HOME and the working directory so the user's real
# ~/.bx.conf never leaks into a run.
_recipe_env() {
  _rhome="$(mktemp -d)"
  _rproj="$(mktemp -d)"
}

_run_recipe_bx() {
  ( cd "$_rproj" && HOME="$_rhome" \
    PATH="${_fake_bin_dir}:$PATH" XDG_STATE_HOME="$_rproj/state" \
    "$_bx" "$@" 2>&1 )
}

test_recipe_lookup_and_merge() {
  _current="a project recipe merges over home defaults"
  local out
  _recipe_env
  cat >"$_rhome/.bx.conf" <<'EOF'
[test]
command = make test
cpus = 2
EOF
  cat >"$_rproj/.bx.conf" <<'EOF'
[test]
cpus = 8
EOF
  out="$(_run_recipe_bx --show test)"
  assert_contains "command=make test" "$out" "keeps home command"
  assert_contains "cpus=8" "$out" "project overrides cpus"
  rm -rf "$_rhome" "$_rproj"
}

test_recipe_mounts_accumulate() {
  _current="repeated mounts accumulate in read order"
  local out
  _recipe_env
  cat >"$_rhome/.bx.conf" <<'EOF'
[test]
command = true
mounts = /a:/a
EOF
  cat >"$_rproj/.bx.conf" <<'EOF'
[test]
mounts = /b:/b
EOF
  out="$(_run_recipe_bx --show test)"
  assert_contains "/a:/a" "$out" "home mount present"
  assert_contains "/b:/b" "$out" "project mount present"
  if [[ "${out%%/b:/b*}" == *"/a:/a"* ]]; then _ok; else _fail "order was not preserved"; fi
  rm -rf "$_rhome" "$_rproj"
}

test_recipe_variable_expansion() {
  _current="\$PWD expands and a recipe is not shell-evaluated"
  local out
  _recipe_env
  cat >"$_rproj/.bx.conf" <<'EOF'
[echo]
command = true
mounts = $PWD:/work
EOF
  out="$(_run_recipe_bx --show echo)"
  assert_contains "${_rproj}:/work" "$out" "\$PWD expanded"
  cat >"$_rproj/.bx.conf" <<'EOF'
[evil]
command = $(touch /tmp/bx-should-not-exist)
EOF
  out="$(_run_recipe_bx --show evil)"
  # The recipe is data, not shell: $(...) must survive verbatim and must not run.
  _literal='$'"(touch /tmp/bx-should-not-exist)"
  assert_contains "$_literal" "$out" "command substitution is literal"
  if [[ -e /tmp/bx-should-not-exist ]]; then
    _fail "a recipe evaluated shell code"
  else
    _ok
  fi
  rm -rf "$_rhome" "$_rproj" /tmp/bx-should-not-exist
}

test_recipe_unknown_key_is_rejected() {
  _current="a misspelled key is rejected, not ignored"
  local out
  _recipe_env
  printf '[bad]\ncomand = typo\n' >"$_rproj/.bx.conf"
  out="$(_run_recipe_bx --show bad)"
  assert_contains "unknown key 'comand'" "$out" "names the key"
  rm -rf "$_rhome" "$_rproj"
}

test_recipe_unknown_name_is_rejected() {
  _current="an unknown recipe lists what exists"
  local out
  _recipe_env
  out="$(_run_recipe_bx --show nosuch)"
  assert_contains "no recipe named 'nosuch'" "$out" "names the miss"
  assert_contains "pi" "$out" "lists pi"
  rm -rf "$_rhome" "$_rproj"
}

test_recipe_list() {
  _current="--list shows the shipped book and user recipes"
  local out
  _recipe_env
  printf '[alpha]\ncommand = true\n' >"$_rproj/.bx.conf"
  out="$(_run_recipe_bx --list)"
  assert_contains "alpha" "$out" "lists alpha"
  assert_contains "pi" "$out" "lists the shipped pi recipe"
  assert_contains "sandbox" "$out" "lists the shipped sandbox recipe"
  rm -rf "$_rhome" "$_rproj"
}

test_version_reports_the_build() {
  _current="--version identifies the build, so a shell's bx maps to a checkout"
  local out
  _recipe_env
  out="$(_run_recipe_bx --version)"
  assert_contains "bx " "$out" "prints a bx version line"
  assert_contains "recipes:" "$out" "names the recipe book in use"
  assert_contains "machines:" "$out" "names the machine book in use"
  rm -rf "$_rhome" "$_rproj"
}

test_recipe_list_shows_description() {
  _current="--list shows the comment above a recipe as its description"
  local out
  _recipe_env
  printf '# alpha: builds the thing. More prose follows.\n[alpha]\ncommand = true\n' \
    >"$_rproj/.bx.conf"
  out="$(_run_recipe_bx --list)"
  assert_contains "builds the thing." "$out" "shows the first sentence"
  assert_not_contains "More prose" "$out" "cuts after the first sentence"
  # The name is already the column, so it is not repeated as a prefix.
  assert_not_contains "alpha: builds" "$out" "strips the name prefix"
  rm -rf "$_rhome" "$_rproj"
}

test_recipe_list_marks_machines() {
  _current="--list marks a machine recipe, which is never run on its own"
  local out
  _recipe_env
  mkdir -p "$_rproj/.bx/machines"
  printf '[big]\nmounts = $PWD:/work\n' >"$_rproj/.bx/machines/big.conf"
  out="$(_run_recipe_bx --list)"
  assert_contains "big" "$out" "lists the machine"
  assert_contains "(machine)" "$out" "marks it as a machine"
  rm -rf "$_rhome" "$_rproj"
}

test_recipe_typo_suggests_the_close_name() {
  _current="a mistyped recipe suggests the close name"
  local out
  _recipe_env
  printf '[deploy]\ncommand = true\n' >"$_rproj/.bx.conf"
  out="$(_run_recipe_bx deployy)"
  assert_contains "no recipe named 'deployy'" "$out" "names the miss"
  assert_contains "did you mean 'deploy'?" "$out" "suggests deploy"
  rm -rf "$_rhome" "$_rproj"
}

test_recipe_typo_far_away_suggests_nothing() {
  _current="a name with no close match gets no false suggestion"
  local out
  _recipe_env
  printf '[deploy]\ncommand = true\n' >"$_rproj/.bx.conf"
  out="$(_run_recipe_bx zzzzzz)"
  assert_not_contains "did you mean" "$out" "does not guess"
  rm -rf "$_rhome" "$_rproj"
}

test_recipe_book_is_not_compiled_in() {
  _current="bx resolves the shipped recipes with no pi-specific code in bx"
  local out
  _recipe_env
  out="$(_run_recipe_bx --show sandbox)"
  assert_contains "recipe=sandbox" "$out" "resolves the shipped sandbox recipe"
  # The point of the book: bx itself must not name any particular recipe.
  if grep -qi 'subconscious\|\bbx-pi\b' "$_bx"; then
    _fail "bx names a specific recipe's provider"
  else
    _ok
  fi
  rm -rf "$_rhome" "$_rproj"
}

test_recipe_extends_inherits_scalars_and_lists() {
  _current="extends inherits scalars and prepends lists"
  local out
  _recipe_env
  cat >"$_rproj/.bx.conf" <<'EOF'
[base]
image = alpine
cpus = 1
mounts = /base:/base
[child]
extends = base
command = true
mounts = /child:/child
cpus = 2
EOF
  out="$(_run_recipe_bx --show child)"
  assert_contains "cpus=2" "$out" "child overrides a scalar"
  assert_contains "image=alpine" "$out" "child inherits image"
  if [[ "${out%%/child:/child*}" == *"/base:/base"* ]]; then _ok; else _fail "base mount did not precede child"; fi
  rm -rf "$_rhome" "$_rproj"
}

test_recipe_resolver_emits_values() {
  _current="a resolver's values merge and its params interpolate"
  local out
  _recipe_env
  cat >"${_rproj}/mk.resolve" <<'EOF'
#!/usr/bin/env bash
printf '@param GREETING=hi\n'
printf 'name=resolved-name\n'
printf 'command=echo $GREETING\n'
EOF
  chmod +x "${_rproj}/mk.resolve"
  cat >"$_rproj/.bx.conf" <<'EOF'
[r]
resolve = mk.resolve
command = default
EOF
  out="$(BX_RECIPES_DIR="$_rproj" _run_recipe_bx --show r)"
  assert_contains "name=resolved-name" "$out" "resolver sets the machine name"
  assert_contains "echo hi" "$out" "param interpolated into a value"
  rm -rf "$_rhome" "$_rproj"
}

test_recipe_resolver_secrets_stay_out_of_show() {
  _current="resolver secrets are never printed by --show"
  local out
  _recipe_env
  cat >"${_rproj}/sec.resolve" <<'EOF'
#!/usr/bin/env bash
printf '@secret MY_SECRET=swordfish\n'
printf 'command = true\n'
EOF
  chmod +x "${_rproj}/sec.resolve"
  printf '[s]\nresolve = sec.resolve\ncommand = true\n' >"$_rproj/.bx.conf"
  out="$(BX_RECIPES_DIR="$_rproj" _run_recipe_bx --show s)"
  assert_not_contains "swordfish" "$out" "secret value is not printed"
  rm -rf "$_rhome" "$_rproj"
}

test_recipe_resolver_missing_is_reported() {
  _current="a missing resolver is a clear error"
  local out
  _recipe_env
  printf '[x]\nresolve = no-such-resolver\ncommand = true\n' >"$_rproj/.bx.conf"
  out="$(_run_recipe_bx --show x)"
  assert_contains "resolve 'no-such-resolver' not found" "$out" "names the missing resolver"
  rm -rf "$_rhome" "$_rproj"
}

# A regression that shipped: the resolver's status was read from a process
# substitution (`done < <(...)`), which always reports 0, so a resolver that
# failed was ignored and bx carried on with a half-resolved recipe — no name,
# no secrets, no model — and exited 0. For `pi` that is an agent launched with
# nothing it needs. A failing resolver must stop the run.
test_recipe_resolver_failure_stops_the_run() {
  _current="a failing resolver stops the run instead of being ignored"
  local out rc
  _recipe_env
  cat >"${_rproj}/bad.resolve" <<'EOF'
#!/usr/bin/env bash
printf 'bad.resolve: cannot resolve\n' >&2
exit 1
EOF
  chmod +x "${_rproj}/bad.resolve"
  cat >"$_rproj/.bx.conf" <<'EOF'
[r]
resolve = bad.resolve
image = alpine
mounts = /a:/a
command = echo hi
EOF
  out="$(BX_RECIPES_DIR="$_rproj" _run_recipe_bx --dry-run r 2>&1)"
  rc=$?
  assert_eq "1" "$rc" "a failed resolver is a non-zero exit"
  assert_contains "resolver 'bad.resolve' failed" "$out" "names the resolver"
  assert_not_contains "action=create" "$out" "no plan is printed for a half-resolved recipe"
  rm -rf "$_rhome" "$_rproj"
}

# The values a resolver supplies must not be partially applied when it fails.
test_recipe_resolver_failure_does_not_emit_partial_plan() {
  _current="a resolver that fails after emitting lines still stops the run"
  local out rc
  _recipe_env
  cat >"${_rproj}/half.resolve" <<'EOF'
#!/usr/bin/env bash
printf 'name=half-resolved\n'
exit 2
EOF
  chmod +x "${_rproj}/half.resolve"
  printf '[h]\nresolve = half.resolve\nimage = alpine\nmounts = /a:/a\ncommand = true\n' >"$_rproj/.bx.conf"
  out="$(BX_RECIPES_DIR="$_rproj" _run_recipe_bx --dry-run h 2>&1)"
  rc=$?
  assert_eq "1" "$rc" "partial output does not rescue a failed resolver"
  assert_contains "status 2" "$out" "the resolver's status is reported"
  rm -rf "$_rhome" "$_rproj"
}

# macOS `mktemp` requires a template; a bare `mktemp` exits 1 with a usage
# message. `_run_resolver` once used the bare form, so every recipe with a
# resolver failed on macOS. Pin the portable form: put a strict mktemp first on
# PATH and require a successful resolve.
test_recipe_resolver_temp_file_is_portable() {
  _current="the resolver's temp file does not assume GNU mktemp"
  local out _strict
  _recipe_env
  _strict="$(mktemp -d)"
  cat >"${_strict}/mktemp" <<'EOF'
#!/usr/bin/env bash
# Faithful macOS behaviour: no template is an error; a template works.
if [[ $# -eq 0 ]]; then
  printf 'mktemp: too few arguments\n' >&2
  exit 1
fi
exec /bin/mktemp "$@"
EOF
  chmod +x "${_strict}/mktemp"
  cat >"${_rproj}/ok.resolve" <<'EOF'
#!/usr/bin/env bash
printf 'name=portable\n'
EOF
  chmod +x "${_rproj}/ok.resolve"
  printf '[p]\nresolve = ok.resolve\nimage = alpine\nmounts = /a:/a\ncommand = true\n' >"$_rproj/.bx.conf"
  out="$(cd "$_rproj" && HOME="$_rhome" BX_RECIPES_DIR="$_rproj" \
    PATH="${_strict}:$PATH" "$_bx" --show p 2>&1)"
  assert_contains "name=portable" "$out" "a resolver succeeds under a strict mktemp"
  assert_not_contains "too few arguments" "$out" "no bare mktemp invocation leaked"
  rm -rf "$_rhome" "$_rproj" "$_strict"
}

test_recipe_new_scaffolds() {
  _current="--new writes a starter recipe into the user's book"
  local out
  _recipe_env
  out="$(HOME="$_rhome" _run_recipe_bx --new mine)"
  assert_contains "wrote" "$out" "reports the file"
  if [[ -f "${_rhome}/.bx/recipes/mine.conf" ]]; then _ok; else _fail "recipe file was not written"; fi
  # Scaffolding twice must not clobber an edited recipe.
  out="$(HOME="$_rhome" _run_recipe_bx --new mine)"
  assert_contains "already exists" "$out" "refuses to overwrite"
  rm -rf "$_rhome" "$_rproj"
}

test_recipe_machine_is_a_separate_dir() {
  _current="a command recipe names a machine from ~/.bx/machines"
  local out
  _recipe_env
  mkdir -p "$_rhome/.bx/machines" "$_rhome/.bx/recipes"
  cat >"$_rhome/.bx/machines/small.conf" <<'EOF'
[small]
image = alpine
cpus = 1
mem = 512
mounts = $PWD:/work
EOF
  cat >"$_rhome/.bx/recipes/dothing.conf" <<'EOF'
[dothing]
machine = small
command = true
EOF
  out="$(_run_recipe_bx --show dothing)"
  assert_contains "recipe=dothing" "$out" "resolves the command recipe"
  assert_contains "image=alpine" "$out" "takes the machine's image"
  assert_contains "cpus=1" "$out" "takes the machine's cpus"
  assert_contains "command=true" "$out" "keeps the recipe's command"
  assert_contains "machine:small" "$out" "provenance credits the machine"
  rm -rf "$_rhome" "$_rproj"
}

test_recipe_machine_overrides() {
  _current="a command recipe overrides its machine's shape keys"
  local out
  _recipe_env
  mkdir -p "$_rhome/.bx/machines" "$_rhome/.bx/recipes"
  printf '[base]\nimage = alpine\ncpus = 2\nmem = 1024\nmounts = $PWD:/work\n' \
    >"$_rhome/.bx/machines/base.conf"
  printf '[job]\nmachine = base\ncpus = 8\ncommand = true\n' \
    >"$_rhome/.bx/recipes/job.conf"
  out="$(_run_recipe_bx --show job)"
  assert_contains "cpus=8" "$out" "recipe overrides cpus"
  assert_contains "mem=1024" "$out" "keeps machine mem"
  assert_contains "job.cpus=recipe" "$out" "provenance credits the override"
  rm -rf "$_rhome" "$_rproj"
}

test_recipe_machine_flag_replaces_shape() {
  _current="--machine replaces the recipe's machine and its overrides"
  local out
  _recipe_env
  mkdir -p "$_rhome/.bx/machines" "$_rhome/.bx/recipes"
  printf '[small]\nimage = alpine\ncpus = 1\nmem = 512\nmounts = $PWD:/work\n' \
    >"$_rhome/.bx/machines/small.conf"
  printf '[big]\nimage = debian:bookworm-slim\ncpus = 16\nmem = 32768\nmounts = $PWD:/work\n' \
    >"$_rhome/.bx/machines/big.conf"
  printf '[job]\nmachine = small\ncpus = 8\ncommand = true\n' \
    >"$_rhome/.bx/recipes/job.conf"
  out="$(_run_recipe_bx --machine=big --show job)"
  assert_contains "cpus=16" "$out" "uses the named machine's cpus"
  assert_contains "mem=32768" "$out" "uses the named machine's mem"
  assert_contains "job.cpus=ignored:--machine" "$out" "reports the override as ignored"
  assert_contains "command=true" "$out" "keeps the recipe's command"
  rm -rf "$_rhome" "$_rproj"
}

test_recipe_machine_flag_via_env() {
  _current="BX_MACHINE selects a machine like --machine"
  local out
  _recipe_env
  mkdir -p "$_rhome/.bx/machines" "$_rhome/.bx/recipes"
  printf '[big]\nimage = debian:bookworm-slim\ncpus = 16\nmem = 32768\nmounts = $PWD:/work\n' \
    >"$_rhome/.bx/machines/big.conf"
  printf '[job]\ncommand = true\n' >"$_rhome/.bx/recipes/job.conf"
  out="$( cd "$_rproj" && HOME="$_rhome" BX_MACHINE=big \
    PATH="${_fake_bin_dir}:$PATH" XDG_STATE_HOME="$_rproj/state" \
    "$_bx" --show job 2>&1 )"
  assert_contains "cpus=16" "$out" "environment picks the machine"
  rm -rf "$_rhome" "$_rproj"
}

test_recipe_machine_unknown_is_reported() {
  _current="an unknown machine reference is an error"
  local out rc
  _recipe_env
  mkdir -p "$_rhome/.bx/recipes"
  printf '[job]\nmachine = ghost\ncommand = true\n' >"$_rhome/.bx/recipes/job.conf"
  out="$(_run_recipe_bx --show job)"; rc=$?
  assert_eq "1" "$rc" "exits nonzero"
  assert_contains "machine 'ghost' is not defined" "$out" "names the missing machine"
  rm -rf "$_rhome" "$_rproj"
}

test_recipe_machine_self_reference_is_rejected() {
  _current="a recipe cannot name itself as its machine"
  local out rc
  _recipe_env
  mkdir -p "$_rhome/.bx/recipes"
  printf '[job]\nmachine = job\ncommand = true\n' >"$_rhome/.bx/recipes/job.conf"
  out="$(_run_recipe_bx --show job)"; rc=$?
  assert_eq "1" "$rc" "exits nonzero"
  assert_contains "refers to itself" "$out" "explains the self-reference"
  rm -rf "$_rhome" "$_rproj"
}

test_recipe_flat_file_holds_both_kinds() {
  _current="a .bx.conf holds machine and command sections together"
  local out
  _recipe_env
  cat >"$_rhome/.bx.conf" <<'EOF'
[tiny]
image = busybox
cpus = 1
mem = 256
[job]
machine = tiny
command = echo hi
EOF
  out="$(_run_recipe_bx --show job)"
  assert_contains "recipe=job" "$out" "resolves the command section"
  assert_contains "image=busybox" "$out" "takes the machine section's image"
  assert_contains "command=echo hi" "$out" "keeps the command"
  rm -rf "$_rhome" "$_rproj"
}

test_recipe_hyphen_name_is_rejected() {
  _current="a hyphenated recipe name is rejected clearly"
  local out rc
  _recipe_env
  mkdir -p "$_rhome/.bx/machines"
  printf '[go-test]\ncommand = true\n' >"$_rhome/.bx/machines/bad.conf"
  out="$(_run_recipe_bx --show go-test)"; rc=$?
  assert_eq "1" "$rc" "exits nonzero"
  assert_contains "recipe name 'go-test' is invalid" "$out" "explains the bad name"
  rm -rf "$_rhome" "$_rproj"
}

test_recipe_machine_recipe_has_no_command() {
  _current="running a machine recipe directly explains itself"
  local out rc
  _recipe_env
  mkdir -p "$_rhome/.bx/machines"
  printf '[bare]\nimage = alpine\ncpus = 1\nmounts = $PWD:/work\n' \
    >"$_rhome/.bx/machines/bare.conf"
  out="$(_run_recipe_bx bare)"; rc=$?
  assert_eq "1" "$rc" "exits nonzero"
  assert_contains "machine recipe" "$out" "names the kind of recipe"
  assert_contains "machine = bare" "$out" "shows how to use it"
  rm -rf "$_rhome" "$_rproj"
}

test_recipe_machine_extends_inherits() {
  _current="a machine recipe's extends is inherited when referenced"
  local out
  _recipe_env
  mkdir -p "$_rhome/.bx/machines" "$_rhome/.bx/recipes"
  printf '[base]\nimage = alpine\ncpus = 1\nmem = 256\nmounts = $PWD:/work\n' \
    >"$_rhome/.bx/machines/base.conf"
  printf '[derived]\nextends = base\ncpus = 8\n' \
    >"$_rhome/.bx/machines/derived.conf"
  printf '[job]\nmachine = derived\ncommand = true\n' \
    >"$_rhome/.bx/recipes/job.conf"
  out="$(_run_recipe_bx --show job)"
  assert_contains "image=alpine" "$out" "inherits image from the base"
  assert_contains "mem=256" "$out" "inherits mem from the base"
  assert_contains "cpus=8" "$out" "keeps the derived cpus"
  assert_contains "machine:derived" "$out" "provenance credits the machine"
  rm -rf "$_rhome" "$_rproj"
}

test_recipe_profile_hands_off() {
  _current="a profile recipe hands off without creating a machine"
  local out
  _recipe_env
  cat >"${_fake_bin_dir}/fake-profile" <<'EOF'
#!/usr/bin/env bash
printf 'profile-args: %s\n' "$*"
EOF
  chmod +x "${_fake_bin_dir}/fake-profile"
  printf '[pf]\nprofile = fake-profile\n' >"$_rproj/.bx.conf"
  out="$(_run_recipe_bx pf --reset -p hello)"
  assert_contains "profile-args: --reset -p hello" "$out" "forwards args untouched"
  assert_not_contains "creating" "$out" "does not create a machine"
  rm -rf "$_rhome" "$_rproj"
}

# ── secret lifetimes ────────────────────────────────────────────────────────
test_secret_lifetime_defaults_ephemeral() {
  _current="a secret without a lifetime is ephemeral and recorded"
  local d out
  d="$(_new_workdir)"
  out="$(cd "$d" && BX_NAME=sl1 BX_COMMAND="true" \
    BX_SECRET_ENV="API_KEY=THE_KEY" BX_DRY_RUN=1 \
    BX_STATE_DIR="$d/local" THE_KEY=x \
    PATH="${_fake_bin_dir}:$PATH" "$_bx" 2>&1)"
  assert_contains "API_KEY=ephemeral" "$out" "records the default lifetime"
  rm -rf "$d"
}

test_secret_lifetime_explicit() {
  _current="an explicit secret lifetime is parsed and recorded"
  local d out
  d="$(_new_workdir)"
  out="$(cd "$d" && BX_NAME=sl2 BX_COMMAND="true" \
    BX_SECRET_ENV="API_KEY=THE_KEY:session" BX_DRY_RUN=1 \
    BX_STATE_DIR="$d/local" THE_KEY=x \
    PATH="${_fake_bin_dir}:$PATH" "$_bx" 2>&1)"
  assert_contains "API_KEY=session" "$out" "records the explicit lifetime"
  rm -rf "$d"
}

test_secret_lifetime_typo_is_rejected() {
  _current="a misspelled secret lifetime is a hard error"
  local d out
  d="$(_new_workdir)"
  out="$(cd "$d" && BX_NAME=sl3 BX_COMMAND="true" \
    BX_SECRET_ENV="API_KEY=THE_KEY:persistant" \
    BX_STATE_DIR="$d/local" THE_KEY=x \
    PATH="${_fake_bin_dir}:$PATH" "$_bx" 2>&1)"
  assert_contains "unknown lifetime" "$out" "names the bad lifetime"
  rm -rf "$d"
}

test_secret_persisted_warns() {
  _current="a persisted secret produces a warning"
  local d out
  d="$(_new_workdir)"
  out="$(cd "$d" && BX_VERBOSE=1 BX_NAME=sl4 BX_COMMAND="true" \
    BX_SECRET_ENV="API_KEY=THE_KEY:persisted" \
    BX_STATE_DIR="$d/local" THE_KEY=x \
    PATH="${_fake_bin_dir}:$PATH" "$_bx" 2>&1)"
  assert_contains "persisted secret" "$out" "warns"
  rm -rf "$d"
}

# ── dry-run cost model ──────────────────────────────────────────────────────
test_dry_run_reports_cost_model() {
  _current="--dry-run reports cache state and a cost estimate"
  local d out
  d="$(_new_workdir)"
  out="$(cd "$d" && BX_NAME=dc1 BX_COMMAND="true" BX_DRY_RUN=1 \
    BX_STATE_DIR="$d/local" \
    PATH="${_fake_bin_dir}:$PATH" "$_bx" 2>&1)"
  assert_contains "cache_image=" "$out" "reports image cache state"
  assert_contains "estimate=" "$out" "reports an estimate"
  rm -rf "$d"
}

# ── status and gc ───────────────────────────────────────────────────────────
test_status_lists_a_machine() {
  _current="--status lists a machine and where it came from"
  local d out
  d="$(_new_workdir)"
  cat >"$d/local/st1.state" <<STATE
image=debian:bookworm-slim
cpus=4
mem=4096
net=bridge
mounts:
$d:/work
secret_lifetimes:
API_KEY=ephemeral
origin=$d
STATE
  out="$(BX_STATE_DIR="$d/local" PATH="${_fake_bin_dir}:$PATH" \
    "$_bx" --status 2>&1)"
  assert_contains "machine:  st1" "$out" "names the machine"
  assert_contains "origin:   $d (present)" "$out" "reports the origin and it exists"
  assert_contains "secrets:" "$out" "reports the declared secrets"
  # The secret block must not bleed into the following scalar line. This was a
  # real bug: `origin=` was counted as a secret entry.
  assert_not_contains "secrets:  API_KEY=ephemeral, origin" "$out" \
    "the secret block leaked the origin line"
  rm -rf "$d"
}

test_status_marks_orphan() {
  _current="--status marks a machine whose directory is gone"
  local d out
  d="$(_new_workdir)"
  cat >"$d/local/st2.state" <<STATE
image=debian:bookworm-slim
origin=/no/such/dir/really
STATE
  out="$(BX_STATE_DIR="$d/local" PATH="${_fake_bin_dir}:$PATH" \
    "$_bx" --status 2>&1)"
  assert_contains "(gone)" "$out" "marks the orphan"
  rm -rf "$d"
}

test_gc_previews_then_deletes() {
  _current="--gc previews an orphan and only deletes with --yes"
  local d out
  d="$(_new_workdir)"
  cat >"$d/local/gc1.state" <<STATE
image=debian:bookworm-slim
origin=/no/such/dir/really
STATE
  out="$(BX_STATE_DIR="$d/local" PATH="${_fake_bin_dir}:$PATH" \
    "$_bx" --gc 2>&1)"
  assert_contains "reclaim: gc1" "$out" "previews the reclaim"
  assert_contains "pass --yes" "$out" "asks for confirmation"
  if [[ -f "$d/local/gc1.state" ]]; then _ok; else _fail "preview deleted the state"; fi
  out="$(BX_STATE_DIR="$d/local" PATH="${_fake_bin_dir}:$PATH" \
    "$_bx" --gc --yes 2>&1)"
  assert_contains "deleted: gc1" "$out" "deletes with --yes"
  if [[ -f "$d/local/gc1.state" ]]; then _fail "state survived deletion"; else _ok; fi
  rm -rf "$d"
}

test_gc_keeps_live_machine() {
  _current="--gc leaves a machine whose directory still exists"
  local d out
  d="$(_new_workdir)"
  cat >"$d/local/gc2.state" <<STATE
image=debian:bookworm-slim
origin=$d
STATE
  out="$(BX_STATE_DIR="$d/local" PATH="${_fake_bin_dir}:$PATH" \
    "$_bx" --gc 2>&1)"
  assert_contains "nothing to reclaim" "$out" "does not reclaim a live machine"
  rm -rf "$d"
}

# ── shape compatibility on upgrade ──────────────────────────────────────────
test_old_state_file_still_reuses() {
  _current="a pre-upgrade state file (no origin/lifetimes) still reuses"
  local d out
  d="$(_new_workdir)"
  cat >"$d/local/up1.state" <<STATE
image=debian:bookworm-slim
cpus=4
mem=4096
net=bridge
mounts:
/only:/only
STATE
  out="$(cd "$d" && BX_NAME=up1 BX_MOUNTS="/only:/only" \
    BX_COMMAND="true" BX_STATE_DIR="$d/local" FAKE_VMS="up1" \
    PATH="${_fake_bin_dir}:$PATH" "$_bx" 2>&1)"
  assert_not_contains "different shape" "$out" "does not false-conflict"
  assert_not_contains "creating" "$out" "reuses rather than recreating"
  rm -rf "$d"
}

# `net` was a boolean (`1`/`0`) before it was a mode (`bridge`/`none`). A
# machine created then recorded `net=1`, and comparing that verbatim against a
# recipe's normalized `net=bridge` made every such machine demand `--reset` on
# the next run for a difference that does not exist. A record must be compared
# in its own vocabulary, not rewritten, so the state file still says what was
# actually created.
test_legacy_boolean_net_record_still_reuses() {
  _current="a record with net=1 reuses against a net=bridge recipe"
  local d out
  d="$(_new_workdir)"
  cat >"$d/local/upnet.state" <<STATE
image=debian:bookworm-slim
cpus=4
mem=4096
net=1
mounts:
/only:/only
STATE
  out="$(cd "$d" && BX_NAME=upnet BX_MOUNTS="/only:/only" BX_NET=bridge \
    BX_COMMAND="true" BX_STATE_DIR="$d/local" FAKE_VMS="upnet" \
    PATH="${_fake_bin_dir}:$PATH" "$_bx" 2>&1)"
  assert_not_contains "different shape" "$out" "net=1 is the same machine as net=bridge"
  assert_not_contains "creating" "$out" "reuses rather than recreating"
  # The recorded shape is evidence, not a cache to normalize in place.
  if ! grep -q '^net=1$' "$d/local/upnet.state"; then
    _fail "the recorded shape was rewritten instead of compared in its own vocabulary"
  else
    _ok
  fi
  rm -rf "$d"
}

# The normalization must not blunt the real check: a genuine move to a
# different network is still a shape change and still needs --reset.
test_legacy_net_record_still_detects_a_real_change() {
  _current="a record with net=1 still conflicts when the recipe changes the mode"
  local d out
  d="$(_new_workdir)"
  cat >"$d/local/upnet2.state" <<STATE
image=debian:bookworm-slim
cpus=4
mem=4096
net=1
mounts:
/only:/only
STATE
  out="$(cd "$d" && BX_NAME=upnet2 BX_MOUNTS="/only:/only" BX_NET=none \
    BX_COMMAND="true" BX_STATE_DIR="$d/local" FAKE_VMS="upnet2" \
    PATH="${_fake_bin_dir}:$PATH" "$_bx" 2>&1)"
  assert_contains "different shape" "$out" "net=1 to net=none is a real change"
  assert_contains "--reset" "$out" "names the fix"
  rm -rf "$d"
}

# ── the container backend ───────────────────────────────────────────────────
# bx inside a machine cannot boot a machine, but it can run a container. These
# pin that the same lifecycle verbs reach podman, that the shape records which
# backend owns it, and that the two backends are never silently interchanged.
_install_fake_podman

# A machine recipe that chooses the container backend, run with the fake
# podman on PATH and a fresh state dir.
test_container_backend_creates_and_execs() {
  _current="backend=podman creates a container and execs into it"
  local d out calls
  d="$(_new_workdir)"
  cat >"$d/.bx.conf" <<'CONF'
[ctr]
backend = podman
image   = debian:bookworm-slim
mounts  = /only:/only
command = true
CONF
  out="$(cd "$d" && BX_NAME=ctrinv BX_STATE_DIR="$d/local" \
    PATH="${_fake_podman_dir}:$PATH" "$_bx" ctr 2>&1)"
  calls="$(cat "$_fake_podman_log" 2>/dev/null)"
  assert_contains "create --name ctrinv" "$calls" "creates a container"
  assert_contains "-v /only:/only" "$calls" "bind-mounts the mount"
  assert_contains "start ctrinv" "$calls" "starts it"
  assert_contains "exec" "$calls" "execs the command"
  assert_contains "stop ctrinv" "$calls" "stops it on the way out"
  rm -rf "$d"
}

# The shape records the backend, so a machine built as a vm is never reused as
# a container (or vice versa): the runtime that owns the mounts is different.
test_backend_is_part_of_the_shape() {
  _current="changing backend is a shape change, and refuses to reuse"
  local d out
  d="$(_new_workdir)"
  cat >"$d/local/bmix.state" <<'STATE'
image=debian:bookworm-slim
cpus=4
mem=4096
net=bridge
backend=podman
mounts:
/only:/only
STATE
  out="$(cd "$d" && BX_NAME=bmix BX_MOUNTS="/only:/only" \
    BX_COMMAND="true" BX_STATE_DIR="$d/local" FAKE_VMS="bmix" \
    PATH="${_fake_bin_dir}:$PATH" "$_bx" 2>&1)"
  assert_contains "different shape" "$out" "refuses the wrong backend"
  assert_contains "backend=podman" "$out" "shows what was recorded"
  assert_contains "--reset" "$out" "names the fix"
  rm -rf "$d"
}

# A recipe that says nothing gets smolvm when smolvm is present, even if
# podman is too. The backend is only inferred when there is no choice.
test_backend_asks_when_both_are_installed() {
  _current="with smolvm and podman installed and no choice, bx stops to ask"
  local d out
  d="$(_new_workdir)"
  : >"$_fake_podman_log"
  # Both are available on PATH and no backend is named. Without a terminal the
  # prompt cannot be answered, so bx must fail naming both choices rather than
  # silently picking one.
  out="$(cd "$d" && env -u BX_BACKEND BX_NAME=amb BX_MOUNTS="/only:/only" \
    BX_COMMAND="true" BX_STATE_DIR="$d/local" FAKE_VMS= \
    PATH="${_fake_bin_dir}:${_fake_podman_dir}:$PATH" "$_bx" 2>&1)"
  assert_contains "not interactive" "$out" "refuses to guess without a terminal"
  assert_contains "backend = smolvm" "$out" "offers smolvm"
  assert_contains "backend = podman" "$out" "offers podman"
  rm -rf "$d"
}

# Exactly one backend installed and no request to be asked: using it is not a
# guess, so bx proceeds without a prompt.
test_backend_uses_the_only_installed_backend() {
  _current="with no smolvm and only podman, the container backend is chosen"
  local d out calls
  d="$(_new_workdir)"
  : >"$_fake_podman_log"
  # No explicit backend: the harness exports BX_BACKEND=smolvm, so unset it to
  # exercise the auto-choice. Only podman is on PATH, so no prompt is needed.
  out="$(cd "$d" && env -u BX_BACKEND BX_VERBOSE=1 BX_NAME=infonly BX_MOUNTS="/only:/only" \
    BX_COMMAND="true" BX_STATE_DIR="$d/local" \
    PATH="${_fake_podman_dir}:$(_backend_free_path)" "$_bx" 2>&1)"
  calls="$(cat "$_fake_podman_log" 2>/dev/null)"
  assert_contains "exec" "$calls" "runs through podman"
  rm -rf "$d"
}

# `backend_prompt` is the escape hatch: even with a single backend installed,
# ask rather than choose. Without a terminal that is a hard error, which is how
# the test observes that the prompt path was taken.
test_backend_prompt_forces_a_question() {
  _current="backend_prompt asks even when only one backend is installed"
  local d out
  d="$(_new_workdir)"
  out="$(cd "$d" && env -u BX_BACKEND BX_BACKEND_PROMPT=1 BX_NAME=forced \
    BX_MOUNTS="/only:/only" BX_COMMAND="true" BX_STATE_DIR="$d/local" \
    PATH="${_fake_podman_dir}:$(_backend_free_path)" "$_bx" 2>&1)"
  assert_contains "not interactive" "$out" "asks despite a single backend"
  rm -rf "$d"
}

# With no backend installed at all, bx must say so. It once exited 1 with no
# output: `_backend_available_list` returns non-zero when nothing is found, and
# under `set -o pipefail` the command substitution that joins the list failed,
# so `set -e` aborted before the `no backend installed` message was reached.
# A machine that cannot run anything still has to explain itself.
test_no_backend_is_never_a_silent_exit() {
  _current="no backend on PATH is reported, not silently exited"
  local d out rc
  d="$(_new_workdir)"
  out="$(cd "$d" && env -u BX_BACKEND BX_NAME=none BX_MOUNTS="/only:/only" \
    BX_COMMAND="true" BX_STATE_DIR="$d/local" \
    PATH="$(_backend_free_path)" "$_bx" 2>&1)"
  rc=$?
  assert_eq "1" "$rc" "fails when no backend is installed"
  assert_contains "no backend installed" "$out" "names the problem"
  assert_contains "smolvm" "$out" "names smolvm as a choice"
  assert_contains "podman" "$out" "names podman as a choice"
  rm -rf "$d"
}

# The same empty list must not break `--dry-run`, whose contract is that it
# needs no runtime: bx plans with the default backend and says it is absent.
test_dry_run_plans_without_a_backend() {
  _current="--dry-run plans even when no backend is installed"
  local d out rc
  d="$(_new_workdir)"
  out="$(cd "$d" && env -u BX_BACKEND BX_DRY_RUN=1 BX_NAME=noback \
    BX_MOUNTS="/only:/only" BX_COMMAND="true" BX_STATE_DIR="$d/local" \
    PATH="$(_backend_free_path)" "$_bx" 2>&1)"
  rc=$?
  assert_eq "0" "$rc" "dry-run succeeds with no backend"
  assert_contains "estimate=" "$out" "still prints the plan"
  rm -rf "$d"
}

# An explicit choice is never questioned: a recipe that names smolvm must not
# prompt even when both are installed.
test_explicit_backend_never_prompts() {
  _current="an explicit backend is used without asking"
  local d out
  d="$(_new_workdir)"
  cat >"$d/.bx.conf" <<'CONF'
[explicit]
backend = smolvm
image   = debian:bookworm-slim
mounts  = /only:/only
command = true
CONF
  out="$(cd "$d" && env -u BX_BACKEND BX_NAME=ex BX_STATE_DIR="$d/local" FAKE_VMS= \
    PATH="${_fake_bin_dir}:${_fake_podman_dir}:$PATH" "$_bx" explicit 2>&1)"
  assert_not_contains "not interactive" "$out" "did not ask"
  rm -rf "$d"
}

# A secret crosses by name on both backends: podman has no --secret-env, so bx
# uses `-e GUEST` and exports the host variable. The value must never appear in
# argv, which is the invariant the whole secret design rests on.
test_container_backend_secret_stays_out_of_argv() {
  _current="a container secret is passed by name, never in podman argv"
  local d calls sentinel
  d="$(_new_workdir)"
  sentinel="SENTINEL-ctr-$$-secret"
  : >"$_fake_podman_log"
  cat >"$d/.bx.conf" <<'CONF'
[sec]
backend    = podman
image      = debian:bookworm-slim
mounts     = /only:/only
secret_env = API_KEY=THE_SECRET_VAR:ephemeral
command    = true
CONF
  (cd "$d" && THE_SECRET_VAR="$sentinel" BX_NAME=secctr BX_STATE_DIR="$d/local" \
    PATH="${_fake_podman_dir}:/usr/bin:/bin" "$_bx" sec >/dev/null 2>&1)
  calls="$(cat "$_fake_podman_log" 2>/dev/null)"
  assert_contains "-e API_KEY" "$calls" "passes the guest name through"
  assert_not_contains "$sentinel" "$calls" "the value never reached argv"
  rm -rf "$d"
}

# --dry-run must plan for the backend without invoking it, the same promise it
# makes for smolvm. A plan is inspectable on a host that cannot run either.
test_dry_run_reports_backend() {
  _current="--dry-run prints the backend and does not invoke it"
  local d out calls
  d="$(_new_workdir)"
  : >"$_fake_podman_log"
  cat >"$d/.bx.conf" <<'CONF'
[ctr]
backend = podman
image   = debian:bookworm-slim
mounts  = /only:/only
command = true
CONF
  out="$(cd "$d" && BX_DRY_RUN=1 BX_NAME=dryctr BX_STATE_DIR="$d/local" \
    PATH="${_fake_podman_dir}:/usr/bin:/bin" "$_bx" ctr 2>&1)"
  calls="$(cat "$_fake_podman_log" 2>/dev/null)"
  assert_contains "backend=podman" "$out" "plans for the container backend"
  # Querying is not acting: dry-run may ask whether a machine or image exists,
  # but it must never create, start, stop, or exec.
  assert_not_contains "create --name" "$calls" "does not create"
  assert_not_contains "exec" "$calls" "does not exec"
  rm -rf "$d"
}

# An unknown backend is a hard error, not a silent fall back to smolvm.
test_unknown_backend_is_rejected() {
  _current="an unknown backend is rejected, not silently defaulted"
  local d out
  d="$(_new_workdir)"
  cat >"$d/.bx.conf" <<'CONF'
[bad]
backend = docker
image   = debian:bookworm-slim
mounts  = /only:/only
command = true
CONF
  out="$(cd "$d" && BX_NAME=badinv BX_STATE_DIR="$d/local" \
    PATH="${_fake_bin_dir}:$PATH" "$_bx" bad 2>&1)"
  assert_contains "unknown backend 'docker'" "$out" "names the bad backend"
  assert_contains "smolvm" "$out" "says what was expected"
  rm -rf "$d"
}

test_backends_implement_the_same_verbs() {
  _current="every backend implements the same lifecycle verbs"
  local _sm _pd
  _sm="$(grep -oE '^bk_smolvm_[a-z_]+' "$_bx" | sed 's/^bk_smolvm_//' | sort)"
  _pd="$(grep -oE '^bk_podman_[a-z_]+' "$_bx" | sed 's/^bk_podman_//' | sort)"
  if [[ -z "$_sm" ]]; then
    _fail "no smolvm backend verbs found; did the naming scheme change?"
    return
  fi
  assert_eq "$_sm" "$_pd" "backends disagree on the verb set"
}

# ── exec: borrow a running machine, do not own it ───────────────────────────
# `bx exec` is the inspection path: look inside the machine a bot is running
# in, run one command, and leave. The guarantees are negative — it must not
# create, start, stop, or lock — because the whole value is that it is safe to
# run against a machine someone else is driving.

# The happy path: an origin-matched machine is found, attached to, and the
# command's status is this command's status.
test_exec_runs_in_the_directorys_machine() {
  _current="exec finds this directory's machine and propagates its status"
  local d out rc
  d="$(_new_workdir)"
  cat >"$d/local/em.state" <<STATE
image=debian:bookworm-slim
cpus=4
mem=4096
net=bridge
backend=smolvm
mounts:
$d:/work
origin=$d
STATE
  out="$(cd "$d" && FAKE_VMS=em FAKE_EXEC_RC=0 BX_STATE_DIR="$d/local" \
    PATH="${_fake_bin_dir}:$PATH" "$_bx" exec ls -la /work/foo 2>&1)"
  rc=$?
  assert_eq "0" "$rc" "exec succeeds"
  # The command reaches the guest as a single shell line, arguments intact.
  assert_contains "machine exec --name em -- bash -lc ls -la /work/foo" \
    "$(cat "$_fake_log")" "the command is forwarded to the machine"

  # A non-zero guest status is not flattened.
  : >"$_fake_log"
  (cd "$d" && FAKE_VMS=em FAKE_EXEC_RC=42 BX_STATE_DIR="$d/local" \
    PATH="${_fake_bin_dir}:$PATH" "$_bx" exec false >/dev/null 2>&1)
  rc=$?
  assert_eq "42" "$rc" "exec propagates the guest status"
  rm -rf "$d"
}

# The defining negative: exec touches nothing about the lifecycle.
test_exec_does_not_own_the_lifecycle() {
  _current="exec never creates, starts, stops, or locks"
  local d calls
  d="$(_new_workdir)"
  cat >"$d/local/eo.state" <<STATE
image=debian:bookworm-slim
cpus=4
mem=4096
net=bridge
backend=smolvm
mounts:
$d:/work
origin=$d
STATE
  : >"$_fake_log"
  (cd "$d" && FAKE_VMS=eo BX_STATE_DIR="$d/local" \
    PATH="${_fake_bin_dir}:$PATH" "$_bx" exec true >/dev/null 2>&1)
  calls="$(cat "$_fake_log")"
  assert_contains "machine exec" "$calls" "it does exec"
  assert_not_contains "machine create" "$calls" "it does not create"
  assert_not_contains "machine start" "$calls" "it does not start"
  assert_not_contains "machine stop" "$calls" "it does not stop"
  if [[ -d "$d/local/eo.lock.d" ]]; then
    _fail "exec took the lifecycle lock"
  else
    _ok
  fi
  rm -rf "$d"
}

# exec must be usable *while* the machine is held by the bx that owns it —
# that is the entire point: peeking at a bot that is currently running.
test_exec_works_while_the_lifecycle_lock_is_held() {
  _current="exec attaches even when the owning run holds the lock"
  local d out rc holder
  d="$(_new_workdir)"
  cat >"$d/local/el.state" <<STATE
image=debian:bookworm-slim
cpus=4
mem=4096
net=bridge
backend=smolvm
mounts:
$d:/work
origin=$d
STATE
  mkdir -p "$d/local/el.lock.d"
  sleep 300 &
  holder=$!
  printf '%s\n' "$holder" >"$d/local/el.lock.d/pid"
  out="$(cd "$d" && FAKE_VMS=el BX_STATE_DIR="$d/local" \
    PATH="${_fake_bin_dir}:$PATH" "$_bx" exec true 2>&1)"
  rc=$?
  kill "$holder" 2>/dev/null || true
  assert_eq "0" "$rc" "exec is not blocked by the lifecycle lock"
  rm -rf "$d"
}

# An absent machine is an error, not an excuse to create one: inspecting a bot
# that is not there must not silently boot a different machine.
test_exec_refuses_a_missing_machine() {
  _current="exec refuses when there is no machine for the directory"
  local d out rc
  d="$(_new_workdir)"
  out="$(cd "$d" && BX_STATE_DIR="$d/local" \
    PATH="${_fake_bin_dir}:$PATH" "$_bx" exec ls 2>&1)"
  rc=$?
  assert_eq "1" "$rc" "exec fails with no machine"
  assert_contains "no machine for" "$out" "says there is no machine"
  assert_contains "bx pi" "$out" "names how to start one"
  assert_not_contains "create" "$(cat "$_fake_log")" "it did not create anything"
  rm -rf "$d"
}

# A machine that exists but is stopped is also a refusal: exec does not start
# it, because starting is the owner's job and would change what is running.
test_exec_refuses_a_stopped_machine() {
  _current="exec refuses to start a stopped machine"
  local d out rc calls
  d="$(_new_workdir)"
  cat >"$d/local/es.state" <<STATE
image=debian:bookworm-slim
cpus=4
mem=4096
net=bridge
backend=smolvm
mounts:
$d:/work
origin=$d
STATE
  : >"$_fake_log"
  out="$(cd "$d" && FAKE_VMS="" BX_STATE_DIR="$d/local" \
    PATH="${_fake_bin_dir}:$PATH" "$_bx" exec ls 2>&1)"
  rc=$?
  calls="$(cat "$_fake_log")"
  assert_eq "1" "$rc" "exec fails on a stopped machine"
  assert_contains "is not running" "$out" "says it is stopped"
  assert_not_contains "machine start" "$calls" "it did not start it"
  rm -rf "$d"
}

# Two machines in one directory is ambiguous, and guessing is the surprise to
# avoid: exec names the conflict and asks for --name.
test_exec_refuses_an_ambiguous_directory() {
  _current="exec refuses to guess between two machines in one directory"
  local d out rc
  d="$(_new_workdir)"
  local n
  for n in amb1 amb2; do
    cat >"$d/local/$n.state" <<STATE
image=debian:bookworm-slim
cpus=4
mem=4096
net=bridge
backend=smolvm
mounts:
$d:/work
origin=$d
STATE
  done
  out="$(cd "$d" && FAKE_VMS="amb1 amb2" BX_STATE_DIR="$d/local" \
    PATH="${_fake_bin_dir}:$PATH" "$_bx" exec ls 2>&1)"
  rc=$?
  assert_eq "1" "$rc" "exec fails when the directory is ambiguous"
  assert_contains "--name" "$out" "asks for the machine to be named"

  # Naming one resolves it.
  out="$(cd "$d" && FAKE_VMS="amb1 amb2" BX_STATE_DIR="$d/local" \
    PATH="${_fake_bin_dir}:$PATH" "$_bx" exec --name=amb2 ls 2>&1)"
  rc=$?
  assert_eq "0" "$rc" "--name picks a machine"
  rm -rf "$d"
}

# exec must not require a recipe or a command to be named for the machine: the
# machine is the directory's, so a bare command is the whole invocation.
test_exec_needs_a_command() {
  _current="exec with no command is a clear error"
  local out rc
  out="$("$_bx" exec 2>&1)"
  rc=$?
  assert_eq "1" "$rc" "exec with no command fails"
  assert_contains "bx exec <command>" "$out" "shows the form"
}

# ── the backend contract, exercised on *both* backends ──────────────────────
# Verb presence is not a contract. These run the same observable behaviour
# through each backend and assert the behaviour, not the wiring: a podman exec
# that forgot to propagate the status, or a podman machine that skipped the
# lock, would still pass the verb-present check above. `fake_for` puts the
# right fake runtime on PATH and points BX_BACKEND at it, so one scenario body
# runs against whichever backend is named.
_fake_for() { # backend -> directory holding just that fake, sets $FAKE_DIR/$FAKE_CALLS
  case "$1" in
    smolvm) FAKE_DIR="$_fake_bin_dir"; FAKE_CALLS="$_fake_log";;
    podman) FAKE_DIR="$_fake_podman_dir"; FAKE_CALLS="$_fake_podman_log";;
    *) _fail "no fake for backend '$1'"; return 1;;
  esac
}

# Both backends must exit with the guest command's status, not flatten it.
test_exit_status_parity() {
  _current="exit status propagates on every backend"
  local _b d rc
  for _b in smolvm podman; do
    _fake_for "$_b" || return
    d="$(_new_workdir)"
    ( cd "$d" && BX_BACKEND="$_b" BX_NAME="rc-$_b" BX_COMMAND="false" \
      BX_STATE_DIR="$d/local" FAKE_EXEC_RC=7 \
      PATH="${FAKE_DIR}:$PATH" "$_bx" >/dev/null 2>&1 )
    rc=$?
    assert_eq "7" "$rc" "$_b preserves the guest exit status"
    rm -rf "$d"
  done
}

# Both backends must refuse a live lock, and recover from a dead one. A second
# run sharing the first's vm is the failure this exists to prevent, and it is
# as wrong for a container as for a vm.
test_lock_parity() {
  _current="the lock blocks and recovers on every backend"
  local _b d out rc
  for _b in smolvm podman; do
    _fake_for "$_b" || return
    d="$(_new_workdir)"
    mkdir -p "$d/local/lk-$_b.lock.d"
    printf '%s\n' "$$" >"$d/local/lk-$_b.lock.d/pid"
    out="$(cd "$d" && BX_BACKEND="$_b" BX_NAME="lk-$_b" BX_COMMAND=true \
      BX_STATE_DIR="$d/local" PATH="${FAKE_DIR}:$PATH" "$_bx" 2>&1)"
    rc=$?
    assert_eq "1" "$rc" "$_b refuses a held lock"
    assert_contains "already being driven" "$out" "$_b names the holder"
    rm -rf "$d"
  done
}

# Both backends must reconcile, not silently reuse, a machine whose shape
# changed. This is the property the whole tool is built around; it cannot be a
# vm-only guarantee.
test_shape_reconcile_parity() {
  _current="a changed mount set conflicts on every backend"
  local _b d out
  for _b in smolvm podman; do
    _fake_for "$_b" || return
    d="$(_new_workdir)"
    cat >"$d/local/sh-$_b.state" <<STATE
image=debian:bookworm-slim
cpus=4
mem=4096
net=bridge
backend=$_b
mounts:
/old:/old
STATE
    out="$(cd "$d" && BX_BACKEND="$_b" BX_NAME="sh-$_b" BX_MOUNTS="/new:/new" \
      BX_COMMAND=true BX_STATE_DIR="$d/local" FAKE_VMS="sh-$_b" \
      FAKE_CONTAINERS="sh-$_b" PATH="${FAKE_DIR}:$PATH" "$_bx" 2>&1)"
    assert_contains "different shape" "$out" "$_b refuses the reused machine"
    assert_contains "--reset" "$out" "$_b names the fix"
    rm -rf "$d"
  done
}

# And both must finish the lifecycle: stop the machine and release the lock on
# the way out, including when the guest command failed.
test_cleanup_parity() {
  _current="stop and unlock happen on every backend, even on failure"
  local _b d calls rc
  for _b in smolvm podman; do
    _fake_for "$_b" || return
    d="$(_new_workdir)"
    : >"$FAKE_CALLS"
    ( cd "$d" && BX_BACKEND="$_b" BX_NAME="cl-$_b" BX_COMMAND=false \
      BX_STATE_DIR="$d/local" FAKE_EXEC_RC=3 PATH="${FAKE_DIR}:$PATH" \
      "$_bx" >/dev/null 2>&1 )
    rc=$?
    calls="$(cat "$FAKE_CALLS" 2>/dev/null)"
    assert_eq "3" "$rc" "$_b keeps the failed status through cleanup"
    if [[ "$_b" == "smolvm" ]]; then
      assert_contains "machine stop" "$calls" "$_b stops a failed machine"
    else
      assert_contains "stop cl-$_b" "$calls" "$_b stops a failed container"
    fi
    if [[ -d "$d/local/cl-$_b.lock.d" ]]; then
      _fail "$_b left the lock behind after a failed run"
    else
      _ok
    fi
    rm -rf "$d"
  done
}

_install_fake_smolvm
trap '_remove_fake_smolvm; _remove_fake_podman' EXIT

test_dry_run_plan
test_conflict_on_changed_mounts
test_reuse_on_unchanged_shape
test_reset_recreates
test_lock_blocks_live_holder
test_lock_recovers_from_dead_holder
test_quiet_silences_notes_but_not_errors
test_verbose_shows_smolvm_commands
test_piped_run_is_quiet
test_env_passthrough_is_curated
test_signal_reaches_foreground_job
test_bootstrap_comment_does_not_end_value
test_guest_exit_status_propagates
test_empty_input_does_not_abort
test_failing_pre_command_is_reported
test_redirected_pre_command_failure_is_still_reported
test_failing_bootstrap_is_reported
test_successful_pre_command_is_silent_and_status_passes_through
test_cpu_change_conflicts
test_unknown_option_is_rejected
test_invalid_machine_name_is_rejected
test_recipe_lookup_and_merge
test_recipe_mounts_accumulate
test_recipe_variable_expansion
test_recipe_unknown_key_is_rejected
test_recipe_unknown_name_is_rejected
test_recipe_list
test_version_reports_the_build
test_recipe_list_shows_description
test_recipe_list_marks_machines
test_recipe_typo_suggests_the_close_name
test_recipe_typo_far_away_suggests_nothing
test_recipe_book_is_not_compiled_in
test_recipe_extends_inherits_scalars_and_lists
test_recipe_resolver_emits_values
test_recipe_resolver_secrets_stay_out_of_show
test_recipe_resolver_missing_is_reported
test_recipe_resolver_failure_stops_the_run
test_recipe_resolver_failure_does_not_emit_partial_plan
test_recipe_resolver_temp_file_is_portable
test_recipe_new_scaffolds
test_recipe_profile_hands_off
test_recipe_machine_is_a_separate_dir
test_recipe_machine_overrides
test_recipe_machine_flag_replaces_shape
test_recipe_machine_flag_via_env
test_recipe_machine_unknown_is_reported
test_recipe_machine_self_reference_is_rejected
test_recipe_flat_file_holds_both_kinds
test_recipe_hyphen_name_is_rejected
test_recipe_machine_recipe_has_no_command
test_recipe_machine_extends_inherits

# New in S-tier: typed secrets, a cost model, and fleet legibility.
test_secret_lifetime_defaults_ephemeral
test_secret_lifetime_explicit
test_secret_lifetime_typo_is_rejected
test_secret_persisted_warns
test_dry_run_reports_cost_model
test_status_lists_a_machine
test_status_marks_orphan
test_gc_previews_then_deletes
test_gc_keeps_live_machine
test_old_state_file_still_reuses
test_legacy_boolean_net_record_still_reuses
test_legacy_net_record_still_detects_a_real_change
test_container_backend_creates_and_execs
test_backend_is_part_of_the_shape
test_backend_asks_when_both_are_installed
test_backend_uses_the_only_installed_backend
test_backend_prompt_forces_a_question
test_no_backend_is_never_a_silent_exit
test_dry_run_plans_without_a_backend
test_explicit_backend_never_prompts
test_container_backend_secret_stays_out_of_argv
test_dry_run_reports_backend
test_unknown_backend_is_rejected

# `net` is a mode, not a flag, and each mode has to reach the runtime as the
# right flag. `none`/`bridge`/`host` are the vocabulary; `0`/`1` are kept as
# aliases for the modes they always meant.
test_net_modes_reach_the_container() {
  _current="net modes reach podman as the right flag"
  local d calls
  : >"$_fake_podman_log"
  d="$(_new_workdir)"
  cat >"$d/.bx.conf" <<'CONF'
[ctr]
backend = podman
image   = debian:bookworm-slim
net     = host
mounts  = /only:/only
command = true
CONF
  (cd "$d" && BX_NAME=nethost BX_STATE_DIR="$d/local" \
    PATH="${_fake_podman_dir}:/usr/bin:/bin" "$_bx" ctr >/dev/null 2>&1)
  calls="$(cat "$_fake_podman_log" 2>/dev/null)"
  assert_contains "--network=host" "$calls" "host mode shares the namespace"
  rm -rf "$d"

  : >"$_fake_podman_log"
  d="$(_new_workdir)"
  cat >"$d/.bx.conf" <<'CONF'
[ctr]
backend = podman
image   = debian:bookworm-slim
net     = none
mounts  = /only:/only
command = true
CONF
  (cd "$d" && BX_NAME=netnone BX_STATE_DIR="$d/local" \
    PATH="${_fake_podman_dir}:/usr/bin:/bin" "$_bx" ctr >/dev/null 2>&1)
  calls="$(cat "$_fake_podman_log" 2>/dev/null)"
  assert_contains "--network=none" "$calls" "none mode cuts the network"
  rm -rf "$d"
}

# The legacy boolean still means what it always did: 1 is the runtime bridge,
# 0 is no network. A recipe written before modes existed keeps working.
test_net_boolean_still_means_a_mode() {
  _current="net = 1/0 stay aliases for bridge/none"
  local d out
  d="$(_new_workdir)"
  cat >"$d/.bx.conf" <<'CONF'
[ctr]
backend = podman
image   = debian:bookworm-slim
net     = 1
mounts  = /only:/only
command = true
CONF
  out="$(cd "$d" && BX_NESTED_NET=normal BX_NAME=netbool \
    BX_STATE_DIR="$d/local" \
    PATH="${_fake_podman_dir}:/usr/bin:/bin" "$_bx" --dry-run ctr 2>&1)"
  assert_contains "net=bridge" "$out" "1 is bridge"

  cat >"$d/.bx.conf" <<'CONF'
[ctr]
backend = podman
image   = debian:bookworm-slim
net     = 0
mounts  = /only:/only
command = true
CONF
  out="$(cd "$d" && BX_NAME=netbool BX_STATE_DIR="$d/local" \
    PATH="${_fake_podman_dir}:/usr/bin:/bin" "$_bx" --dry-run ctr 2>&1)"
  assert_contains "net=none" "$out" "0 is none"
  rm -rf "$d"
}

# A mode that is not a mode is a hard error, not a silent default.
test_net_bogus_mode_is_rejected() {
  _current="an unknown net mode is rejected"
  local d out
  d="$(_new_workdir)"
  out="$(cd "$d" && BX_NET=bogus BX_COMMAND=true BX_MOUNTS="/a:/a" \
    BX_STATE_DIR="$d/local" PATH="${_fake_bin_dir}:$PATH" \
    "$_bx" 2>&1)"
  assert_contains "not a mode" "$out" "names the problem"
  assert_contains "none, bridge, or host" "$out" "names the vocabulary"
  rm -rf "$d"
}

# The mode is part of the shape, so changing it forces a recreate rather than
# silently moving a machine onto a different network.
test_net_mode_is_part_of_the_shape() {
  _current="changing net is a shape change"
  local d out
  d="$(_new_workdir)"
  cat >"$d/local/nshape.state" <<'STATE'
image=debian:bookworm-slim
cpus=4
mem=4096
net=none
backend=podman
mounts:
/only:/only
STATE
  cat >"$d/.bx.conf" <<'CONF'
[ctr]
backend = podman
image   = debian:bookworm-slim
net     = host
mounts  = /only:/only
command = true
CONF
  out="$(cd "$d" && FAKE_CONTAINERS=nshape BX_NAME=nshape \
    BX_MOUNTS="/only:/only" BX_NET=host \
    BX_COMMAND=true BX_STATE_DIR="$d/local" \
    PATH="${_fake_podman_dir}:/usr/bin:/bin" "$_bx" ctr 2>&1)"
  assert_contains "different shape" "$out" "a net change is a conflict"
  assert_contains "--reset" "$out" "names the fix"
  rm -rf "$d"
}

# A container on the runtime bridge cannot reach the network inside a vm with
# user-mode (TSI) networking. When the recipe *asks* for a bridge there, bx
# refuses and names the fix, rather than creating a container whose DNS fails.
test_net_bridge_under_tsi_is_refused() {
  _current="net = bridge is refused, with the fix, under TSI"
  local d out calls
  : >"$_fake_podman_log"
  d="$(_new_workdir)"
  cat >"$d/.bx.conf" <<'CONF'
[ctr]
backend = podman
image   = debian:bookworm-slim
net     = bridge
mounts  = /only:/only
command = true
CONF
  out="$(cd "$d" && BX_NESTED_NET=tsi BX_NAME=tsibr BX_STATE_DIR="$d/local" \
    PATH="${_fake_podman_dir}:/usr/bin:/bin" "$_bx" ctr 2>&1)"
  calls="$(cat "$_fake_podman_log" 2>/dev/null)"
  assert_contains "net = host" "$out" "names the recommended fix"
  assert_contains "net = none" "$out" "offers the no-network option"
  assert_not_contains "create --name" "$calls" "does not create a broken container"
  rm -rf "$d"
}

# When nothing was asked for, the mode that works is used, and bx says so.
# Unset means "whatever works", so this is a report, not a silent override.
test_net_unset_under_tsi_uses_host() {
  _current="net unset under TSI uses host and says so"
  local d out calls
  : >"$_fake_podman_log"
  d="$(_new_workdir)"
  cat >"$d/.bx.conf" <<'CONF'
[ctr]
backend = podman
image   = debian:bookworm-slim
mounts  = /only:/only
command = true
CONF
  out="$(cd "$d" && BX_VERBOSE=1 BX_NESTED_NET=tsi BX_NAME=tsiauto \
    BX_STATE_DIR="$d/local" PATH="${_fake_podman_dir}:/usr/bin:/bin" \
    "$_bx" ctr 2>&1)"
  calls="$(cat "$_fake_podman_log" 2>/dev/null)"
  assert_contains "--network=host" "$calls" "falls back to host networking"
  assert_contains "user-mode" "$out" "explains why"
  rm -rf "$d"
}

# Approval is explicit: BX_NET_APPROVED=1 turns an asked-for bridge into host
# for this run, without editing the recipe.
test_net_bridge_approved_becomes_host() {
  _current="BX_NET_APPROVED=1 approves host networking"
  local d calls
  : >"$_fake_podman_log"
  d="$(_new_workdir)"
  cat >"$d/.bx.conf" <<'CONF'
[ctr]
backend = podman
image   = debian:bookworm-slim
net     = bridge
mounts  = /only:/only
command = true
CONF
  (cd "$d" && BX_NESTED_NET=tsi BX_NET_APPROVED=1 BX_NAME=tsiappr \
    BX_STATE_DIR="$d/local" PATH="${_fake_podman_dir}:/usr/bin:/bin" \
    "$_bx" ctr >/dev/null 2>&1)
  calls="$(cat "$_fake_podman_log" 2>/dev/null)"
  assert_contains "--network=host" "$calls" "approval becomes host networking"
  rm -rf "$d"
}

# On an ordinary host the bridge is correct and must be left alone.
test_net_bridge_kept_on_a_normal_host() {
  _current="net = bridge is kept on a normal host"
  local d calls
  : >"$_fake_podman_log"
  d="$(_new_workdir)"
  cat >"$d/.bx.conf" <<'CONF'
[ctr]
backend = podman
image   = debian:bookworm-slim
net     = bridge
mounts  = /only:/only
command = true
CONF
  (cd "$d" && BX_NESTED_NET=normal BX_NAME=normbr BX_STATE_DIR="$d/local" \
    PATH="${_fake_podman_dir}:/usr/bin:/bin" "$_bx" ctr >/dev/null 2>&1)
  calls="$(cat "$_fake_podman_log" 2>/dev/null)"
  assert_not_contains "--network=host" "$calls" "does not force host on a host"
  assert_not_contains "--network=none" "$calls" "does not cut the network"
  rm -rf "$d"
}

# The same modes, on the vm backend. smolvm enables the vm's own network with
# `--net`; `none` omits it, and `host` (a vm's network is already host-like)
# also needs it. `bridge` is the vm's own NAT and is the same as `host` here.
test_net_modes_reach_the_vm() {
  _current="net modes reach smolvm as the right flag"
  local d calls
  d="$(_new_workdir)"
  : >"$_fake_log"
  (cd "$d" && BX_NESTED_NET=normal BX_NET=none BX_NAME=vmnone \
    BX_MOUNTS="/only:/only" BX_COMMAND=true BX_STATE_DIR="$d/local" \
    FAKE_VMS="" PATH="${_fake_bin_dir}:$PATH" "$_bx" >/dev/null 2>&1)
  calls="$(cat "$_fake_log" 2>/dev/null)"
  assert_not_contains "--net" "$calls" "none does not enable the vm network"
  rm -rf "$d"

  d="$(_new_workdir)"
  : >"$_fake_log"
  (cd "$d" && BX_NESTED_NET=normal BX_NET=host BX_NAME=vmhost \
    BX_MOUNTS="/only:/only" BX_COMMAND=true BX_STATE_DIR="$d/local" \
    FAKE_VMS="" PATH="${_fake_bin_dir}:$PATH" "$_bx" >/dev/null 2>&1)
  calls="$(cat "$_fake_log" 2>/dev/null)"
  assert_contains "--net" "$calls" "host enables the vm network"
  rm -rf "$d"
}

# `runtime_args` are the backend's own flags, passed through verbatim. The whole
# point is that bx does not translate them, so the test is that the exact text
# reaches the create argv and nothing rewrites it.
test_runtime_args_reach_the_create_argv() {
  _current="runtime_args reach the create argv verbatim"
  local d calls
  d="$(_new_workdir)"
  : >"$_fake_podman_log"
  cat >"$d/.bx.conf" <<'CONF'
[ctr]
backend      = podman
image        = debian:bookworm-slim
runtime_args = --privileged
runtime_args = --cgroupns=host
mounts       = /only:/only
command      = true
CONF
  (cd "$d" && FAKE_CONTAINERS="" BX_NAME=ra BX_STATE_DIR="$d/local" \
    PATH="${_fake_podman_dir}:$PATH" "$_bx" ctr >/dev/null 2>&1)
  calls="$(cat "$_fake_podman_log" 2>/dev/null)"
  assert_contains "--privileged" "$calls" "the first flag reaches create"
  assert_contains "--cgroupns=host" "$calls" "the second flag reaches create"
  rm -rf "$d"
}

# They are bound at create time, so changing them cannot apply to a running
# machine; a changed set must reconcile like any other shape change.
test_runtime_args_are_part_of_the_shape() {
  _current="changing runtime_args is a shape change"
  local d out
  d="$(_new_workdir)"
  cat >"$d/local/ra.state" <<'STATE'
image=debian:bookworm-slim
cpus=4
mem=4096
net=host
backend=podman
mounts:
/only:/only
runtime_args:
--privileged
STATE
  cat >"$d/.bx.conf" <<'CONF'
[ctr]
backend      = podman
image        = debian:bookworm-slim
net          = host
runtime_args = --privileged
runtime_args = --cap-add=SYS_ADMIN
mounts       = /only:/only
command      = true
CONF
  out="$(cd "$d" && FAKE_CONTAINERS=ra BX_NAME=ra BX_STATE_DIR="$d/local" \
    PATH="${_fake_podman_dir}:$PATH" "$_bx" ctr 2>&1)"
  assert_contains "different shape" "$out" "added runtime_args is a conflict"
  rm -rf "$d"
}

# The plan has to show what the fence was opened with, or --dry-run is not a
# plan. The warning is the create-time half of the same promise.
test_runtime_args_are_reported() {
  _current="runtime_args appear in the plan, and warn when they widen"
  local d out
  d="$(_new_workdir)"
  cat >"$d/.bx.conf" <<'CONF'
[ctr]
backend      = podman
image        = debian:bookworm-slim
runtime_args = --privileged
mounts       = /only:/only
command      = true
CONF
  out="$(cd "$d" && BX_NAME=ra2 BX_STATE_DIR="$d/state" BX_DRY_RUN=1 \
    PATH="${_fake_podman_dir}:$PATH" "$_bx" ctr 2>&1)"
  assert_contains "runtime_args:" "$out" "the plan names the raw flags"
  assert_contains "--privileged" "$out" "the plan shows the flag itself"
  out="$(cd "$d" && FAKE_CONTAINERS="" BX_VERBOSE=1 BX_NAME=ra3 \
    BX_STATE_DIR="$d/local" PATH="${_fake_podman_dir}:$PATH" "$_bx" ctr 2>&1)"
  assert_contains "raw runtime flags" "$out" "create warns that raw flags were passed"
  rm -rf "$d"
}

# With no runtime_args, none of the widening machinery should appear: the flag
# is explicit-only, and bx must never invent one.
test_no_runtime_args_is_the_default() {
  _current="runtime_args are never inferred"
  local d out calls
  d="$(_new_workdir)"
  : >"$_fake_podman_log"
  cat >"$d/.bx.conf" <<'CONF'
[ctr]
backend = podman
image   = debian:bookworm-slim
mounts  = /only:/only
command = true
CONF
  out="$(cd "$d" && BX_NAME=ra4 BX_STATE_DIR="$d/state" BX_DRY_RUN=1 \
    PATH="${_fake_podman_dir}:$PATH" "$_bx" ctr 2>&1)"
  assert_not_contains "runtime_args" "$out" "the plan omits it when unset"
  (cd "$d" && FAKE_CONTAINERS="" BX_NAME=ra5 BX_STATE_DIR="$d/local" \
    PATH="${_fake_podman_dir}:$PATH" "$_bx" ctr >/dev/null 2>&1)
  calls="$(cat "$_fake_podman_log" 2>/dev/null)"
  assert_not_contains "--privileged" "$calls" "no privileged flag is invented"
  rm -rf "$d"
}

test_net_modes_reach_the_container
test_net_boolean_still_means_a_mode
test_net_bogus_mode_is_rejected
test_net_mode_is_part_of_the_shape
test_net_bridge_under_tsi_is_refused
test_net_unset_under_tsi_uses_host
test_net_bridge_approved_becomes_host
test_net_bridge_kept_on_a_normal_host
test_net_modes_reach_the_vm
test_runtime_args_reach_the_create_argv
test_runtime_args_are_part_of_the_shape
test_runtime_args_are_reported
test_no_runtime_args_is_the_default



# The engine is only unified if every backend implements the same verbs. A new
# backend that forgets one would fail at the call site, deep in a run; catch it
# here, where the fix is obvious. The parity tests go further: presence is not
# a contract, so the same observable behaviour is asserted on both backends.
test_backends_implement_the_same_verbs
test_exec_runs_in_the_directorys_machine
test_exec_does_not_own_the_lifecycle
test_exec_works_while_the_lifecycle_lock_is_held
test_exec_refuses_a_missing_machine
test_exec_refuses_a_stopped_machine
test_exec_refuses_an_ambiguous_directory
test_exec_needs_a_command
test_exit_status_parity
test_lock_parity
test_shape_reconcile_parity
test_cleanup_parity
test_bx_in_bx_composes
test_bx_in_bx_locks_are_per_level

printf '\n%d passed, %d failed\n' "$_passed" "$_failed"
[[ "$_failed" -eq 0 ]]
