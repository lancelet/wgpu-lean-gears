// A deliberately small, handle-based slice of webgpu.h exposed to Lean.
// The same file compiles against wgpu-native (macOS) and emdawnwebgpu (web);
// the only differences are surface creation (platform_*.c/.m), how we wait for
// async adapter/device requests, and that the browser presents implicitly.
#include <lean/lean.h>
#include <webgpu/webgpu.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "platform.h"

#define MAX_BUFFERS 64
#define MSAA 4
#define UNIFORM_SIZE 160

static struct {
  WGPUInstance instance;
  WGPUAdapter adapter;
  WGPUDevice device;
  WGPUQueue queue;
  WGPUSurface surface;
  WGPUTextureFormat format;
  WGPUCompositeAlphaMode alpha;
  WGPURenderPipeline pipeline;
  WGPUBindGroupLayout bgl;
  WGPUTexture msaa, depth;
  WGPUTextureView msaaView, depthView;
  WGPUBindGroup bindGroup;
  uint32_t bindGroupBuffer;
  uint32_t width, height;
  WGPUBuffer buffers[MAX_BUFFERS];
  uint32_t nbuffers;
} G;

static WGPUStringView sv(const char* s) { return (WGPUStringView){s, WGPU_STRLEN}; }

static lean_obj_res io_error(const char* msg) {
  return lean_io_result_mk_error(lean_mk_io_user_error(lean_mk_string(msg)));
}

// --- waiting for async requests ---------------------------------------------

#ifdef __EMSCRIPTEN__
// Requires -sASYNCIFY or -sJSPI: WaitAny suspends the wasm stack until the
// browser resolves the promise.
#define CALLBACK_MODE WGPUCallbackMode_WaitAnyOnly
static void wait_for(WGPUFuture f) { wgpuInstanceWaitAny(G.instance, 1, &(WGPUFutureWaitInfo){.future = f}, UINT64_MAX); }
#else
#define CALLBACK_MODE WGPUCallbackMode_AllowProcessEvents
static volatile int g_pending;
static void wait_for(WGPUFuture f) {
  (void)f;
  while (g_pending) wgpuInstanceProcessEvents(G.instance);
}
#endif

static void on_adapter(WGPURequestAdapterStatus status, WGPUAdapter adapter, WGPUStringView msg, void* u1, void* u2) {
  (void)u2;
  if (status != WGPURequestAdapterStatus_Success) fprintf(stderr, "[gpu] adapter: %.*s\n", (int)msg.length, msg.data);
  *(WGPUAdapter*)u1 = adapter;
#ifndef __EMSCRIPTEN__
  g_pending = 0;
#endif
}

static void on_device(WGPURequestDeviceStatus status, WGPUDevice device, WGPUStringView msg, void* u1, void* u2) {
  (void)u2;
  if (status != WGPURequestDeviceStatus_Success) fprintf(stderr, "[gpu] device: %.*s\n", (int)msg.length, msg.data);
  *(WGPUDevice*)u1 = device;
#ifndef __EMSCRIPTEN__
  g_pending = 0;
#endif
}

static void on_error(WGPUDevice const* d, WGPUErrorType type, WGPUStringView msg, void* u1, void* u2) {
  (void)d; (void)u1; (void)u2;
  fprintf(stderr, "[gpu] error %d: %.*s\n", (int)type, (int)msg.length, msg.data);
}

static void on_lost(WGPUDevice const* d, WGPUDeviceLostReason reason, WGPUStringView msg, void* u1, void* u2) {
  (void)d; (void)u1; (void)u2;
  if (reason != WGPUDeviceLostReason_Destroyed)
    fprintf(stderr, "[gpu] device lost %d: %.*s\n", (int)reason, (int)msg.length, msg.data);
}

// --- init ---------------------------------------------------------------------

static WGPUTextureFormat pick_format(const WGPUSurfaceCapabilities* caps) {
  // Prefer a non-sRGB format on both platforms so colours match.
  for (size_t i = 0; i < caps->formatCount; ++i)
    if (caps->formats[i] == WGPUTextureFormat_BGRA8Unorm || caps->formats[i] == WGPUTextureFormat_RGBA8Unorm)
      return caps->formats[i];
  return caps->formats[0];
}

static int create_pipeline(const char* wgsl) {
  WGPUShaderSourceWGSL src = WGPU_SHADER_SOURCE_WGSL_INIT;
  src.code = sv(wgsl);
  WGPUShaderModuleDescriptor smd = WGPU_SHADER_MODULE_DESCRIPTOR_INIT;
  smd.nextInChain = &src.chain;
  WGPUShaderModule sm = wgpuDeviceCreateShaderModule(G.device, &smd);
  if (!sm) return 0;

  WGPUBindGroupLayoutEntry e = WGPU_BIND_GROUP_LAYOUT_ENTRY_INIT;
  e.binding = 0;
  e.visibility = WGPUShaderStage_Vertex | WGPUShaderStage_Fragment;
  e.buffer.type = WGPUBufferBindingType_Uniform;
  e.buffer.hasDynamicOffset = 1;
  e.buffer.minBindingSize = UNIFORM_SIZE;
  WGPUBindGroupLayoutDescriptor bgld = WGPU_BIND_GROUP_LAYOUT_DESCRIPTOR_INIT;
  bgld.entryCount = 1;
  bgld.entries = &e;
  G.bgl = wgpuDeviceCreateBindGroupLayout(G.device, &bgld);

  WGPUPipelineLayoutDescriptor pld = WGPU_PIPELINE_LAYOUT_DESCRIPTOR_INIT;
  pld.bindGroupLayoutCount = 1;
  pld.bindGroupLayouts = &G.bgl;
  WGPUPipelineLayout pl = wgpuDeviceCreatePipelineLayout(G.device, &pld);

  WGPUVertexAttribute attrs[2] = {
    {.format = WGPUVertexFormat_Float32x3, .offset = 0, .shaderLocation = 0},
    {.format = WGPUVertexFormat_Float32x3, .offset = 12, .shaderLocation = 1},
  };
  WGPUVertexBufferLayout vbl = WGPU_VERTEX_BUFFER_LAYOUT_INIT;
  vbl.arrayStride = 24;
  vbl.stepMode = WGPUVertexStepMode_Vertex;
  vbl.attributeCount = 2;
  vbl.attributes = attrs;

  WGPUColorTargetState target = WGPU_COLOR_TARGET_STATE_INIT;
  target.format = G.format;
  WGPUFragmentState fs = WGPU_FRAGMENT_STATE_INIT;
  fs.module = sm;
  fs.entryPoint = sv("fs");
  fs.targetCount = 1;
  fs.targets = &target;

  WGPUDepthStencilState ds = WGPU_DEPTH_STENCIL_STATE_INIT;
  ds.format = WGPUTextureFormat_Depth24Plus;
  ds.depthWriteEnabled = WGPUOptionalBool_True;
  ds.depthCompare = WGPUCompareFunction_Less;

  WGPURenderPipelineDescriptor rpd = WGPU_RENDER_PIPELINE_DESCRIPTOR_INIT;
  rpd.layout = pl;
  rpd.vertex.module = sm;
  rpd.vertex.entryPoint = sv("vs");
  rpd.vertex.bufferCount = 1;
  rpd.vertex.buffers = &vbl;
  rpd.primitive.topology = WGPUPrimitiveTopology_TriangleList;
  rpd.primitive.frontFace = WGPUFrontFace_CCW;
  rpd.primitive.cullMode = WGPUCullMode_Back;
  rpd.depthStencil = &ds;
  rpd.multisample.count = MSAA;
  rpd.fragment = &fs;
  G.pipeline = wgpuDeviceCreateRenderPipeline(G.device, &rpd);
  wgpuPipelineLayoutRelease(pl);
  wgpuShaderModuleRelease(sm);
  return G.pipeline != NULL;
}

LEAN_EXPORT lean_obj_res lean_gpu_init(b_lean_obj_arg wgsl) {
#ifdef __EMSCRIPTEN__
  WGPUInstanceFeatureName feat = WGPUInstanceFeatureName_TimedWaitAny;
  WGPUInstanceDescriptor id = WGPU_INSTANCE_DESCRIPTOR_INIT;
  id.requiredFeatureCount = 1;
  id.requiredFeatures = &feat;
  G.instance = wgpuCreateInstance(&id);
#else
  G.instance = wgpuCreateInstance(NULL);
#endif
  if (!G.instance) return io_error("wgpuCreateInstance failed");

  G.surface = platform_create_surface(G.instance);
  if (!G.surface) return io_error("could not create a surface");

  WGPURequestAdapterOptions ao = WGPU_REQUEST_ADAPTER_OPTIONS_INIT;
  ao.compatibleSurface = G.surface;
  ao.powerPreference = WGPUPowerPreference_HighPerformance;
  WGPURequestAdapterCallbackInfo aci = WGPU_REQUEST_ADAPTER_CALLBACK_INFO_INIT;
  aci.mode = CALLBACK_MODE;
  aci.callback = on_adapter;
  aci.userdata1 = &G.adapter;
#ifndef __EMSCRIPTEN__
  g_pending = 1;
#endif
  wait_for(wgpuInstanceRequestAdapter(G.instance, &ao, aci));
  if (!G.adapter) return io_error("no WebGPU adapter");

  WGPUDeviceDescriptor dd = WGPU_DEVICE_DESCRIPTOR_INIT;
  dd.label = sv("lean-gears");
  dd.uncapturedErrorCallbackInfo.callback = on_error;
  dd.deviceLostCallbackInfo.mode = WGPUCallbackMode_AllowSpontaneous;
  dd.deviceLostCallbackInfo.callback = on_lost;
  WGPURequestDeviceCallbackInfo dci = WGPU_REQUEST_DEVICE_CALLBACK_INFO_INIT;
  dci.mode = CALLBACK_MODE;
  dci.callback = on_device;
  dci.userdata1 = &G.device;
#ifndef __EMSCRIPTEN__
  g_pending = 1;
#endif
  wait_for(wgpuAdapterRequestDevice(G.adapter, &dd, dci));
  if (!G.device) return io_error("no WebGPU device");
  G.queue = wgpuDeviceGetQueue(G.device);

  WGPUSurfaceCapabilities caps = WGPU_SURFACE_CAPABILITIES_INIT;
  wgpuSurfaceGetCapabilities(G.surface, G.adapter, &caps);
  if (caps.formatCount == 0) return io_error("surface reports no formats");
  G.format = pick_format(&caps);
  G.alpha = caps.alphaModes[0];
  wgpuSurfaceCapabilitiesFreeMembers(caps);

  if (!create_pipeline(lean_string_cstr(wgsl))) return io_error("pipeline creation failed");
  fprintf(stderr, "[gpu] ready, surface format %d\n", (int)G.format);
  return lean_io_result_mk_ok(lean_box(0));
}

// --- surface ------------------------------------------------------------------

static void make_target(WGPUTextureFormat fmt, WGPUTexture* tex, WGPUTextureView* view) {
  if (*view) wgpuTextureViewRelease(*view);
  if (*tex) { wgpuTextureDestroy(*tex); wgpuTextureRelease(*tex); }
  WGPUTextureDescriptor td = WGPU_TEXTURE_DESCRIPTOR_INIT;
  td.usage = WGPUTextureUsage_RenderAttachment;
  td.size = (WGPUExtent3D){G.width, G.height, 1};
  td.format = fmt;
  td.sampleCount = MSAA;
  *tex = wgpuDeviceCreateTexture(G.device, &td);
  *view = wgpuTextureCreateView(*tex, NULL);
}

LEAN_EXPORT lean_obj_res lean_gpu_configure(uint32_t w, uint32_t h) {
  if (w == 0 || h == 0 || (w == G.width && h == G.height)) return lean_io_result_mk_ok(lean_box(0));
  G.width = w; G.height = h;
  WGPUSurfaceConfiguration sc = WGPU_SURFACE_CONFIGURATION_INIT;
  sc.device = G.device;
  sc.format = G.format;
  sc.usage = WGPUTextureUsage_RenderAttachment;
  sc.width = w;
  sc.height = h;
  sc.alphaMode = G.alpha;
  sc.presentMode = WGPUPresentMode_Fifo;
  wgpuSurfaceConfigure(G.surface, &sc);
  make_target(G.format, &G.msaa, &G.msaaView);
  make_target(WGPUTextureFormat_Depth24Plus, &G.depth, &G.depthView);
  return lean_io_result_mk_ok(lean_box(0));
}

// --- buffers ------------------------------------------------------------------

LEAN_EXPORT lean_obj_res lean_gpu_create_buffer(uint32_t usage, b_lean_obj_arg data) {
  if (G.nbuffers == MAX_BUFFERS) return io_error("out of buffer handles");
  size_t n = lean_sarray_size(data);
  if (n % 4) return io_error("buffer data must be a multiple of 4 bytes");
  WGPUBufferDescriptor bd = WGPU_BUFFER_DESCRIPTOR_INIT;
  bd.usage = (WGPUBufferUsage)usage | WGPUBufferUsage_CopyDst;
  bd.size = n ? n : 4;
  WGPUBuffer b = wgpuDeviceCreateBuffer(G.device, &bd);
  if (!b) return io_error("wgpuDeviceCreateBuffer failed");
  if (n) wgpuQueueWriteBuffer(G.queue, b, 0, lean_sarray_cptr(data), n);
  G.buffers[G.nbuffers++] = b;
  return lean_io_result_mk_ok(lean_box_uint32(G.nbuffers));
}

static WGPUBuffer buf(uint32_t h) { return (h >= 1 && h <= G.nbuffers) ? G.buffers[h - 1] : NULL; }

LEAN_EXPORT lean_obj_res lean_gpu_write_buffer(uint32_t h, uint32_t offset, b_lean_obj_arg data) {
  WGPUBuffer b = buf(h);
  if (!b) return io_error("bad buffer handle");
  wgpuQueueWriteBuffer(G.queue, b, offset, lean_sarray_cptr(data), lean_sarray_size(data) & ~(size_t)3);
  return lean_io_result_mk_ok(lean_box(0));
}

// --- frame ----------------------------------------------------------------------

static uint32_t rd32(const uint8_t* p) { uint32_t v; memcpy(&v, p, 4); return v; }

LEAN_EXPORT lean_obj_res lean_gpu_render(double r, double g, double b, uint32_t ubuf, b_lean_obj_arg draws) {
  if (!G.width) return lean_io_result_mk_ok(lean_box(0));
  if (G.bindGroupBuffer != ubuf) {
    if (G.bindGroup) wgpuBindGroupRelease(G.bindGroup);
    WGPUBindGroupEntry be = WGPU_BIND_GROUP_ENTRY_INIT;
    be.binding = 0;
    be.buffer = buf(ubuf);
    be.size = UNIFORM_SIZE;
    WGPUBindGroupDescriptor bgd = WGPU_BIND_GROUP_DESCRIPTOR_INIT;
    bgd.layout = G.bgl;
    bgd.entryCount = 1;
    bgd.entries = &be;
    G.bindGroup = wgpuDeviceCreateBindGroup(G.device, &bgd);
    G.bindGroupBuffer = ubuf;
  }

  WGPUSurfaceTexture st = WGPU_SURFACE_TEXTURE_INIT;
  wgpuSurfaceGetCurrentTexture(G.surface, &st);
  if (st.status != WGPUSurfaceGetCurrentTextureStatus_SuccessOptimal &&
      st.status != WGPUSurfaceGetCurrentTextureStatus_SuccessSuboptimal) {
    if (st.texture) wgpuTextureRelease(st.texture);
    return lean_io_result_mk_ok(lean_box(0));  // e.g. minimised; skip frame
  }
  WGPUTextureView view = wgpuTextureCreateView(st.texture, NULL);

  WGPURenderPassColorAttachment ca = WGPU_RENDER_PASS_COLOR_ATTACHMENT_INIT;
  ca.view = G.msaaView;
  ca.resolveTarget = view;
  ca.loadOp = WGPULoadOp_Clear;
  ca.storeOp = WGPUStoreOp_Discard;
  ca.clearValue = (WGPUColor){r, g, b, 1.0};
  WGPURenderPassDepthStencilAttachment da = WGPU_RENDER_PASS_DEPTH_STENCIL_ATTACHMENT_INIT;
  da.view = G.depthView;
  da.depthLoadOp = WGPULoadOp_Clear;
  da.depthStoreOp = WGPUStoreOp_Discard;
  da.depthClearValue = 1.0f;
  WGPURenderPassDescriptor rp = WGPU_RENDER_PASS_DESCRIPTOR_INIT;
  rp.colorAttachmentCount = 1;
  rp.colorAttachments = &ca;
  rp.depthStencilAttachment = &da;

  WGPUCommandEncoder enc = wgpuDeviceCreateCommandEncoder(G.device, NULL);
  WGPURenderPassEncoder pass = wgpuCommandEncoderBeginRenderPass(enc, &rp);
  wgpuRenderPassEncoderSetPipeline(pass, G.pipeline);
  const uint8_t* d = lean_sarray_cptr(draws);
  size_t n = lean_sarray_size(draws) / 16;
  for (size_t i = 0; i < n; ++i, d += 16) {
    WGPUBuffer vb = buf(rd32(d)), ib = buf(rd32(d + 4));
    uint32_t count = rd32(d + 8), off = rd32(d + 12);
    if (!vb || !ib) continue;
    wgpuRenderPassEncoderSetBindGroup(pass, 0, G.bindGroup, 1, &off);
    wgpuRenderPassEncoderSetVertexBuffer(pass, 0, vb, 0, WGPU_WHOLE_SIZE);
    wgpuRenderPassEncoderSetIndexBuffer(pass, ib, WGPUIndexFormat_Uint32, 0, WGPU_WHOLE_SIZE);
    wgpuRenderPassEncoderDrawIndexed(pass, count, 1, 0, 0, 0);
  }
  wgpuRenderPassEncoderEnd(pass);
  WGPUCommandBuffer cmd = wgpuCommandEncoderFinish(enc, NULL);
  wgpuQueueSubmit(G.queue, 1, &cmd);
#ifndef __EMSCRIPTEN__
  wgpuSurfacePresent(G.surface);  // the browser presents when we yield to rAF
#endif
  wgpuCommandBufferRelease(cmd);
  wgpuRenderPassEncoderRelease(pass);
  wgpuCommandEncoderRelease(enc);
  wgpuTextureViewRelease(view);
  wgpuTextureRelease(st.texture);
  return lean_io_result_mk_ok(lean_box(0));
}
