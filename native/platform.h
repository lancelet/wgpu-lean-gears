// What gpu.c needs from the platform layer (platform_web.c / platform_macos.m).
#pragma once
#include <webgpu/webgpu.h>

WGPUSurface platform_create_surface(WGPUInstance instance);

// Event record kinds, shared with Gears/Runtime.lean and web/main.ts:
// each event is 5 doubles: kind, a, b, c, d.
enum {
  EV_RESIZE = 1,   // a = width px, b = height px
  EV_DRAG = 2,     // a = dx, b = dy (pixels)
  EV_WHEEL = 3,    // a = dx, b = dy, c = flags (1 = pinch/ctrl, 2 = discrete mouse wheel)
  EV_MAGNIFY = 4,  // a = magnification delta (native trackpad pinch)
  EV_KEY = 5,      // a = unicode code point
  EV_QUIT = 6,
};
