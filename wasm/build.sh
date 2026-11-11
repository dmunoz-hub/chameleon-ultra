#!/usr/bin/env bash
# Build the Chameleon key-recovery solvers (nested / staticnested / darkside) to
# WebAssembly for the web app. Single-threaded (see src/pthread.h), so the output
# needs no SharedArrayBuffer and no special HTTP headers.
#
# Prereq: emscripten (emcc) on PATH. If you used emsdk:
#   source ~/emsdk/emsdk_env.sh
#
# Output: ../web/wasm/{nested,staticnested,darkside}.{js,wasm}
set -euo pipefail

cd "$(dirname "$0")"
SRC=src
OUT=../web/wasm
mkdir -p "$OUT"

if ! command -v emcc >/dev/null 2>&1; then
  echo "emcc not found. Run:  source ~/emsdk/emsdk_env.sh   (or install emscripten)"; exit 1
fi

COMMON="$SRC/common.c $SRC/crapto1.c $SRC/crypto1.c $SRC/bucketsort.c $SRC/parity.c"
FLAGS="-O3 -I$SRC -sMODULARIZE=1 -sALLOW_MEMORY_GROWTH=1 -sENVIRONMENT=web -sINVOKE_RUN=0 -sEXIT_RUNTIME=0 -sEXPORTED_RUNTIME_METHODS=callMain -sFILESYSTEM=0"

echo "Building nested…"
emcc $FLAGS -sEXPORT_NAME=NestedModule       $COMMON $SRC/nested_util.c $SRC/nested.c       -o "$OUT/nested.js"

echo "Building staticnested…"
emcc $FLAGS -sEXPORT_NAME=StaticNestedModule $COMMON $SRC/nested_util.c $SRC/staticnested.c -o "$OUT/staticnested.js"

echo "Building darkside…"
emcc $FLAGS -sEXPORT_NAME=DarksideModule     $COMMON $SRC/mfkey.c       $SRC/darkside.c     -o "$OUT/darkside.js"

echo "Done. Artifacts in $OUT:"
ls -la "$OUT"
