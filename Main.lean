import Gears

/-!
No `def main`: Lean's generated C `main` runs the program on a fresh thread
(for a big stack), which neither single-threaded wasm nor Cocoa (UI must stay
on the main thread) tolerates. `native/entry.c` calls this instead.
-/
@[export gears_main]
def gearsMain : IO Unit := Gears.Runtime.run
