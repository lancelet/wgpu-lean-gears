# lean-gears build. Run inside `nix develop` (tools only; Nix builds nothing).
#
#   make                      # TARGET/ASYNC from config.mk (default: web, jspi)
#   make TARGET=macos
#   make TARGET=web ASYNC=asyncify
#   make run                  # serve dist/web-*, or open the .app
#   make site                 # both web builds + auto-selecting page -> dist/site (what CI publishes)
#
# Pipeline:   Lean --lake--> C --cc/emcc--> .o --link--> app
#   * Lean app:    `lake build` emits .lake/build/ir/*.c (target-independent C)
#   * Lean stdlib: native -> toolchain's libInit.a/libleanrt.a
#                  web    -> Init re-elaborated to C (scripts/gen-stdlib-c.sh),
#                            runtime compiled from the pinned Lean source
#   * OCCT, libuv: CMake, once per (target, exception model), cached in .toolchain/
include config.mk

SHELL := bash
.DELETE_ON_ERROR:
.SUFFIXES:

ifeq ($(origin LEAN4_SRC),undefined)
  $(error run inside 'nix develop' (LEAN4_SRC is not set))
endif

LEAN_PREFIX  := $(shell lean --print-prefix)
LEAN_VERSION := $(shell lean --short-version)
LEAN_GITHASH := $(shell lean --githash)
TC := .toolchain

ifeq ($(TARGET),web)
  VARIANT := web-$(ASYNC)
else ifeq ($(TARGET),macos)
  VARIANT := macos
else
  $(error TARGET must be web or macos)
endif
BUILD := build/$(VARIANT)
DIST  := dist/$(VARIANT)

# --- the Lean application (same C for both targets) ------------------------
LEAN_SRCS := Main.lean Gears.lean $(wildcard Gears/*.lean)
IR        := .lake/build/ir
APP_LEAN_C := $(addprefix $(IR)/,$(LEAN_SRCS:.lean=.c))

build/lake.stamp: $(LEAN_SRCS) lakefile.toml lean-toolchain
	@mkdir -p $(@D)
	lake build
	@touch $@
$(APP_LEAN_C): build/lake.stamp ;
APP_LEAN_OBJS := $(patsubst $(IR)/%.c,$(BUILD)/lean/%.o,$(APP_LEAN_C))

# Recursive (=) so PLATFORM_OBJ can be set by the target section below.
OBJS = $(APP_LEAN_OBJS) $(BUILD)/native/entry.o $(BUILD)/native/gpu.o \
       $(BUILD)/native/occt_gear.o $(PLATFORM_OBJ)

OCCT_LIBS := -lTKBO -lTKPrim -lTKMesh -lTKShHealing -lTKTopAlgo -lTKGeomAlgo \
             -lTKBRep -lTKGeomBase -lTKG3d -lTKG2d -lTKMath -lTKernel

# ===========================================================================
ifeq ($(TARGET),web)
# ===========================================================================
CC  := emcc
CXX := em++
AR  := emar

ifeq ($(ASYNC),jspi)
  EH := -fwasm-exceptions
  EHNAME := wasmeh
  ASYNC_LDFLAGS := -sJSPI=1
else ifeq ($(ASYNC),asyncify)
  EH := -fexceptions
  EHNAME := jseh
  ASYNC_LDFLAGS := -sASYNCIFY=1 -sASYNCIFY_STACK_SIZE=1048576
else
  $(error ASYNC must be jspi or asyncify)
endif

OCCT  := $(TC)/occt-web-$(EHNAME)
LIBUV := $(TC)/libuv-web-$(EHNAME)
STDLIB_C := $(TC)/stdlib-c-$(LEAN_VERSION)

# Lean headers: lean.h from the pinned source, our own config.h (no mimalloc).
LEAN_INC := -I$(BUILD)/include -I$(LEAN4_SRC)/src/include
LEAN_CFLAGS := $(OPT) $(EH) -DLEAN_EMSCRIPTEN -DNDEBUG $(LEAN_INC) -w
RT_CXXFLAGS := $(OPT) $(EH) -std=c++20 -DLEAN_EMSCRIPTEN -DNDEBUG -DLEAN_EXPORTING \
               $(LEAN_INC) -I$(LEAN4_SRC)/src -I$(LIBUV_SRC)/include -I$(BUILD)/include -w
PORT := --use-port=emdawnwebgpu

$(BUILD)/include/lean/config.h:
	@mkdir -p $(@D)
	cp $(LEAN_PREFIX)/include/lean/version.h $(@D)/
	printf '#pragma once\n#include <lean/version.h>\n#define LEAN_IS_STAGE0 0\n' > $@
	printf '#define LEAN_GITHASH "%s"\n' $(LEAN_GITHASH) > $(BUILD)/include/githash.h

# Lean runtime: src/runtime/CMakeLists.txt's list minus mimalloc and uv/*.
# uv/* only backs Std.Internal.UV (not linked here), and its Emscripten stubs
# no longer compile in 4.35 (lean_uv_os_get_group signature mismatch).
RT_SRCS := debug thread mpz utf8 object apply exception interrupt memory stackinfo \
  compact init_module io hash byteslice platform alloc allocprof sharecommon \
  stack_overflow process object_ref mpn mutex libuv openssl
RT_OBJS := $(addprefix $(BUILD)/rt/,$(RT_SRCS:=.o))
$(BUILD)/rt/%.o: $(LEAN4_SRC)/src/runtime/%.cpp | $(BUILD)/include/lean/config.h
	@mkdir -p $(@D)
	$(CXX) $(RT_CXXFLAGS) -c $< -o $@
$(BUILD)/libleanrt.a: $(RT_OBJS)
	@rm -f $@
	$(AR) rcs $@ $^

# Lean stdlib: Init -> C (once per Lean version) -> archive (once per variant).
$(STDLIB_C)/.stamp:
	scripts/gen-stdlib-c.sh $(STDLIB_C) Init
	@touch $@
$(BUILD)/libInit.a: $(STDLIB_C)/.stamp | $(BUILD)/include/lean/config.h
	$(MAKE) -f mk/archive.mk SRC=$(STDLIB_C) OUT=$(BUILD)/stdlib LIB=$@ \
	  CC=$(CC) AR=$(AR) CFLAGS="$(LEAN_CFLAGS)"

$(LIBUV)/out/libuv.a:
	scripts/build-libuv-web.sh $(EHNAME) $(LIBUV)

$(OCCT)/install/.complete:
	scripts/build-occt.sh web-$(EHNAME) $(OCCT)/build $(OCCT)/install

PLATFORM_OBJ := $(BUILD)/native/platform_web.o
$(BUILD)/native/%.o: native/%.c | $(BUILD)/include/lean/config.h
	@mkdir -p $(@D)
	$(CC) $(OPT) $(EH) $(PORT) -DLEAN_EMSCRIPTEN $(LEAN_INC) -c $< -o $@

LIBS := $(BUILD)/libInit.a $(BUILD)/libleanrt.a $(LIBUV)/out/libuv.a $(OCCT)/install/.complete

LDFLAGS := $(OPT) $(EH) $(PORT) $(ASYNC_LDFLAGS) \
  -sALLOW_MEMORY_GROWTH=1 -sINITIAL_MEMORY=67108864 -sSTACK_SIZE=8388608 \
  -sMODULARIZE=1 -sEXPORT_ES6=1 -sEXPORT_NAME=createGears -sENVIRONMENT=web \
  -L$(OCCT)/install/lib $(OCCT_LIBS)

APP := $(DIST)/gears.js
$(APP): $(OBJS) $(LIBS) web/index.html web/main.ts
	@mkdir -p $(@D)
	$(CXX) -o $@ $(OBJS) $(BUILD)/libInit.a $(BUILD)/libleanrt.a $(LIBUV)/out/libuv.a $(LDFLAGS)
	esbuild web/main.ts --bundle --format=esm --target=es2022 \
	  --define:BUILD_ASYNC='"$(ASYNC)"' --outfile=$(DIST)/main.js
	cp web/index.html $(DIST)/index.html
	@ls -lh $(DIST)

run: all
	@echo "serving http://localhost:8000 (needs a WebGPU browser; ASYNC=$(ASYNC))"
	python3 -m http.server -d $(DIST) 8000

# ===========================================================================
else  # macos
# ===========================================================================
CC  := /usr/bin/clang
CXX := /usr/bin/clang++
OCCT := $(TC)/occt-macos
LEAN_INC := -I$(LEAN_PREFIX)/include
LEAN_CFLAGS := $(OPT) $(LEAN_INC) -w
MACOS_MIN := -mmacosx-version-min=15.0

$(OCCT)/install/.complete:
	scripts/build-occt.sh macos $(OCCT)/build $(OCCT)/install

PLATFORM_OBJ := $(BUILD)/native/platform_macos.o
$(BUILD)/native/%.o: native/%.c
	@mkdir -p $(@D)
	$(CC) $(OPT) $(MACOS_MIN) $(LEAN_INC) -I$(WGPU_NATIVE_DEV)/include -c $< -o $@
$(BUILD)/native/%.o: native/%.m
	@mkdir -p $(@D)
	$(CC) $(OPT) $(MACOS_MIN) -fobjc-arc $(LEAN_INC) -I$(WGPU_NATIVE_DEV)/include -c $< -o $@

LIBS := $(OCCT)/install/.complete
APPDIR := $(DIST)/LeanGears.app
APP := $(APPDIR)/Contents/MacOS/lean-gears

$(APP): $(OBJS) $(LIBS) native/Info.plist
	@mkdir -p $(@D) $(APPDIR)/Contents/Frameworks
	$(CXX) $(MACOS_MIN) -o $@ $(OBJS) \
	  -L$(OCCT)/install/lib $(OCCT_LIBS) \
	  -L$(LEAN_PREFIX)/lib/lean -lInit -lStd -lleanrt -L$(LEAN_PREFIX)/lib -luv -lgmp -lssl -lcrypto \
	  -L$(WGPU_NATIVE)/lib -lwgpu_native \
	  -framework Cocoa -framework QuartzCore -framework Metal \
	  -Wl,-dead_strip -Wl,-rpath,@executable_path/../Frameworks
	cp native/Info.plist $(APPDIR)/Contents/Info.plist
	# Self-contained bundle: ship wgpu-native and point it away from /nix/store.
	install -m 644 $(WGPU_NATIVE)/lib/libwgpu_native.dylib $(APPDIR)/Contents/Frameworks/
	install_name_tool -id @rpath/libwgpu_native.dylib $(APPDIR)/Contents/Frameworks/libwgpu_native.dylib
	for dep in $$(otool -L $(APPDIR)/Contents/Frameworks/libwgpu_native.dylib | awk '/\/nix\/store\/.*libiconv/{print $$1}'); do \
	  install_name_tool -change $$dep /usr/lib/libiconv.2.dylib $(APPDIR)/Contents/Frameworks/libwgpu_native.dylib; done
	install_name_tool -change $(WGPU_NATIVE)/lib/libwgpu_native.dylib @rpath/libwgpu_native.dylib $@
	codesign --force --sign - $(APPDIR)/Contents/Frameworks/libwgpu_native.dylib
	codesign --force --sign - $(APPDIR)
	@if otool -L $@ $(APPDIR)/Contents/Frameworks/*.dylib | grep -q /nix/store; then \
	  echo "error: bundle still references /nix/store"; exit 1; fi

run: all
	open $(APPDIR)
endif

# --- shared rules ------------------------------------------------------------
$(BUILD)/lean/%.o: $(IR)/%.c | $(if $(filter web,$(TARGET)),$(BUILD)/include/lean/config.h)
	@mkdir -p $(@D)
	$(CC) $(LEAN_CFLAGS) -c $< -o $@

$(BUILD)/native/occt_gear.o: native/occt_gear.cpp $(OCCT)/install/.complete
	@mkdir -p $(@D)
	$(CXX) $(OPT) $(EH) $(LEAN_INC) -I$(OCCT)/install/include/opencascade -std=c++17 -w -c $< -o $@

$(BUILD)/native/gpu.o $(PLATFORM_OBJ): native/platform.h

# --- the published site: both web builds, the page picks one at load time ----
SITE := dist/site
web-jspi web-asyncify:
	$(MAKE) TARGET=web ASYNC=$(@:web-%=%)
site: web-jspi web-asyncify
	scripts/assemble-site.sh dist/web-jspi dist/web-asyncify $(SITE)

.PHONY: all run clean distclean site web-jspi web-asyncify
.DEFAULT_GOAL := all
all: $(APP)

clean:
	rm -rf build dist .lake
distclean: clean
	rm -rf $(TC)
