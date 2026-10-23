#!/usr/bin/env bash
# Build a static, modelling-only OpenCASCADE for one target.
#   usage: build-occt.sh <web|macos> <build-dir> <install-dir> [extra CXX flags...]
# Only FoundationClasses + ModelingData + ModelingAlgorithms are built: no
# visualisation, no data exchange, no Tcl/Tk/FreeType/OpenGL.
set -euo pipefail
target=$1 build=$2 prefix=$3; shift 3
cxxflags="$*"
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

case $target in
  web)   emcmake cmake -S "$OCCT_SRC" -B "$build" "${common[@]}" ;;
  macos) cmake -S "$OCCT_SRC" -B "$build" "${common[@]}" \
           -DCMAKE_C_COMPILER=/usr/bin/clang -DCMAKE_CXX_COMPILER=/usr/bin/clang++ \
           -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 ;;
  *) echo "unknown target $target" >&2; exit 2 ;;
esac
cmake --build "$build"
cmake --install "$build"
