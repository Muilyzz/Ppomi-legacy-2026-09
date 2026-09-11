#!/bin/sh
# Finder double-click → same as scripts/open-mac-shell.sh
# ponytail: wrapper only; logic lives in the .sh
cd "$(dirname "$0")/.." || exit 1
exec sh scripts/open-mac-shell.sh "$@"
