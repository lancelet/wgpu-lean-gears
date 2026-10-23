{
  # Nix is used ONLY to provide pinned tools and source trees.
  # It does not build the project: that's `make` (see Makefile / config.mk).
  description = "lean-gears: Lean + WebGPU + OpenCASCADE dev tools";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    # Lean runtime C/C++ sources (src/runtime, src/include). Must match ./lean-toolchain.
    lean4-src = {
      url = "github:leanprover/lean4/v4.35.0";
      flake = false;
    };
    # libuv for the wasm Lean runtime; same tag Lean itself uses for its Emscripten build.
    libuv-src = {
      url = "github:libuv/libuv/v1.48.0";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, lean4-src, libuv-src }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" "aarch64-linux" "x86_64-linux" ];
      forAll = f: nixpkgs.lib.genAttrs systems (s: f nixpkgs.legacyPackages.${s});
    in {
      devShells = forAll (pkgs: {
        # Just enough to run scripts/assemble-site.sh (CI's final job).
        site = pkgs.mkShellNoCC { packages = [ pkgs.esbuild ]; };
        default = pkgs.mkShellNoCC {
          packages = with pkgs; [
            emscripten   # emcc/em++/emar, wasm-ld, binaryen
            cmake
            gnumake      # macOS ships make 3.81
            ninja
            nodejs       # emscripten tooling + local dev server
            esbuild      # TS -> JS, no node_modules needed
            python3
            wgpu-native  # webgpu.h implementation for the native build (Rust wgpu-core)
          ];
          # Paths handed to the (non-Nix) build.
          LEAN4_SRC = "${lean4-src}";
          LIBUV_SRC = "${libuv-src}";
          OCCT_SRC = "${pkgs.opencascade-occt.src}";
          OCCT_VERSION = pkgs.opencascade-occt.version;
          WGPU_NATIVE = "${pkgs.wgpu-native}";
          WGPU_NATIVE_DEV = "${pkgs.wgpu-native.dev}";
          EMSCRIPTEN_ROOT = "${pkgs.emscripten}/share/emscripten";
          shellHook = ''
            # The Nix store is read-only; emscripten needs a writable cache for
            # ports (emdawnwebgpu) and system libs. Seed it from the prebuilt one.
            export EM_CACHE="$PWD/.toolchain/emcache"
            if [ ! -d "$EM_CACHE" ]; then
              mkdir -p "$EM_CACHE"
              cp -R "$EMSCRIPTEN_ROOT/cache/." "$EM_CACHE/" 2>/dev/null || true
              chmod -R u+w "$EM_CACHE"
            fi
          '';
        };
      });
    };
}
