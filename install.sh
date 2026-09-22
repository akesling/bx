#!/usr/bin/env bash
# Install bx and its recipe book into a prefix.
#
#   ./install.sh                 # install to ~/.local
#   PREFIX=/usr/local ./install.sh
#   ./install.sh --uninstall     # remove what a previous install wrote
#   DESTDIR=/tmp/pkg ./install.sh  # stage into a package root
#
# bx is a single Bash script plus a recipe book it reads at run time. The book
# is installed under share/bx/recipes, where bx finds it relative to itself.
# A copy rather than a symlink: a symlink into a checkout breaks when the
# checkout moves or is deleted, and this tool is meant to outlive any one
# project.

set -euo pipefail

_src_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PREFIX="${PREFIX:-$HOME/.local}"
DESTDIR="${DESTDIR:-}"
_uninstall=0
_bindir_rel="bin"

_die() { printf 'install: %s\n' "$*" >&2; exit 1; }
_note() { printf 'install: %s\n' "$*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --uninstall) _uninstall=1; shift ;;
    --prefix=*)  PREFIX="${1#*=}"; shift ;;
    --bindir=*)  _bindir_rel="${1#*=}"; shift ;;
    --help|-h)
      sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) _die "unknown option: $1 (see --help)" ;;
  esac
done

_bindir="${DESTDIR}${PREFIX}/${_bindir_rel}"
_bookdir="${DESTDIR}${PREFIX}/share/bx/recipes"
_machinedir="${DESTDIR}${PREFIX}/share/bx/machines"
_manifest="${DESTDIR}${PREFIX}/share/bx/installed-files"
_files=(bx)
_book_files=(README.md bash.conf pi.conf pi.resolve sandbox.conf)
_machine_files=(default.conf pi_agent.conf)

_do_uninstall() {
  local removed=0 f
  if [[ -f "$_manifest" ]]; then
    while IFS= read -r f; do
      [[ -n "$f" ]] || continue
      if [[ -f "$f" ]]; then rm -f "$f"; removed=$((removed + 1)); fi
    done <"$_manifest"
    rm -f "$_manifest"
    rmdir "$(dirname "$_manifest")" 2>/dev/null || true
  else
    for f in "${_files[@]}"; do
      if [[ -f "${_bindir}/${f}" ]]; then rm -f "${_bindir}/${f}"; removed=$((removed + 1)); fi
    done
  fi
  rm -rf "$_bookdir" "$_machinedir" 2>/dev/null || true
  _note "removed $removed file(s) from ${_bindir}, ${_bookdir}, and ${_machinedir}"
}

if [[ "$_uninstall" == "1" ]]; then
  _do_uninstall
  exit 0
fi

for f in "${_files[@]}"; do
  [[ -f "${_src_dir}/bin/${f}" ]] || _die "missing ${_src_dir}/bin/${f}"
done
for f in "${_book_files[@]}"; do
  [[ -f "${_src_dir}/recipes/${f}" ]] || _die "missing ${_src_dir}/recipes/${f}"
done
for f in "${_machine_files[@]}"; do
  [[ -f "${_src_dir}/machines/${f}" ]] || _die "missing ${_src_dir}/machines/${f}"
done

command -v smolvm >/dev/null 2>&1 || \
  _note "warning: smolvm is not on PATH; bx will not run until it is installed"

mkdir -p "$_bindir"
for f in "${_files[@]}"; do
  install -m 0755 "${_src_dir}/bin/${f}" "${_bindir}/${f}"
done

# The recipe book. pi.resolve must stay executable; the rest are data.
mkdir -p "$_bookdir" "$_machinedir"
for f in "${_book_files[@]}"; do
  install -m 0644 "${_src_dir}/recipes/${f}" "${_bookdir}/${f}"
done
for f in "${_machine_files[@]}"; do
  install -m 0644 "${_src_dir}/machines/${f}" "${_machinedir}/${f}"
done
chmod 0755 "${_bookdir}/pi.resolve"

# Record exactly what was written so --uninstall is precise and does not touch
# unrelated files that happen to share a name.
mkdir -p "$(dirname "$_manifest")"
: >"$_manifest"
for f in "${_files[@]}"; do
  printf '%s\n' "${_bindir}/${f}" >>"$_manifest"
done
for f in "${_book_files[@]}"; do
  printf '%s\n' "${_bookdir}/${f}" >>"$_manifest"
done
for f in "${_machine_files[@]}"; do
  printf '%s\n' "${_machinedir}/${f}" >>"$_manifest"
done

_note "installed ${_files[*]} into ${_bindir}"
_note "installed recipe book into ${_bookdir}"
_note "installed machine book into ${_machinedir}"

# Tell the user whether the destination is actually on PATH, rather than
# assuming it is.
case ":${PATH}:" in
  *":${_bindir}:"*) ;;
  *) _note "note: ${_bindir} is not on PATH; add it, for example:"
     _note "  export PATH=\"${_bindir}:\$PATH\"" ;;
esac
