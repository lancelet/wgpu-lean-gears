# lean-gears

**Live demo: <https://lancelet.github.io/wgpu-lean-gears/>.** You need a
browser with WebGPU: current Chrome or Edge, Safari 26 or later, or Firefox
141 or later on Windows.

> [!IMPORTANT]
> **This is an AI-only experiment.** All the code, build scripts, CI and
> documentation in this repository were written by an AI: Claude (Anthropic's
> Opus 5.5 model, running in Claude Code). The human owner set the goals and
> made the main design decisions: Lean must own the event loop, use WebGPU via
> `webgpu.h`, use Nix for tools only, and let OpenCASCADE do the geometry. The
> human did not write the code. Treat this as an unaudited proof of concept
> and a record of what we found out, not as a reference implementation. The
> claims under "What has been verified" are the AI's own checks.

A `glxgears` for **Lean 4 + WebGPU (wgpu) + OpenCASCADE**, built for two
targets from one codebase:

* **web**: a single `.wasm` (Lean + OCCT + the Lean runtime) that runs
  entirely in the browser through WebGPU.
* **macOS**: a self-contained `LeanGears.app` that runs offline, using
  **wgpu-native** (Rust wgpu behind the C ABI) on Metal.

Three gears with true involute teeth (module 0.3, 20° pressure angle) spin and
mesh. You can drag to orbit, two-finger scroll to orbit, pinch or use the mouse
wheel to zoom, press **space** to pause or resume, and press **r** to reset the camera.

## Architecture

There are four layers, and only Lean makes decisions:

| Layer | What it does |
|---|---|
| **Lean** (`Gears/`) | The whole app, in Elm style. A pure `update : Msg → Model → Model × List Cmd` and `view : Model → Scene`. A runtime loop that owns the event loop, decodes input, performs `Cmd`s and turns the `Scene` into GPU buffer writes and draws. |
| **C/C++ shims** (`native/`) | About ten `@[extern]` functions in three groups: `Platform` (window/canvas and the blocking `waitFrame`), `Gpu` (a handle-based slice of `webgpu.h`) and `Occt` (build and mesh a gear). |
| **OpenCASCADE** | Exact involute B-Rep, extrusion, a boolean bore, then triangulation. |
| **Host** | Web: `web/main.ts`, about 90 lines that forward DOM events and give WebGPU its canvas. macOS: a bare Cocoa window. |

```
            ┌──────────────────────── Lean (Elm architecture) ────────────────────────┐
 events ──► │ Runtime.loop:  waitFrame ─► decode ─► update ─► Cmds ─► view ─► render │
            └─────┬──────────────────────────────┬──────────────────────────┬─────────┘
                  │ Platform.waitFrame           │ Occt.gear                │ Gpu.createBuffer/
                  ▼                              ▼                          ▼ writeBuffer/render
  platform_web.c (EM_ASYNC_JS) │ platform_macos.m      occt_gear.cpp            gpu.c  (webgpu.h)
  web/main.ts (DOM → records)  │ (NSEvent pump)        involute B-Rep → mesh    emdawnwebgpu │ wgpu-native
```

Lean owns the event loop. `Platform.waitFrame` is a real blocking call. In
the browser it suspends the whole wasm stack until the next
`requestAnimationFrame`, using JSPI or Asyncify. On macOS it drains the Cocoa
event queue, and the FIFO present paces frames. The TypeScript side has no app
logic: it sizes the canvas, queues raw input as number records and resolves
one promise per frame.

OpenCASCADE does the geometry. It samples each involute flank and interpolates
it as a B-spline (`GeomAPI_Interpolate`), joins the flanks with tip and root
arcs, extrudes the profile, cuts the bore with a boolean (`BRepAlgoAPI_Cut`)
and meshes the solid (`BRepMesh_IncrementalMesh`). Lean asks for the gears by
parameter and takes the vertex and index bytes back. It also works out the gear
train: centre distances and the phase that keeps tooth meshed with gap. Lean
then creates and fills every GPU buffer itself, packing the per-draw uniforms
as `f32` bytes.

## Quick start

```sh
nix develop                      # tools only: emscripten, cmake, ninja, node, esbuild, wgpu-native, gnumake
make                             # default from config.mk: TARGET=web ASYNC=jspi  -> dist/web-jspi/
make run                         # serves http://localhost:8000
make TARGET=macos run            # -> dist/macos/LeanGears.app
make TARGET=web ASYNC=asyncify   # -> dist/web-asyncify/ (for browsers without JSPI, e.g. Safari 26)
make site                        # both web builds + a page that picks one -> dist/site/ (what CI publishes)
node scripts/smoke-web.mjs       # headless-Chrome test against a running `make run`
```

Lean comes from elan (`lean-toolchain` = 4.35.0). The first build of each
variant compiles OpenCASCADE, which takes about 6 to 10 minutes on an M1 Max.
After that it is cached in `.toolchain/`, so a Lean-only change rebuilds in
seconds.

| Which build | Browser support |
|---|---|
| `ASYNC=jspi` (default) | Chrome/Edge 137+, Safari 27+, Firefox 153+ |
| `ASYNC=asyncify` | any browser with WebGPU (Safari 26, older Chrome) |
| `make site` | both of the above; the page checks for `WebAssembly.Suspending` and loads the JSPI build when it's there, otherwise the Asyncify one (force with `?variant=asyncify`) |

## CI and the published page

`.github/workflows/pages.yml` runs on every push and pull request. No built
files are ever checked in. It has three jobs:

* **build**: a matrix with one runner per wasm variant (`jspi`, `asyncify`),
  running in parallel. Each needs its own OpenCASCADE build (different C++
  exception model), and on a cold cache that's the slow part: well over an
  hour on a 4-core runner. Each runner:
  1. installs Nix and elan;
  2. restores its caches, each keyed only on the files that determine it:
     OpenCASCADE (`flake.lock`, `build-occt.sh`), libuv, `Init` as C
     (`lean-toolchain`, the generator script), the Emscripten cache, and the
     compiled Lean runtime and `Init` archives;
  3. runs `nix develop --command make TARGET=web ASYNC=<variant>`, the same
     command as locally;
  4. uploads `gears.js` and `gears.wasm`;
  5. saves any cache that missed, *even if the build failed, timed out or was
     cancelled*, so a cold OpenCASCADE build is never thrown away.
* **site**: downloads both variants and runs `scripts/assemble-site.sh`
  (`make site` runs the same script locally) inside a small devShell
  (`nix develop .#site`, just esbuild).
* **deploy**: on `main` only, publishes `dist/site/` to GitHub Pages.

All third-party compiler flags live in the build scripts, not the Makefile,
so a script's hash is a complete cache key. A finished OpenCASCADE install
is marked by `install/.complete`, so a half-installed build is never cached.
Builds on `main` are never cancelled by a newer push, because they may be
filling the cache; stale PR builds are cancelled. The Lean toolchain and the
Nix store aren't cached; they probably download about as fast as they would
restore.

Only the web version is built in CI. The macOS app is built locally with
`make TARGET=macos`.

## Layout

```
Main.lean, Gears/          the Lean app
  App.lean                 Model / Msg / update / view / Cmd: pure, no IO
  Runtime.lean             the event loop, event decoding, uniform packing, GPU upload
  FFI.lean                 the entire foreign interface (≈10 externs)
  Math.lean, Shader.lean   mat4 + WGSL (Lean owns the shader source)
native/
  entry.c                  C main: init Lean modules, call the exported Lean entry
  gpu.c                    webgpu.h shim, the same file for both targets
  occt_gear.cpp            OpenCASCADE gear → mesh
  platform_web.c           EM_ASYNC_JS waitFrame, canvas surface
  platform_macos.m         Cocoa window + CAMetalLayer, no GLFW/SDL
web/                       index.html + main.ts (event forwarding only)
flake.nix                  devShell + pinned sources (Lean runtime, libuv)
config.mk                  TARGET / ASYNC / OPT
Makefile, mk/archive.mk    the build
scripts/                   build-occt.sh, build-libuv-web.sh, gen-stdlib-c.sh, smoke-web.mjs
```

## The build pipeline

```
 Lean sources ──lake build──► .lake/build/ir/*.c ─┐   (the same C for every target)
                                                  │
 web:   Init  ──lean -c (×653, parallel)──► C ──┐ │
        lean4 src/runtime ─────────────────────┤ ├─ emcc ──► gears.wasm + gears.js
        libuv, OCCT ──emcmake (cached)─────────┘ │           + main.js (esbuild) + index.html
                                                 │
 macOS: toolchain libInit.a/libleanrt.a ─────────┴─ clang ─► LeanGears.app (+ bundled wgpu-native)
        OCCT ──cmake (cached)
```

* **Nix** supplies tools and pinned source trees only: the `lean4` and `libuv`
  flake inputs, OCCT's source via nixpkgs, and wgpu-native. Nix builds nothing
  for the project.
* **Lake** turns Lean into C. That's all it is asked to do.
* **Make** owns the C world for both targets. `config.mk` chooses the variant,
  and outputs go to `build/<variant>` and `dist/<variant>`.
* **CMake** is used only for third-party code (OCCT, libuv). It runs through
  small scripts, and the results are cached in `.toolchain/` per (target,
  exception model).

## Designing for both web and native wgpu

If you bind Lean to **wgpu-native** in another project, you can keep the door
open to the web. Write against the standard **`webgpu.h`**, not wgpu-native's
`wgpu.h` extensions. This repo shows it works: one `native/gpu.c` compiles
against wgpu-native (macOS) and emdawnwebgpu (browser). Only three things
differ: creating the surface, waiting for adapter and device requests, and
presenting frames.

What makes porting hard later is mostly native habits, roughly in order of
pain:

1. **Blocking on the GPU.** Native code can poll or wait anywhere: map a
   buffer, spin on `wgpuDevicePoll`/`ProcessEvents`, read results back at
   once. The browser can never block. Readbacks (`mapAsync`) are the classic
   trap. Design the Lean API so GPU results come back asynchronously, for
   example as a `Msg` in an Elm-style loop, not as a blocking `IO` call. JSPI
   can cover a few waits (`wgpuInstanceWaitAny` here), but not blocking
   everywhere.
2. **Owning the frame loop.** In the browser, presentation happens when you
   yield to `requestAnimationFrame`, and `wgpuSurfacePresent` *aborts* in
   emdawnwebgpu. Make the app "wait for the next frame, then render one",
   like `Platform.waitFrame` here, so the native present call is a detail of
   one platform.
3. **wgpu-native extensions.** Push constants, `wgpuDevicePoll`, SPIR-V/GLSL
   shader input, polygon-mode line, pipeline statistics and other native-only
   features don't exist in browsers. Write shaders in **WGSL only**. Put any
   extension behind a feature check with a portable fallback.
4. **Limits and optional features.** Browsers expose conservative, per-browser
   limits: buffer sizes, storage buffers per stage, 256-byte uniform-offset
   alignment, optional features. Request only what you need, read the limits
   at startup, and test in more than one browser. Safari and Chrome differ.
5. **Threads.** A wasm build without pthreads runs on one thread, and Lean
   `Task`s run synchronously there. Keep GPU encoding and submission
   single-threaded, and don't depend on parallel `Task`s for correctness.
6. **Header drift.** wgpu-native's `webgpu.h` sometimes lags Dawn's. Here they
   were nearly identical, including the `*_INIT` macros, but pin both versions
   and expect the occasional `#ifdef`. Both are converging on the standard
   webgpu-headers.
7. **Binding the Rust crate instead of the C ABI.** Calling Rust `wgpu`
   through a Rust shim puts the browser build in a separate wasm-bindgen
   module that can't link with Emscripten's. Going through wgpu-native's C
   header avoids that.

Two more observations from this project:

* **The hard part of going to the web is Lean, not wgpu.** Building the Lean
  runtime and stdlib for wasm, single-threading, matching exception models
  and suspending the stack (JSPI/Asyncify) were most of the work. The GPU
  layer was the easy part.
* **The cheapest insurance is a web target in CI from day one,** even one that
  only clears the screen. Each native-only habit then fails a build or a smoke
  test the week it's introduced, not a year later. This repo's `gpu.c` +
  `platform_web.c` + JSPI `waitFrame` + `make site` is a working template.

## Findings and recommendations

**1. Lean → wasm works with stock tooling, but you have to assemble it.**
Lean ships no wasm toolchain, but its C output is portable to `wasm32`, so you
can compile it with `emcc`. Three pieces are needed:

* **Your app:** use `lake build` and take the `.c` files.
* **The stdlib (`Init`):** the toolchain ships the `.lean` sources and
  `.olean`s, so each module can be re-elaborated on its own with
  `lean -R . -c X.c X.lean`. That's 653 files in about 45 s on 10 cores,
  cached per Lean version (`scripts/gen-stdlib-c.sh`). *Dead end:*
  `leanir` (new in 4.3x) looks like "C from `.ir`", but it only emits
  **postponed** declarations, so for the stdlib it produces near-empty files.
* **The runtime:** compile `src/runtime/*.cpp` from the pinned Lean source
  directly. **Don't** use Lean's CMake Emscripten path, which wants pthreads,
  mimalloc and the whole compiler. Instead:
  * write your own `lean/config.h` without `LEAN_MIMALLOC`
  * add `-DLEAN_EMSCRIPTEN`
  * build single-threaded, which means no SharedArrayBuffer and no COOP/COEP
    headers
  * leave out `uv/*.cpp`: in 4.35 those Emscripten stubs don't even compile
    (`lean_uv_os_get_group` signature mismatch), and they only back
    `Std.Internal.UV`
  * still link libuv (built the same way Lean upstream does), because `io.cpp`
    uses it.

  More signs the Emscripten path has drifted: `wasm-ld` warns about signature
  mismatches for `lean_io_create_tempfile` and `lean_io_create_tempdir`
  between the runtime and `Init`. Neither is called here.

**2. Don't use Lean's generated `main`.** It runs the program on a new thread
for a large stack (`lean_run_main` → `lthread`). Single-threaded wasm can't
spawn that thread, and Cocoa needs the UI on the process's main thread.
Instead, mark the entry with `@[export gears_main]` and write a 15-line C
`main` (`native/entry.c`).

**3. Choose one exception model per binary and key every cache on it.** With
JSPI, use native wasm exceptions (`-fwasm-exceptions`). Asyncify can't
instrument those, so the Asyncify build needs `-fexceptions`. OCCT, libuv, the
Lean runtime and the app must all agree. That's why the caches are
`.toolchain/occt-web-wasmeh` and `.toolchain/occt-web-jseh`.

**4. `webgpu.h` is the right seam, not the Rust crate.** wgpu-native and
emdawnwebgpu now implement nearly identical standard headers, including the
`*_INIT` macros. So `gpu.c` is one file for both targets, and only three things
differ:

* **Surface source:** a Metal layer natively, a canvas selector on the web.
* **Async requests:** `wgpuInstanceWaitAny` on the web (it suspends via
  JSPI/Asyncify). Natively, spin on `wgpuInstanceProcessEvents`.
* **Present:** call `wgpuSurfacePresent` natively only. In emdawnwebgpu it
  *aborts*, because the browser presents when you yield to rAF.

In the browser, the WebGPU implementation is the browser's own whichever
binding you use. Both emdawnwebgpu and Rust wgpu-on-wasm are thin wrappers
over `navigator.gpu`. The Rust crate would add a second wasm module
(wasm-bindgen) that can't link with Emscripten's.

**5. Make Lean the event loop by making `waitFrame` block.** With JSPI an
`EM_ASYNC_JS` import suspends the stack. Lean's `partial def loop` is
tail-recursive, so it compiles to a C loop with no stack growth. That keeps
the Elm runtime straightforward:
`decode raw events → foldl update → perform Cmds → render (view model)`.
Input policy, such as "trackpad scroll orbits but a notched wheel zooms", lives
in Lean, and both frontends forward the same 5-number records.

**6. Keep FFI data flat.** All data crosses as `ByteArray`/`FloatArray`, with
scalars as `UInt32`/`Float`. Lean packs `f32` itself
(`Float.toFloat32.toBits`), so C hands the bytes straight to
`wgpuQueueWriteBuffer`. The only Lean object built in C is a `Prod`. In 4.35,
`IO` externs take **no world token**: `lean_obj_res f(args…)` returns
`lean_io_result_mk_ok(x)`.

**7. Native macOS without a windowing library is about 130 lines.** It's an
`NSWindow` plus a `CAMetalLayer`, with the NSEvent queue pumped by hand from
`waitFrame`. That gives you the native trackpad events (`magnifyWithEvent:`,
precise scrolling deltas) that GLFW lacks.

To make the app bundle self-contained:

* copy wgpu-native's dylib into `Contents/Frameworks`
* rewrite its `/nix/store` libiconv reference to `/usr/lib`
* ad-hoc sign the bundle (the Makefile fails if anything still points at
  `/nix/store`)

Lean 4.35's bundled static libs are built for macOS 15, which sets the minimum
macOS version.

**8. Nix: pin sources as flake inputs and keep the emscripten cache writable.**
The Nix store is read-only, but emscripten writes its cache and ports, so the
shell hook seeds `EM_CACHE` in `.toolchain/`. The emdawnwebgpu port is fetched
from GitHub on first use. Pinning it as a flake input as well would make
builds fully offline-reproducible.

**9. Sizes and times (M1 Max).**

| Item | Size or time |
|---|---|
| `gears.wasm` (`-O2`), JSPI | 7.7 MB (2.7 MB gzipped) |
| `gears.wasm` (`-O2`), Asyncify | 19 MB (4.8 MB gzipped). The instrumentation more than doubles the binary, probably because Lean's closures make most calls indirect, so Asyncify has to instrument almost everything (not measured) |
| `.app` | 18 MB (11 MB binary + 7 MB wgpu-native) |
| First build per variant | OCCT 6–10 min, `Init` → C 45 s, runtime and archive about 1 min |
| Rebuild after a Lean change | a few seconds |

There's headroom: `-Oz`, `--closure=1` (recommended by emdawnwebgpu), and
building only the OCCT toolkits actually linked (12) instead of three whole modules (18).

### What has been verified

* **macOS:** the app launches and renders the three meshed gears through
  wgpu-native on Metal. I checked the window visually but did not
  automatically test its input.
* **Web, JSPI and Asyncify builds:** both tested in headless Chrome 155 via
  `scripts/smoke-web.mjs`. Lean logs the OCCT meshes, then drag-orbit and
  ctrl-wheel pinch zoom both work. SPACE freezes the frames (two screenshots
  1 s apart are identical) and SPACE again resumes them.
* **Gear meshing:** a numerical check of the profile and phase formulas shows
  zero tooth interference (zero-backlash contact only).
* **Determinism:** the native and wasm builds get identical meshes from OCCT,
  with the same vertex and triangle counts.
* **Published site (`make site`):** tested with the same smoke test, for both
  the auto-selected JSPI build and `?variant=asyncify`.
* **Not tested:** Safari or Firefox, real trackpad hardware, and native input
  events (the code is written but nothing drove it automatically). The
  development machine was a Mac, so the Linux CI build was never run locally
  before it was first pushed.
