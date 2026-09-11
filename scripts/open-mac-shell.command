#!/bin/sh
# Finder double-click: open 뽀미.app (Ppomi.app). Test in the main app, not packages/*/example.
cd "$(dirname "$0")/.." && exec ./scripts/open-mac-shell.sh
