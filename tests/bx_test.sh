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
net=1
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
net=1
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

_install_fake_smolvm
trap '_remove_fake_smolvm' EXIT

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
test_cpu_change_conflicts
test_unknown_option_is_rejected
test_invalid_machine_name_is_rejected
test_recipe_lookup_and_merge
test_recipe_mounts_accumulate
test_recipe_variable_expansion
test_recipe_unknown_key_is_rejected
test_recipe_unknown_name_is_rejected
test_recipe_list
test_recipe_book_is_not_compiled_in
test_recipe_extends_inherits_scalars_and_lists
test_recipe_resolver_emits_values
test_recipe_resolver_secrets_stay_out_of_show
test_recipe_resolver_missing_is_reported
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

printf '\n%d passed, %d failed\n' "$_passed" "$_failed"
[[ "$_failed" -eq 0 ]]
