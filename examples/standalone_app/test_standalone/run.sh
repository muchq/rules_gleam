#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ ! -d "$SCRIPT_DIR/lib" ]; then
  echo "ERROR: This script must be run from the extracted archive directory" >&2
  echo "       Expected lib/ directory in $SCRIPT_DIR" >&2
  exit 1
fi

if command -v erl >/dev/null 2>&1; then
  ERL="erl"
else
  echo "ERROR: Erlang (erl) not found in PATH" >&2
  exit 1
fi

# Build -pa paths
PA_PATHS=""
for pkg_dir in "$SCRIPT_DIR"/lib/*/ebin; do
  if [ -d "$pkg_dir" ]; then
    PA_PATHS="$PA_PATHS -pa '$pkg_dir'"
  fi
done

eval exec "$ERL" \
  $PA_PATHS \
  -noshell \
  -s app main \
  -s init stop \
  -- "$@"
