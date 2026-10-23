# Build configuration. Override on the command line, e.g.
#   make TARGET=macos
#   make TARGET=web ASYNC=asyncify
#
# TARGET : web   -> dist/web-$(ASYNC)/  (static site: index.html + main.js + gears.js + gears.wasm)
#          macos -> dist/macos/LeanGears.app
TARGET ?= web

# Web only. How Lean's blocking `waitFrame` suspends the wasm stack:
#   jspi     -> JS Promise Integration (Chrome/Edge 137+, Safari 27+, Firefox 153+);
#               native wasm exceptions; small and fast.
#   asyncify -> Binaryen Asyncify rewrite (any WebGPU browser, e.g. Safari 26);
#               JS-based C++ exceptions; bigger and slower.
ASYNC ?= jspi

# Optimisation for everything we compile (OCCT has its own: see scripts/build-occt.sh).
OPT ?= -O2
