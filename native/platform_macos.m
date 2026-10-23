// macOS platform layer: a bare Cocoa window with a CAMetalLayer, no GLFW/SDL.
// There is no [NSApp run]: Lean owns the loop and calls `waitFrame`, which
// drains the NSEvent queue by hand. Frame pacing comes from the FIFO present.
#import <Cocoa/Cocoa.h>
#import <QuartzCore/CAMetalLayer.h>
#include <lean/lean.h>
#include <webgpu/webgpu.h>

#include "platform.h"

#define MAX_EVENTS 512

static double g_events[5 * MAX_EVENTS];
static int g_nevents;
static NSWindow* g_window;
static CAMetalLayer* g_layer;
static CGSize g_lastSize;

static void push(double k, double a, double b, double c, double d) {
  if (g_nevents == MAX_EVENTS) return;
  double* e = &g_events[5 * g_nevents++];
  e[0] = k; e[1] = a; e[2] = b; e[3] = c; e[4] = d;
}

@interface GearsView : NSView
@end

@implementation GearsView
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)wantsUpdateLayer { return YES; }
- (CALayer*)makeBackingLayer { return g_layer; }
- (void)mouseDragged:(NSEvent*)e { push(EV_DRAG, e.deltaX, e.deltaY, 0, 0); }
- (void)rightMouseDragged:(NSEvent*)e { push(EV_DRAG, e.deltaX, e.deltaY, 0, 0); }
- (void)scrollWheel:(NSEvent*)e {
  // Report in DOM `wheel` conventions (positive dy = scroll down) so Lean sees one format.
  if (e.hasPreciseScrollingDeltas)
    push(EV_WHEEL, -e.scrollingDeltaX, -e.scrollingDeltaY, 0, 0);
  else
    push(EV_WHEEL, -e.scrollingDeltaX * 40, -e.scrollingDeltaY * 40, 2, 0);
}
- (void)magnifyWithEvent:(NSEvent*)e { push(EV_MAGNIFY, e.magnification, 0, 0, 0); }
- (void)keyDown:(NSEvent*)e {
  if (e.isARepeat || e.characters.length == 0) return;
  push(EV_KEY, [e.characters characterAtIndex:0], 0, 0, 0);
}
@end

@interface GearsWindowDelegate : NSObject <NSWindowDelegate>
@end

@implementation GearsWindowDelegate
- (void)windowWillClose:(NSNotification*)n { (void)n; push(EV_QUIT, 0, 0, 0, 0); }
@end

static void check_resize(void) {
  NSView* v = g_window.contentView;
  CGFloat scale = g_window.backingScaleFactor;
  CGSize px = CGSizeMake(v.bounds.size.width * scale, v.bounds.size.height * scale);
  if (!CGSizeEqualToSize(px, g_lastSize)) {
    g_lastSize = px;
    g_layer.contentsScale = scale;
    push(EV_RESIZE, px.width, px.height, scale, 0);
  }
}

LEAN_EXPORT lean_obj_res lean_platform_init(b_lean_obj_arg title, uint32_t w, uint32_t h) {
  @autoreleasepool {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

    NSMenu* bar = [NSMenu new];
    NSMenuItem* appItem = [NSMenuItem new];
    [bar addItem:appItem];
    NSMenu* appMenu = [NSMenu new];
    [appMenu addItemWithTitle:@"Quit Lean Gears" action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = appMenu;
    NSApp.mainMenu = bar;

    g_layer = [CAMetalLayer layer];
    NSRect frame = NSMakeRect(0, 0, w, h);
    g_window = [[NSWindow alloc] initWithContentRect:frame
                                           styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                     NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                                             backing:NSBackingStoreBuffered
                                               defer:NO];
    g_window.title = [NSString stringWithUTF8String:lean_string_cstr(title)];
    g_window.releasedWhenClosed = NO;
    static GearsWindowDelegate* delegate;
    delegate = [GearsWindowDelegate new];
    g_window.delegate = delegate;
    GearsView* view = [[GearsView alloc] initWithFrame:frame];
    view.wantsLayer = YES;
    g_window.contentView = view;
    [g_window makeFirstResponder:view];
    [g_window center];
    [g_window makeKeyAndOrderFront:nil];
    [NSApp finishLaunching];
    [NSApp activateIgnoringOtherApps:YES];
  }
  return lean_io_result_mk_ok(lean_box(0));
}

LEAN_EXPORT lean_obj_res lean_platform_wait_frame(void) {
  @autoreleasepool {
    NSEvent* e;
    while ((e = [NSApp nextEventMatchingMask:NSEventMaskAny
                                   untilDate:[NSDate distantPast]
                                      inMode:NSDefaultRunLoopMode
                                     dequeue:YES])) {
      [NSApp sendEvent:e];
    }
    [NSApp updateWindows];
    check_resize();
    if (!g_window.visible || g_window.miniaturized) [NSThread sleepForTimeInterval:1.0 / 60];
  }
  lean_object* arr = lean_alloc_sarray(sizeof(double), 1 + 5 * g_nevents, 1 + 5 * g_nevents);
  double* out = lean_float_array_cptr(arr);
  out[0] = CACurrentMediaTime() * 1000.0;
  memcpy(out + 1, g_events, sizeof(double) * 5 * g_nevents);
  g_nevents = 0;
  return lean_io_result_mk_ok(arr);
}

WGPUSurface platform_create_surface(WGPUInstance instance) {
  WGPUSurfaceSourceMetalLayer src = WGPU_SURFACE_SOURCE_METAL_LAYER_INIT;
  src.layer = (__bridge void*)g_layer;
  WGPUSurfaceDescriptor sd = WGPU_SURFACE_DESCRIPTOR_INIT;
  sd.nextInChain = &src.chain;
  return wgpuInstanceCreateSurface(instance, &sd);
}
