#!/bin/sh
# Everything CI and a contributor should run before trusting a change.
set -eu
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck bin/bx bin/bx-pi install.sh tests/bx_test.sh
else
  echo "check: shellcheck not found; skipping lint" >&2
fi
sh tests/bx_test.sh
