#!/usr/bin/env bash
# Combine the two web builds into the published site: both wasm variants side
# by side, plus a page that picks one at load time (see web/main.ts).
#   usage: assemble-site.sh <jspi-dist> <asyncify-dist> <out>
# Needs only esbuild, so CI can run it in a small job after the parallel builds.
set -euo pipefail
jspi=$1 asyncify=$2 out=$3
rm -rf "$out"
mkdir -p "$out/jspi" "$out/asyncify"
cp "$jspi/gears.js" "$jspi/gears.wasm" "$out/jspi/"
cp "$asyncify/gears.js" "$asyncify/gears.wasm" "$out/asyncify/"
cp web/index.html "$out/"
esbuild web/main.ts --bundle --format=esm --target=es2022 \
  --define:BUILD_ASYNC='"auto"' --outfile="$out/main.js"
du -sh "$out"/*
