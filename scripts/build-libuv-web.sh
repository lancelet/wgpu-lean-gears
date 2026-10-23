#!/usr/bin/env bash
# libuv for the wasm Lean runtime, built the way Lean's own Emscripten build
# does it: upstream v1.48.0 plus one stub source file for Emscripten.
#   usage: build-libuv-web.sh <build-dir> [extra C flags...]
set -euo pipefail
build=$1; shift
: "${LIBUV_SRC:?run inside 'nix develop'}"
rm -rf "$build/src"; mkdir -p "$build"
cp -R "$LIBUV_SRC" "$build/src"; chmod -R u+w "$build/src"
# == Lean's LIBUV_PATCH_IN (src/CMakeLists.txt)
python3 - "$build/src/CMakeLists.txt" <<'PY'
import sys; p=sys.argv[1]; s=open(p).read()
anchor='if(CMAKE_SYSTEM_NAME STREQUAL "Linux")'
s=s.replace(anchor,'if(CMAKE_SYSTEM_NAME STREQUAL "Emscripten")\n  list(APPEND uv_sources src/unix/no-proctitle.c)\nendif()\n\n'+anchor,1)
open(p,'w').write(s)
PY
emcmake cmake -S "$build/src" -B "$build/out" -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DLIBUV_BUILD_TESTS=OFF -DLIBUV_BUILD_SHARED=OFF -DCMAKE_C_FLAGS="$*"
cmake --build "$build/out" --target uv_a
