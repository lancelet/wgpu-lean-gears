#!/usr/bin/env bash
# Produce C for Lean's own stdlib (e.g. Init) for targets the toolchain does
# not ship binaries for (wasm). The toolchain ships the .lean sources and the
# .olean files, so every module can be re-elaborated independently and in
# parallel with `lean -c` (imports resolve to the shipped .oleans).
#
# (`leanir` looks tempting but only emits code for *postponed* declarations,
#  so it produces near-empty C for the already-compiled stdlib.)
#
#   usage: gen-stdlib-c.sh <out-dir> <lib>...      e.g. gen-stdlib-c.sh build/stdlib-c Init
set -euo pipefail
out=$(mkdir -p "$1" && cd "$1" && pwd); shift
prefix=$(lean --print-prefix)   # resolved via ./lean-toolchain
export LEAN_PATH="$prefix/lib/lean" LEAN="$prefix/bin/lean"
src="$prefix/src/lean"

worker=$(mktemp); trap 'rm -f "$worker"' EXIT
cat > "$worker" <<'ONE'
#!/usr/bin/env bash
set -euo pipefail
out=$1 src=$2 path=$3            # path like Init/Data/Array/Basic
mkdir -p "$out/$(dirname "$path")"
cd "$src"
"$LEAN" -R . -c "$out/$path.c.tmp" "$path.lean" >/dev/null || { echo "lean -c failed: $path" >&2; exit 255; }
mv "$out/$path.c.tmp" "$out/$path.c"
ONE
chmod +x "$worker"

for lib in "$@"; do
  (cd "$src" && { echo "$lib.lean"; find "$lib" -name '*.lean'; }) | sed 's/\.lean$//'
done | xargs -P "$(sysctl -n hw.ncpu 2>/dev/null || nproc)" -n 1 "$worker" "$out" "$src"
echo "generated $(find "$out" -name '*.c' | wc -l | tr -d ' ') C files in $out"
