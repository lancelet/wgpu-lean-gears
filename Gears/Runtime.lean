import Gears.App
import Gears.FFI
import Gears.Shader

/-!
The Elm runtime: owns the event loop, turns raw platform events into `Msg`s,
runs `update`, performs `Cmd`s, and turns `view`'s `Scene` into GPU buffer
writes and a draw list.
-/
namespace Gears.Runtime

/-- Bytes per draw in the uniform buffer (`minUniformBufferOffsetAlignment`). -/
def uniformStride : Nat := 256

/-- Raw wheel flags sent by both frontends. -/
def wheelPinch : UInt32 := 1     -- ctrl+wheel: a trackpad pinch in browsers
def wheelDiscrete : UInt32 := 2  -- a notched mouse wheel rather than a trackpad

/--
Decode `[timeMs, (kind, a, b, c, d)*]` into messages. This is also where input
policy lives ("subscriptions"): trackpad scroll orbits, pinch and mouse wheel zoom.
-/
def decode (raw : FloatArray) : List Msg := Id.run do
  if raw.size == 0 then return []
  let mut out : Array Msg := #[]
  let n := (raw.size - 1) / 5
  for i in [0:n] do
    let o := 1 + i * 5
    let k := raw[o]!; let a := raw[o+1]!; let b := raw[o+2]!; let c := raw[o+3]!
    match k.toUInt32 with
    | 1 => out := out.push (.resize a b)
    | 2 => out := out.push (.drag a b)
    | 3 =>
      let flags := c.toUInt32
      if flags &&& wheelPinch != 0 then out := out.push (.zoom (Float.exp (b * 0.01)))
      else if flags &&& wheelDiscrete != 0 then out := out.push (.zoom (Float.exp (b * 0.0015)))
      else out := out.push (.orbit (-a) (-b))
    | 4 => out := out.push (.zoom (Float.exp (-a)))
    | 5 => out := out.push (.key a.toUInt32.toNat)
    | 6 => out := out.push .quit
    | _ => pure ()
  out := out.push (.frame raw[0]!)
  return out.toList

/-- 160 bytes: `mvp`, `model`, `color`, `light` – the WGSL `U` struct. -/
def packUniform (d : Draw) : ByteArray :=
  ByteArray.empty
    |>.pushMat4 d.mvp |>.pushMat4 d.model
    |>.pushF32 d.color.x |>.pushF32 d.color.y |>.pushF32 d.color.z |>.pushF32 1
    |>.pushF32 5 |>.pushF32 5 |>.pushF32 10 |>.pushF32 0

structure GpuMesh where
  vbuf  : UInt32
  ibuf  : UInt32
  count : UInt32
  deriving Inhabited

/-- Ask OCCT for every gear and hand the resulting meshes to the GPU. -/
def uploadGears : IO (Array GpuMesh) := do
  let mut out := #[]
  for g in gearSpecs do
    let (verts, idx) ← Occt.gear g.teeth.toUInt32 gearModule g.width g.bore pressureAngle 0.01
    IO.eprintln s!"[lean] gear z={g.teeth}: {verts.size / 24} vertices, {idx.size / 12} triangles"
    let vbuf ← Gpu.createBuffer (Gpu.usageVertex ||| Gpu.usageCopyDst) verts
    let ibuf ← Gpu.createBuffer (Gpu.usageIndex ||| Gpu.usageCopyDst) idx
    out := out.push { vbuf, ibuf, count := (idx.size / 4).toUInt32 }
  return out

def render (meshes : Array GpuMesh) (ubuf : UInt32) (s : Scene) : IO Unit := do
  let mut uniforms := ByteArray.empty
  let mut draws := ByteArray.empty
  for (d, i) in s.draws.zipIdx do
    uniforms := (uniforms ++ packUniform d).padTo ((i + 1) * uniformStride)
    let gm := meshes[d.mesh]!
    draws := draws.pushU32 gm.vbuf |>.pushU32 gm.ibuf |>.pushU32 gm.count
                   |>.pushU32 (i * uniformStride).toUInt32
  Gpu.writeBuffer ubuf 0 uniforms
  Gpu.render s.clear.x s.clear.y s.clear.z ubuf draws

/-- Perform commands; `false` means stop. -/
def perform (cmds : List Cmd) : IO Bool := do
  for c in cmds do
    match c with
    | .configureSurface w h => Gpu.configure w h
    | .quit => return false
  return true

partial def loop (meshes : Array GpuMesh) (ubuf : UInt32) (m : Model) : IO Unit := do
  let msgs := decode (← Platform.waitFrame)
  let (m, cmds) := msgs.foldl (init := (m, [])) fun (m, cs) msg =>
    let (m, c) := update msg m
    (m, cs ++ c)
  if ← perform cmds then
    render meshes ubuf (view m)
    loop meshes ubuf m

def run : IO Unit := do
  Platform.init "Lean Gears" 960 720
  Gpu.init wgsl
  let meshes ← uploadGears
  let ubuf ← Gpu.createBuffer (Gpu.usageUniform ||| Gpu.usageCopyDst)
    (ByteArray.empty.padTo (gearSpecs.length * uniformStride))
  IO.eprintln "[lean] entering event loop"
  loop meshes ubuf init

end Gears.Runtime
