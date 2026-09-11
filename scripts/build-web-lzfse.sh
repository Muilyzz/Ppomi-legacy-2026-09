#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
# Apple lzfse e634ca58b4821d9f3d560cdc6df5dec02ffc93fd, BSD-3-Clause.
# Sources vendored verbatim; only strict_decode.c is the local adapter.
# Built with Emscripten 6.0.9. Worker supplies inert memory/stdio callbacks only;
# there is no filesystem, network or generated JS glue.
emcc -O2 --no-entry -Iscripts/vendor/lzfse \
  scripts/vendor/lzfse/strict_decode.c \
  scripts/vendor/lzfse/lzfse_decode_base.c \
  scripts/vendor/lzfse/lzfse_fse.c \
  scripts/vendor/lzfse/lzvn_decode_base.c \
  -sSTANDALONE_WASM=1 -sALLOW_MEMORY_GROWTH=1 \
  -sINITIAL_MEMORY=16777216 -sMAXIMUM_MEMORY=402653184 \
  -sSTACK_SIZE=1048576 -sMALLOC=emmalloc -sFILESYSTEM=0 -sASSERTIONS=0 \
  -sEXPORTED_FUNCTIONS='["_malloc","_free","_ppomi_decode"]' \
  -o hub/web/vendor/lzfse.wasm
