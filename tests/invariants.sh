#!/usr/bin/env bash
# Invariant harness for bx.
#
# The README and recipes/README make claims in prose: "secrets never appear in
# argv", "the host home directory is not mounted", "a recipe is data, not
# shell". Prose drifts; assertions do not. This harness turns each claim into a
# test and fails if the claim and the code disagree.
#
# Rule: any sentence in the docs that says "never" or "only" must have an
# assertion here. If it does not, the sentence is wrong or the harness is
# incomplete — both are failures.
#
# Two suites:
#   host   — no smolvm, no VM, no network. Always runs. Greps every byte bx
#            writes for sentinel values, and lints the docs' claims.
#   real   — needs smolvm and a host that can boot a VM (macOS, or Linux with
#            /dev/kvm). Opt in with BX_REAL=1. Boots a real
#            machine and asserts the isolation the demo shows by hand.
#
# Run: tests/invariants.sh          # host suite
#      BX_REAL=1 tests/invariants.sh  # host + real isolation suite

set -uo pipefail

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_repo_root="$(cd "${_here}/.." && pwd)"
_bx="${_repo_root}/bin/bx"

_passed=0
_failed=0
_current=""

_pass() { _passed=$((_passed + 1)); }
_fail() { printf 'not ok - %s: %s\n' "$_current" "$*" >&2; _failed=$((_failed + 1)); }

assert_absent() { # needle haystack what
  if [[ "$2" != *"$1"* ]]; then _pass; else _fail "$3: found '$1'"; fi
}
assert_present() { # needle haystack what
  if [[ "$2" == *"$1"* ]]; then _pass; else _fail "$3: missing '$1'"; fi
}

# A unique, unlikely-to-collide sentinel. If it appears anywhere bx or smolvm
# wrote, a secret leaked.
_sentinel="BXSECRET_$(date +%s)_$RANDOM$RANDOM"

_tmp=""
_new_tmp() { _tmp="$(mktemp -d)"; printf '%s' "$_tmp"; }

# ── host: secrets leave no trace in bx's own artifacts ──────────────────────
test_secret_absent_from_state_and_show() {
  _current="a secret never appears in bx state or --show output"
  local d out
  d="$(_new_tmp)"
  cat >"$d/.bx.conf" <<CONF
[sec]
image    = debian:bookworm-slim
mounts   = \$PWD:/work
secret_env = API_KEY=THE_SECRET_VAR:ephemeral
command  = true
CONF
  # --show must not print the value (only the names), and must not fail.
  out="$(cd "$d" && THE_SECRET_VAR="$_sentinel" \
    BX_STATE_DIR="$d/state" "$_bx" --show sec 2>&1)"
  assert_absent "$_sentinel" "$out" "--show leaked the secret"
  # Anything bx wrote under the state dir must not contain it either.
  local _hit=""
  if [[ -d "$d/state" ]]; then
    _hit="$(grep -rIl "$_sentinel" "$d/state" 2>/dev/null || true)"
  fi
  assert_absent "$_sentinel" "$_hit" "state dir leaked the secret"
  rm -rf "$d"
}

# Grips the entire test's tmpdir for the sentinel after a fake run. The fake
# smolvm records the argv it was given; the secret must not be in it. The value
# is passed as an env var and must cross by name.
test_secret_absent_from_argv() {
  _current="a secret is passed by name, never in smolvm argv"
  local d log out
  d="$(_new_tmp)"
  log="$d/calls.log"
  mkdir -p "$d/bin"
  cat >"$d/bin/smolvm" <<FAKE
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$(printf '%q' "$log")"
case "\$1 \$2" in
  "machine ls") ;;
  "machine exec") exit 0 ;;
esac
exit 0
FAKE
  chmod +x "$d/bin/smolvm"
  cat >"$d/.bx.conf" <<CONF
[sec]
image    = debian:bookworm-slim
mounts   = \$PWD:/work
secret_env = API_KEY=THE_SECRET_VAR:ephemeral
command  = true
CONF
  out="$(cd "$d" && THE_SECRET_VAR="$_sentinel" BX_NAME=secinv \
    BX_BACKEND=smolvm BX_STATE_DIR="$d/state" PATH="$d/bin:$PATH" "$_bx" sec 2>&1)"
  # The recorded argv (calls.log) must name THE_SECRET_VAR, never its value.
  assert_present "THE_SECRET_VAR" "$(cat "$log" 2>/dev/null)" "the secret was not passed by name"
  assert_absent "$_sentinel" "$(cat "$log" 2>/dev/null)" "argv leaked the secret"
  assert_absent "$_sentinel" "$out" "output leaked the secret"
  rm -rf "$d"
}

# ── host: a recipe is data, never shell ─────────────────────────────────────
test_recipe_is_never_shell() {
  _current="a recipe value is never shell-evaluated"
  local d out canary
  d="$(_new_tmp)"
  canary="$d/canary"
  cat >"$d/.bx.conf" <<CONF
[evil]
command = \$(touch $canary)
mounts  = \$PWD:/work
CONF
  out="$(cd "$d" && BX_STATE_DIR="$d/state" "$_bx" --show evil 2>&1)"
  if [[ -e "$canary" ]]; then _fail "a recipe value was evaluated as shell"; else _pass; fi
  assert_present 'touch' "$out" "the command substitution was not preserved literally"
  rm -rf "$d"
}

# ── host: a run piped is silent on stderr ───────────────────────────────────
# The whole point of the fidelity work: `bx pi | grep x` must not be polluted
# by bx's own narration about the machine. Run narration is suppressed when
# stderr is not a terminal and the user did not ask for verbosity.
test_piped_run_is_silent() {
  _current="a piped run adds no narration to stderr"
  local d err
  d="$(_new_tmp)"
  mkdir -p "$d/bin"
  cat >"$d/bin/smolvm" <<'FAKE'
#!/usr/bin/env bash
case "$1 $2" in
  "machine ls") ;;
  "machine exec") printf 'guest output\n'; exit 0 ;;
  "machine start"|"machine stop"|"machine create"|"machine delete") exit 0 ;;
esac
exit 0
FAKE
  chmod +x "$d/bin/smolvm"
  cat >"$d/.bx.conf" <<'CONF'
[quiet]
image   = debian:bookworm-slim
mounts  = /tmp:/work
command = true
CONF
  # A fresh machine name: the run will create it, which is the noisy path.
  err="$(cd "$d" && BX_NAME=quietinv BX_BACKEND=smolvm BX_STATE_DIR="$d/state" \
    PATH="$d/bin:$PATH" "$_bx" quiet 2>&1 >/dev/null)"
  assert_absent "creating" "$err" "piped run leaked create narration"
  assert_absent "bx:" "$err" "piped run leaked a bx-prefixed line"
  rm -rf "$d"
}

# ── host: env passthrough forwards only the allowlist ───────────────────────
# Fidelity must not become a leak: TERM/LANG cross, credentials do not.
test_env_passthrough_is_curated() {
  _current="env passthrough forwards the allowlist and nothing secret"
  local d log
  d="$(_new_tmp)"
  log="$d/calls.log"
  mkdir -p "$d/bin"
  cat >"$d/bin/smolvm" <<FAKE
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$(printf '%q' "$log")"
case "\$1 \$2" in
  "machine ls") ;;
  "machine exec") exit 0 ;;
  *) exit 0 ;;
esac
FAKE
  chmod +x "$d/bin/smolvm"
  cat >"$d/.bx.conf" <<'CONF'
[env]
image   = debian:bookworm-slim
mounts  = /tmp:/work
command = true
CONF
  (cd "$d" && TERM=xterm-color LANG=en_US.UTF-8 TZ=UTC \
     AWS_SECRET_ACCESS_KEY="$_sentinel" EDITOR=vim \
     BX_NAME=envinv BX_BACKEND=smolvm BX_STATE_DIR="$d/state" PATH="$d/bin:$PATH" \
     "$_bx" env >/dev/null 2>&1)
  local calls
  calls="$(cat "$log" 2>/dev/null)"
  assert_present 'TERM=xterm-color' "$calls" "TERM was not forwarded"
  assert_present 'LANG=en_US.UTF-8' "$calls" "LANG was not forwarded"
  assert_absent "$_sentinel" "$calls" "a credential was forwarded"
  assert_absent 'EDITOR=vim' "$calls" "a non-allowlisted var was forwarded"
  rm -rf "$d"
}

# ── host: docs and code agree ───────────────────────────────────────────────
# Every "never"/"only" claim in the docs must be listed here with the test that
# backs it. This list is the contract; adding a claim without adding an
# assertion fails.
test_claims_are_backed() {
  _current="every 'never'/'only' claim in the docs is backed by a test"
  local _missing=""
  local _readme="${_repo_root}/README.md"
  local _rreadme="${_repo_root}/recipes/README.md"
  # Map of doc phrase -> invariant test name that must exist in this file.
  # Keyed on a distinctive substring of the claim, so prose can move around it.
  # If a claim is added to the docs and not here, this test cannot know; the
  # reverse — a phrase here whose test vanished — is what it enforces.
  local _claims=(
    "Secrets stay out of argv:test_secret_absent_from_argv"
    "Values are data, not shell:test_recipe_is_never_shell"
    "passed by name:test_secret_absent_from_argv"
    "out of its own state files:test_secret_absent_from_state_and_show"
    "A piped run is silent:test_piped_run_is_silent"
    "A curated environment is forwarded:test_env_passthrough_is_curated"
  )
  local _c _phrase _fn
  for _c in "${_claims[@]}"; do
    _phrase="${_c%%:*}"
    _fn="${_c##*:}"
    # The claim must appear in one of the docs...
    if ! grep -qF "$_phrase" "$_readme" "$_rreadme" 2>/dev/null; then
      _missing="${_missing} claim-not-in-docs:'${_phrase}'"
      continue
    fi
    # ...and the named test must exist to back it.
    if ! grep -q "^${_fn}()" "${BASH_SOURCE[0]}"; then
      _missing="${_missing} claim-without-test:'${_phrase}' -> ${_fn}"
    fi
  done
  if [[ -n "$_missing" ]]; then _fail "$_missing"; else _pass; fi
}

# ── host: the cost model is honest ──────────────────────────────────────────
# --dry-run must not touch smolvm, so a plan is inspectable on any host.
test_dry_run_needs_no_smolvm() {
  _current="--dry-run works with no smolvm on PATH"
  local d out rc
  d="$(_new_tmp)"
  out="$(cd "$d" && BX_DRY_RUN=1 BX_NAME=probe BX_COMMAND="true" \
    BX_STATE_DIR="$d/state" PATH="/usr/bin:/bin" \
    "$_bx" 2>&1)"
  rc=$?
  if [[ "$rc" == "0" ]]; then _pass; else _fail "exited $rc: $out"; fi
  assert_present "estimate=" "$out" "the plan did not include a cost estimate"
  rm -rf "$d"
}

# ── host capability probe ─────────────────────────────────────────────────
# The harness gates on "can this host boot a VM", which is smolvm present and
# either macOS or a Linux /dev/kvm. A bare /dev/kvm check skips the Mac, which
# is a first-class host. This sources the *shipping* predicate from
# scripts/lib.sh and exercises it through its override hooks, so the test
# cannot drift from the code bench.sh and demo.sh actually use.
test_boot_probe_accepts_macos() {
  _current="the shipping boot probe accepts macOS without /dev/kvm"
  . "${_repo_root}/scripts/lib.sh"
  # Fake smolvm on PATH so the command -v check passes.
  local _fake_dir
  _fake_dir="$(mktemp -d)"
  printf '#!/bin/sh\nexit 0\n' >"${_fake_dir}/smolvm"
  chmod +x "${_fake_dir}/smolvm"
  local _orig_path="$PATH"
  PATH="${_fake_dir}:$PATH"

  if ! BX_HOST_OS=Darwin BX_HAVE_KVM=0 _smolvm_can_boot; then
    _fail "Darwin with smolvm and no /dev/kvm must be bootable"
  else
    _pass
  fi
  if ! BX_HOST_OS=Linux BX_HAVE_KVM=1 _smolvm_can_boot; then
    _fail "Linux with smolvm and /dev/kvm must be bootable"
  else
    _pass
  fi
  if BX_HOST_OS=Linux BX_HAVE_KVM=0 _smolvm_can_boot; then
    _fail "Linux without /dev/kvm must NOT be bootable"
  else
    _pass
  fi

  # With no smolvm on PATH, no host is bootable.
  # shellcheck disable=SC2123  # overriding PATH is the point here
  PATH="/nonexistent-bx-"
  if BX_HOST_OS=Darwin _smolvm_can_boot; then
    _fail "Darwin without smolvm must NOT be bootable"
  else
    _pass
  fi

  PATH="$_orig_path"
  rm -rf "$_fake_dir"
}

# ── containers in the guest are documented, with their caveat ────────────────
# The README claims you can run containers inside the guest, names the
# overlayfs storage caveat, and now documents `backend = podman` as the way bx
# manages a container machine from inside one. Those claims must not silently
# disappear.
test_containers_claim_is_documented() {
  _current="the containers-in-guest claim and its caveat are documented"
  local _readme="${_repo_root}/README.md"
  if ! grep -qF 'Containers inside the guest' "$_readme"; then
    _fail "README no longer documents containers inside the guest"
    return
  fi
  if ! grep -qF 'is not supported over overlayfs' "$_readme" && \
     ! grep -qF 'itself an overlayfs' "$_readme"; then
    _fail "README no longer explains the overlayfs storage-driver caveat"
    return
  fi
  if ! grep -qF 'backend = podman' "$_readme"; then
    _fail "README no longer documents the podman backend"
    return
  fi
  _pass
}

# The backend is a safety boundary, not a convenience knob: a machine built as
# a vm must not be reused as a container. That is code-level (the shape records
# it) and is pinned in bx_test.sh; this pins the *documentation* of it, so the
# reason cannot be edited away while the mechanism stays.
test_backend_choice_is_documented() {
  _current="the backend key and its never-silently-substituted rule are documented"
  local _rreadme="${_repo_root}/recipes/README.md" _readme="${_repo_root}/README.md"
  if ! grep -qF '| `backend` |' "$_rreadme"; then
    _fail "recipes/README.md no longer lists the backend key"
    return
  fi
  if ! grep -qiE 'is an error naming both choices|never a silent substitution' "$_readme"; then
    _fail "README no longer states that an unresolved backend choice is an error, not a silent pick"
    return
  fi
  _pass
}

# `net` is a capability the user approves, not a knob bx turns silently. The
# documentation must keep saying that an explicit `bridge` under user-mode
# networking is refused with the fix, and that an unset `net` picks what works.
test_net_mode_choice_is_documented() {
  _current="the net modes and their approval rule are documented"
  local _readme="${_repo_root}/README.md"
  if ! grep -qF 'net = host' "$_readme"; then
    _fail "README no longer documents the host network mode"
    return
  fi
  if ! grep -qiE 'user-mode|TSI' "$_readme"; then
    _fail "README no longer explains why a bridge cannot work when nested"
    return
  fi
  if ! grep -qiF 'refuses at *create* time' "$_readme"; then
    _fail "README no longer says an impossible net choice is refused, not silently changed"
    return
  fi
  if ! grep -qiE 'did not ask for anything|Whatever works|uses the mode that works' "$_readme"; then
    _fail "README no longer says an unset net picks the mode that works"
    return
  fi
  _pass
}

# `runtime_args` is the one key that widens the fence, so the claim that bx
# never infers it is load-bearing. Pin it against the source and the docs: the
# key must be absent from every default, and the README must still say that a
# recipe has to ask for it.
test_runtime_args_are_never_inferred() {
  _current="runtime_args are documented, explicit-only, and warned about"
  local _readme="${_repo_root}/README.md" _bx="${_repo_root}/bin/bx"
  if ! grep -qF 'runtime_args' "$_readme"; then
    _fail "README no longer documents runtime_args"
    return
  fi
  # The only mentions of --privileged in bx itself must be prose, never a
  # default handed to a backend. If a future change adds one, this catches it.
  if grep -nE '^\s*_create_args\+=\(.*--privileged' "$_bx" >/dev/null 2>&1; then
    _fail "bx now injects --privileged itself; it must only pass recipe flags through"
    return
  fi
  if ! grep -qiE 'warn' "$_readme"; then
    _fail "README no longer says runtime_args are warned about at create time"
    return
  fi
  _pass
}

# The README now claims the backend contract is asserted on *both* backends and
# that the real fence runs on whichever can boot. Those are the guarantees that
# turn the engine from a dispatch table into an abstraction, so pin them: the
# parity tests must still iterate over both names, and the real runner must
# still probe rather than hardcode smolvm.
test_backend_contract_is_asserted_on_every_backend() {
  _current="the backend contract and the real fence cover every backend"
  local _t="${_repo_root}/tests/bx_test.sh" _i="${_repo_root}/tests/invariants.sh"
  # The parity scenarios must loop over the declared backends. If someone
  # narrows one to smolvm, the guarantee is gone and this says so.
  local _scenario
  for _scenario in test_exit_status_parity test_lock_parity \
                   test_shape_reconcile_parity test_cleanup_parity; do
    if ! sed -n "/^${_scenario}()/,/^}/p" "$_t" | grep -q 'for _b in smolvm podman'; then
      _fail "${_scenario} no longer runs on both backends"
      return
    fi
  done
  # The real runner must discover what can boot, not gate on the vm predicate.
  # Scoped to the runner block: `_smolvm_can_boot` still exists and is tested
  # elsewhere, so a whole-file grep would flag its own test.
  local _runner
  _runner="$(sed -n '/^if \[\[ "${BX_REAL:-0}" == "1" \]\]/,/^fi/p' "$_i")"
  if ! grep -q '_real_backend_runnable' <<<"$_runner"; then
    _fail "the real suite no longer probes which backend can boot"
    return
  fi
  if grep -q '_smolvm_can_boot' <<<"$_runner"; then
    _fail "the real runner still gates on the smolvm predicate alone"
    return
  fi
  _pass
}

# A shipped regression: a failing `pre_command` aborted bx with its raw status
# and printed nothing, so `bx pi` failed as a silent `exit 1`. The rule is that
# bx's own setup steps name themselves; only the guest command's status passes
# through verbatim. Pin the source shape, since the behavior is covered in
# bx_test.sh and this keeps a future edit from removing the guard.
test_setup_failures_are_never_silent() {
  _current="a failed setup step is reported, and the exit contract is stated"
  local _bx="${_repo_root}/bin/bx" _readme="${_repo_root}/README.md"
  if ! grep -qF 'pre_command failed' "$_bx"; then
    _fail "bx no longer reports a failed pre_command"
    return
  fi
  if ! grep -qF 'bootstrap failed' "$_bx"; then
    _fail "bx no longer reports a failed bootstrap"
    return
  fi
  # The invocation must sit inside a `set +e` / status-check guard, not run
  # bare where `set -e` would abort on it silently. Check the region around the
  # call for the guard rather than the line itself, which is legitimately just
  # `bash -c "$BX_PRE_COMMAND"`.
  local _region
  _region="$(sed -n '/if \[\[ -n "${BX_PRE_COMMAND:-}" \]\]/,/^fi$/p' "$_bx")"
  if ! grep -q 'set +e' <<<"$_region"; then
    _fail "pre_command no longer runs under set +e; a failure would exit silently"
    return
  fi
  if ! grep -q '_pre_status' <<<"$_region"; then
    _fail "pre_command's status is no longer captured and checked"
    return
  fi
  if ! grep -qF "otherwise bx names the step that failed" "$_readme"; then
    _fail "README no longer states the exit-status contract for setup failures"
    return
  fi
  _pass
}

# ── real: isolation, on whichever backend can actually run ──────────────────
# The fence is bx's reason to exist, so it must be asserted on every backend
# that can boot, not only the vm. These take the backend as an argument: the
# runner below picks one that works on this host, so a Linux box with podman
# exercises the container fence and a Mac exercises the vm fence. A claim that
# only holds on smolvm is not a property of bx.
#
# `cat` of a host file that exists is the test: if the guest prints the
# sentinel, the file crossed the boundary. `|| true` keeps a refusal from
# looking like a runner failure.
#
# Names carry the pid and BX_RESET=1, so a re-run never collides with a machine
# a previous run left behind (the state dir is fresh, but the machine is not
# always deleted) — that collision once looked exactly like a fence failure.
_real_name() { printf 'bxinv-%s-%s-%s' "$1" "$2" "$$"; }

# Remove a machine this suite created, so a re-run starts clean. bx stops a
# machine but does not delete it, and a leftover name with no recorded shape is
# exactly the collision that once masqueraded as a fence failure. Deleting
# through the backend directly is deliberate: `bx --reset` needs a state file
# to reconcile against, and this cleanup is removing the thing state would
# describe.
_real_cleanup() { # backend name
  case "$1" in
    smolvm) smolvm machine delete --name "$2" -f >/dev/null 2>&1 || true ;;
    podman) podman rm -f "$2" >/dev/null 2>&1 || true ;;
  esac
}

test_real_home_is_not_mounted() { # backend
  local _b="$1" d out _name _needle
  _current="[$_b] the host home directory is not visible in the machine"
  d="$(_new_tmp)"
  _name="$(_real_name "$_b" home)"
  # The needle is a value that appears only in the file's *contents*, never in
  # the path we ask for: echoing `${HOME}/...-sentinel` in a `cat:` error would
  # otherwise match the needle and look exactly like a leak.
  _needle="LEAKED_$(date +%s)_$RANDOM"
  printf '%s\n' "$_needle" >"${HOME}/.bx-invariants-home"
  out="$(cd "$d" && BX_NAME="$_name" BX_BACKEND="$_b" \
    BX_RESET=1 BX_MOUNTS="$d:/work" BX_WORKDIR=/work \
    BX_COMMAND="cat \$HOME/.bx-invariants-home 2>&1 || true" \
    BX_STATE_DIR="$d/state" BX_KEEP=0 "$_bx" 2>&1)"
  assert_absent "$_needle" "$out" "[$_b] the machine read a host home-directory file"
  rm -f "${HOME}/.bx-invariants-home"
  _real_cleanup "$_b" "$_name"
  rm -rf "$d"
}

# The project mount must work — the fence must not be so tight the agent can't
# edit. Paired with the test above, this is the whole isolation story.
test_real_project_is_mounted() { # backend
  local _b="$1" d out _name
  _current="[$_b] the project directory is writable inside the machine"
  d="$(_new_tmp)"
  _name="$(_real_name "$_b" proj)"
  out="$(cd "$d" && BX_NAME="$_name" BX_BACKEND="$_b" \
    BX_RESET=1 BX_MOUNTS="$d:/work" BX_WORKDIR=/work \
    BX_COMMAND="echo from-guest > /work/invariants-probe && cat /work/invariants-probe" \
    BX_STATE_DIR="$d/state" "$_bx" 2>&1)"
  assert_present "from-guest" "$out" "[$_b] the machine could not write the mount"
  # The write must land on the host's copy of the mount, or the mount is a lie.
  if [[ "$(cat "$d/invariants-probe" 2>/dev/null)" == "from-guest" ]]; then
    _pass
  else
    _fail "[$_b] the guest write did not reach the host mount"
  fi
  _real_cleanup "$_b" "$_name"
  rm -rf "$d"
}

# A mount the recipe does *not* name must not appear, whatever the backend.
# This is the negative form of the project-mount test, and the property that
# keeps nesting from widening by accident: the child sees its own mounts only.
test_real_undeclared_path_is_absent() { # backend
  local _b="$1" d out sibling _name _needle
  _current="[$_b] a path that is not mounted is not visible"
  d="$(_new_tmp)"
  _name="$(_real_name "$_b" unmnt)"
  sibling="$(mktemp -d)"
  _needle="LEAKED_$(date +%s)_$RANDOM"
  printf '%s\n' "$_needle" >"$sibling/secret"
  out="$(cd "$d" && BX_NAME="$_name" BX_BACKEND="$_b" \
    BX_RESET=1 BX_MOUNTS="$d:/work" BX_WORKDIR=/work \
    BX_COMMAND="cat $sibling/secret 2>&1 || true" \
    BX_STATE_DIR="$d/state" BX_KEEP=0 "$_bx" 2>&1)"
  assert_absent "$_needle" "$out" "[$_b] a sibling directory leaked into the machine"
  _real_cleanup "$_b" "$_name"
  rm -rf "$d" "$sibling"
}

# Which backends can actually boot here. smolvm needs a hypervisor; podman
# needs a working container runtime (and, when nested, the guest it runs in).
_real_backend_runnable() { # backend -> 0 if it can boot on this host
  local _b="$1" d _name
  d="$(_new_tmp)"
  _name="$(_real_name "$_b" probe)"
  if ( cd "$d" && BX_NAME="$_name" BX_BACKEND="$_b" \
       BX_COMMAND=true BX_RESET=1 BX_MOUNTS="$d:/work" BX_WORKDIR=/work \
       BX_STATE_DIR="$d/state" "$_bx" >/dev/null 2>&1 ); then
    _real_cleanup "$_b" "$_name"
    rm -rf "$d"; return 0
  fi
  rm -rf "$d"; return 1
}

# ── runner ──────────────────────────────────────────────────────────────────
_install_fake() { :; }
_remove_fake() { :; }

test_secret_absent_from_state_and_show
test_secret_absent_from_argv
test_recipe_is_never_shell
test_piped_run_is_silent
test_env_passthrough_is_curated
test_claims_are_backed
test_dry_run_needs_no_smolvm
test_boot_probe_accepts_macos
test_containers_claim_is_documented
test_backend_choice_is_documented
test_net_mode_choice_is_documented
test_runtime_args_are_never_inferred
test_backend_contract_is_asserted_on_every_backend
test_setup_failures_are_never_silent

if [[ "${BX_REAL:-0}" == "1" ]]; then
  # Run the fence on every backend that can actually boot here, not just the
  # one the smolvm predicate happens to know about. A host that can run podman
  # but not a vm (a CI container, or bx nested in bx) now exercises the fence
  # instead of skipping the whole suite.
  _ran_real=0
  for _candidate in smolvm podman; do
    if _real_backend_runnable "$_candidate"; then
      printf 'bx-invariants: real suite on %s\n' "$_candidate" >&2
      test_real_home_is_not_mounted "$_candidate"
      test_real_project_is_mounted "$_candidate"
      test_real_undeclared_path_is_absent "$_candidate"
      _ran_real=1
    fi
  done
  if [[ "$_ran_real" == "0" ]]; then
    printf 'bx-invariants: BX_REAL=1 but no backend can boot here; skipping real suite\n' >&2
  fi
fi

printf '%s passed, %s failed\n' "$_passed" "$_failed"
[[ "$_failed" == 0 ]]
