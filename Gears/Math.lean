/-!
Just enough linear algebra for a camera and three gears.
Matrices are column-major, matching WGSL's `mat4x4f`.
-/
namespace Gears

structure Vec3 where
  x : Float
  y : Float
  z : Float

structure Mat4 where
  /-- 16 entries, column-major: `m[c*4 + r]`. -/
  m : Array Float

namespace Mat4

def get (a : Mat4) (r c : Nat) : Float := a.m[c * 4 + r]!

def ofRows (rows : List (List Float)) : Mat4 := Id.run do
  let mut m := Array.replicate 16 0.0
  for r in [0:4] do
    for c in [0:4] do
      m := m.set! (c * 4 + r) ((rows[r]!)[c]!)
  return ⟨m⟩

def identity : Mat4 := ofRows [[1,0,0,0],[0,1,0,0],[0,0,1,0],[0,0,0,1]]

def mul (a b : Mat4) : Mat4 := Id.run do
  let mut m := Array.replicate 16 0.0
  for r in [0:4] do
    for c in [0:4] do
      let mut s := 0.0
      for k in [0:4] do
        s := s + a.get r k * b.get k c
      m := m.set! (c * 4 + r) s
  return ⟨m⟩

instance : Mul Mat4 := ⟨mul⟩

def translate (v : Vec3) : Mat4 :=
  ofRows [[1,0,0,v.x],[0,1,0,v.y],[0,0,1,v.z],[0,0,0,1]]

def rotX (a : Float) : Mat4 :=
  let c := a.cos; let s := a.sin
  ofRows [[1,0,0,0],[0,c,-s,0],[0,s,c,0],[0,0,0,1]]

def rotY (a : Float) : Mat4 :=
  let c := a.cos; let s := a.sin
  ofRows [[c,0,s,0],[0,1,0,0],[-s,0,c,0],[0,0,0,1]]

def rotZ (a : Float) : Mat4 :=
  let c := a.cos; let s := a.sin
  ofRows [[c,-s,0,0],[s,c,0,0],[0,0,1,0],[0,0,0,1]]

/-- Right-handed perspective with WebGPU's [0,1] depth range. -/
def perspective (fovY aspect near far : Float) : Mat4 :=
  let f := 1.0 / (fovY / 2.0).tan
  ofRows [[f / aspect, 0, 0, 0],
          [0, f, 0, 0],
          [0, 0, far / (near - far), near * far / (near - far)],
          [0, 0, -1, 0]]

end Mat4

def pi : Float := 3.14159265358979323846

end Gears

/-- Append `x` as a little-endian IEEE-754 binary32. -/
def ByteArray.pushF32 (b : ByteArray) (x : Float) : ByteArray :=
  let u := x.toFloat32.toBits
  b |>.push u.toUInt8 |>.push (u >>> 8).toUInt8 |>.push (u >>> 16).toUInt8 |>.push (u >>> 24).toUInt8

def ByteArray.pushU32 (b : ByteArray) (u : UInt32) : ByteArray :=
  b |>.push u.toUInt8 |>.push (u >>> 8).toUInt8 |>.push (u >>> 16).toUInt8 |>.push (u >>> 24).toUInt8

def ByteArray.pushMat4 (b : ByteArray) (a : Gears.Mat4) : ByteArray :=
  a.m.foldl ByteArray.pushF32 b

def ByteArray.padTo (b : ByteArray) (n : Nat) : ByteArray := Id.run do
  let mut b := b
  while b.size < n do b := b.push 0
  return b
