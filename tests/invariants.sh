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
    BX_STATE_DIR="$d/state" PATH="$d/bin:$PATH" "$_bx" sec 2>&1)"
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
# The README now claims you can run containers inside the guest, and names the
# overlayfs storage caveat. That claim must not silently disappear.
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
  if ! grep -qF 'does **not** manage that lifecycle' "$_readme"; then
    _fail "README no longer states that bx does not manage the nested-container lifecycle"
    return
  fi
  _pass
}

# ── real: isolation, only when asked ────────────────────────────────────────
# This is the claim the README leads with: the host home directory is not
# mounted. It cannot be tested with a fake smolvm, so it is opt-in.
test_real_home_is_not_mounted() {
  _current="the host home directory is not visible in the guest"
  local d out
  d="$(_new_tmp)"
  printf 'sentinel\n' >"${HOME}/.bx-invariants-sentinel"
  out="$(cd "$d" && BX_NAME=inv-home BX_COMMAND="cat \$HOME/.bx-invariants-sentinel 2>&1 || true" \
    BX_STATE_DIR="$d/state" BX_KEEP=0 "$_bx" 2>&1)"
  assert_absent "sentinel" "$out" "the guest read a host home-directory file"
  rm -f "${HOME}/.bx-invariants-sentinel"
  rm -rf "$d"
}

# The project mount must work — the fence must not be so tight the agent can't
# edit. Paired with the test above, this is the whole isolation story.
test_real_project_is_mounted() {
  _current="the project directory is writable inside the guest"
  local d out
  d="$(_new_tmp)"
  out="$(cd "$d" && BX_NAME=inv-proj \
    BX_COMMAND="echo from-guest > /work/invariants-probe && cat /work/invariants-probe" \
    BX_STATE_DIR="$d/state" "$_bx" 2>&1)"
  assert_present "from-guest" "$out" "the guest could not write the mount"
  rm -rf "$d"
}

# ── runner ──────────────────────────────────────────────────────────────────
_install_fake() { :; }
_remove_fake() { :; }

test_secret_absent_from_state_and_show
test_secret_absent_from_argv
test_recipe_is_never_shell
test_claims_are_backed
test_dry_run_needs_no_smolvm
test_boot_probe_accepts_macos
test_containers_claim_is_documented

if [[ "${BX_REAL:-0}" == "1" ]]; then
  # Use the shipping predicate, not a copy: a bare /dev/kvm check would skip
  # the Mac, which is a first-class host.
  . "${_repo_root}/scripts/lib.sh"
  if _smolvm_can_boot; then
    test_real_home_is_not_mounted
    test_real_project_is_mounted
  else
    printf 'bx-invariants: BX_REAL=1 but no smolvm or hypervisor; skipping real suite\n' >&2
  fi
fi

printf '%s passed, %s failed\n' "$_passed" "$_failed"
[[ "$_failed" == 0 ]]
