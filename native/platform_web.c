// Browser platform layer. The TypeScript host (web/main.ts) queues raw DOM
// events on `Module.gearsHost`; `waitFrame` suspends the wasm stack (JSPI or
// Asyncify, via EM_ASYNC_JS) until the next requestAnimationFrame and then
// copies the queued events into a Lean FloatArray.
#include <emscripten.h>
#include <lean/lean.h>
#include <webgpu/webgpu.h>

#include "platform.h"

#define MAX_EVENTS 512

EM_JS(void, js_platform_init, (const char* title), {
  document.title = UTF8ToString(title);
  Module.gearsHost.start();
});

EM_ASYNC_JS(int, js_wait_frame, (double* out, int cap), {
  const host = Module.gearsHost;
  const t = await host.nextFrame();
  const evs = host.drain();
  const n = Math.min(evs.length, cap - 1);
  HEAPF64[out >> 3] = t;
  HEAPF64.set(evs.slice(0, n), (out >> 3) + 1);
  return 1 + n;
});

LEAN_EXPORT lean_obj_res lean_platform_init(b_lean_obj_arg title, uint32_t w, uint32_t h) {
  (void)w; (void)h;  // the canvas is sized by CSS; the host reports its size as a resize event
  js_platform_init(lean_string_cstr(title));
  return lean_io_result_mk_ok(lean_box(0));
}

LEAN_EXPORT lean_obj_res lean_platform_wait_frame(void) {
  int cap = 1 + 5 * MAX_EVENTS;
  lean_object* arr = lean_alloc_sarray(sizeof(double), 0, cap);
  int n = js_wait_frame(lean_float_array_cptr(arr), cap);
  lean_to_sarray(arr)->m_size = n;
  return lean_io_result_mk_ok(arr);
}

WGPUSurface platform_create_surface(WGPUInstance instance) {
  WGPUEmscriptenSurfaceSourceCanvasHTMLSelector canvas = WGPU_EMSCRIPTEN_SURFACE_SOURCE_CANVAS_HTML_SELECTOR_INIT;
  canvas.selector = (WGPUStringView){"#canvas", WGPU_STRLEN};
  WGPUSurfaceDescriptor sd = WGPU_SURFACE_DESCRIPTOR_INIT;
  sd.nextInChain = &canvas.chain;
  return wgpuInstanceCreateSurface(instance, &sd);
}
