#!/usr/bin/env bash
# scripts/lib.sh — shared helpers sourced by bx's host-side tooling.
#
# This exists so that the "can this host boot a smolvm machine?" predicate is
# defined exactly once and can be exercised by the test suite. It used to be a
# bare `[[ -e /dev/kvm ]]` check copied into bench.sh, demo.sh, and
# invariants.sh, which wrongly excluded macOS — a first-class host.
#
# Source it, do not run it:
#   . "$(dirname "$0")/lib.sh"

# A host can boot a smolvm machine when smolvm is on PATH and the platform has
# hardware virtualization: macOS exposes it through Hypervisor.framework (there
# is no /dev/kvm), Linux exposes it through /dev/kvm. Any other platform fails.
#
# Two environment hooks make this testable without the hardware:
#   BX_HOST_OS    overrides `uname -s` (e.g. "Darwin")
#   BX_HAVE_KVM   overrides the /dev/kvm existence check ("0" or "1")
_smolvm_can_boot() {
  command -v smolvm >/dev/null 2>&1 || return 1
  local _os="${BX_HOST_OS:-$(uname -s)}"
  [[ "$_os" == Darwin ]] && return 0
  if [[ -n "${BX_HAVE_KVM:-}" ]]; then
    [[ "$BX_HAVE_KVM" == 1 ]]
  else
    [[ -e /dev/kvm ]]
  fi
}
