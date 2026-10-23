#!/usr/bin/env bash
# Build a static, modelling-only OpenCASCADE for one variant.
#   usage: build-occt.sh <web-wasmeh|web-jseh|macos> <build-dir> <install-dir>
# All compiler flags live here (not in the Makefile) so that hashing this file
# is a complete cache key for the result. `<install-dir>/.complete` marks success.
# Only FoundationClasses + ModelingData + ModelingAlgorithms are built: no
# visualisation, no data exchange, no Tcl/Tk/FreeType/OpenGL.
set -euo pipefail
variant=$1 build=$2 prefix=$3
case $variant in
  web-wasmeh) cxxflags="-O2 -fwasm-exceptions" ;;  # pairs with JSPI
  web-jseh)   cxxflags="-O2 -fexceptions" ;;       # pairs with Asyncify
  macos)      cxxflags="-O2" ;;
  *) echo "unknown variant $variant" >&2; exit 2 ;;
esac
rm -f "$prefix/.complete"
: "${OCCT_SRC:?run inside 'nix develop'}"

common=(
  -G Ninja
  -DCMAKE_BUILD_TYPE=Release
  -DBUILD_LIBRARY_TYPE=Static
  -DINSTALL_DIR="$prefix"
  -DBUILD_MODULE_FoundationClasses=ON
  -DBUILD_MODULE_ModelingData=ON
  -DBUILD_MODULE_ModelingAlgorithms=ON
  -DBUILD_MODULE_Visualization=OFF
  -DBUILD_MODULE_ApplicationFramework=OFF
  -DBUILD_MODULE_DataExchange=OFF
  -DBUILD_MODULE_DETools=OFF
  -DBUILD_MODULE_Draw=OFF
  -DBUILD_DOC_Overview=OFF
  -DBUILD_SAMPLES_QT=OFF
  -DUSE_TK=OFF -DUSE_TCL=OFF -DUSE_FREETYPE=OFF -DUSE_FREEIMAGE=OFF
  -DUSE_OPENGL=OFF -DUSE_GLES2=OFF -DUSE_XLIB=OFF -DUSE_VTK=OFF
  -DUSE_TBB=OFF -DUSE_RAPIDJSON=OFF -DUSE_DRACO=OFF -DUSE_FFMPEG=OFF
  -DUSE_OPENVR=OFF -DUSE_EIGEN=OFF
  -DCMAKE_CXX_FLAGS="$cxxflags"
  -DCMAKE_C_FLAGS="$cxxflags"
)

case $variant in
  web-*) emcmake cmake -S "$OCCT_SRC" -B "$build" "${common[@]}" ;;
  macos) cmake -S "$OCCT_SRC" -B "$build" "${common[@]}" \
           -DCMAKE_C_COMPILER=/usr/bin/clang -DCMAKE_CXX_COMPILER=/usr/bin/clang++ \
           -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 ;;
esac
cmake --build "$build"
cmake --install "$build"
touch "$prefix/.complete"
