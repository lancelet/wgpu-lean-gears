/-!
The complete foreign interface. Three small groups:

* `Platform` – window/canvas and the frame clock. `waitFrame` is the only
  blocking call: natively it pumps the Cocoa event queue; in the browser it
  suspends the whole wasm stack (JSPI/Asyncify) until the next
  `requestAnimationFrame`, so Lean's loop really is *the* event loop.
* `Gpu` – a thin, handle-based slice of `webgpu.h`. Lean decides what goes in
  every buffer; C only forwards bytes.
* `Occt` – OpenCASCADE builds an involute gear B-Rep and triangulates it.
-/
namespace Gears

namespace Platform
/-- Create the window (native) or bind to `#canvas` (web). -/
@[extern "lean_platform_init"]
opaque init (title : @& String) (width height : UInt32) : IO Unit

/--
Block until the next frame. Returns `[timeMs, k₀, a₀, b₀, c₀, d₀, k₁, …]`:
a timestamp followed by 5-float event records (see `Gears.Runtime.decode`).
-/
@[extern "lean_platform_wait_frame"]
opaque waitFrame : IO FloatArray
end Platform

namespace Gpu
/-- `WGPUBufferUsage` bits. -/
def usageCopyDst : UInt32 := 0x08
def usageIndex   : UInt32 := 0x10
def usageVertex  : UInt32 := 0x20
def usageUniform : UInt32 := 0x40

/-- Acquire adapter/device, create the surface, compile `wgsl` into the pipeline. -/
@[extern "lean_gpu_init"]
opaque init (wgsl : @& String) : IO Unit

/-- (Re)configure the swapchain, depth and MSAA targets for a pixel size. -/
@[extern "lean_gpu_configure"]
opaque configure (width height : UInt32) : IO Unit

/-- Create a GPU buffer initialised with `data`; returns a handle. -/
@[extern "lean_gpu_create_buffer"]
opaque createBuffer (usage : UInt32) (data : @& ByteArray) : IO UInt32

@[extern "lean_gpu_write_buffer"]
opaque writeBuffer (buffer : UInt32) (offset : UInt32) (data : @& ByteArray) : IO Unit

/--
Render one frame. `draws` is packed little-endian `u32` records
`[vertexBuf, indexBuf, indexCount, uniformOffset]`; every draw binds
`uniformBuf` at its dynamic offset.
-/
@[extern "lean_gpu_render"]
opaque render (r g b : Float) (uniformBuf : UInt32) (draws : @& ByteArray) : IO Unit
end Gpu

namespace Occt
/--
Ask OpenCASCADE for a spur gear: involute flanks, extruded to `width`,
bore cut with a boolean, then meshed with `BRepMesh`.
Returns `(vertices, indices)`: interleaved `f32` position+normal, and `u32` indices.
-/
@[extern "lean_occt_gear"]
opaque gear (teeth : UInt32) (module width boreRadius pressureAngleDeg deflection : Float) :
    IO (ByteArray × ByteArray)
end Occt

end Gears
