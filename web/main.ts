// The browser host. It contains no app logic: it sizes the canvas, queues raw
// input as 5-number records (see native/platform.h), and resolves one promise
// per animation frame. Lean (via platform_web.c) pulls from it in waitFrame.

declare const BUILD_ASYNC: string;  // injected by esbuild: "jspi" | "asyncify" | "auto"
// "auto" (the published site) ships both builds side by side and picks one here.

const EV_RESIZE = 1, EV_DRAG = 2, EV_WHEEL = 3, EV_MAGNIFY = 4, EV_KEY = 5;
const WHEEL_PINCH = 1, WHEEL_DISCRETE = 2;

const canvas = document.getElementById("canvas") as HTMLCanvasElement;
const status = document.getElementById("status") as HTMLElement;
const queue: number[] = [];
const push = (k: number, a = 0, b = 0, c = 0, d = 0) => { queue.push(k, a, b, c, d); };

function fail(msg: string): never {
  status.textContent = msg;
  status.classList.add("error");
  throw new Error(msg);
}

function resize() {
  const dpr = window.devicePixelRatio || 1;
  const w = Math.max(1, Math.round(canvas.clientWidth * dpr));
  const h = Math.max(1, Math.round(canvas.clientHeight * dpr));
  if (w !== canvas.width || h !== canvas.height) {
    canvas.width = w;
    canvas.height = h;
  }
  push(EV_RESIZE, w, h, dpr);
}

function installInput() {
  new ResizeObserver(resize).observe(canvas);

  canvas.addEventListener("pointerdown", (e) => canvas.setPointerCapture(e.pointerId));
  canvas.addEventListener("pointermove", (e) => {
    if (e.buttons) push(EV_DRAG, e.movementX, e.movementY);
  });

  canvas.addEventListener("wheel", (e) => {
    e.preventDefault();
    let flags = 0;
    if (e.ctrlKey) flags |= WHEEL_PINCH;  // trackpad pinch arrives as ctrl+wheel
    // Notched mouse wheels: line/page mode, or legacy wheelDelta in steps of 120.
    const legacy = (e as unknown as { wheelDeltaY?: number }).wheelDeltaY ?? 0;
    if (e.deltaMode !== 0 || (legacy !== 0 && legacy % 120 === 0 && e.deltaX === 0)) flags |= WHEEL_DISCRETE;
    const scale = e.deltaMode === 1 ? 16 : e.deltaMode === 2 ? 400 : 1;
    push(EV_WHEEL, e.deltaX * scale, e.deltaY * scale, flags);
  }, { passive: false });

  // Safari reports trackpad pinch as non-standard gesture events.
  let lastScale = 1;
  const g = canvas as unknown as { addEventListener(t: string, f: (e: any) => void): void };
  g.addEventListener("gesturestart", (e) => { e.preventDefault(); lastScale = 1; });
  g.addEventListener("gesturechange", (e) => {
    e.preventDefault();
    push(EV_MAGNIFY, e.scale / lastScale - 1);
    lastScale = e.scale;
  });

  window.addEventListener("keydown", (e) => {
    if (e.key.length !== 1 || e.metaKey || e.ctrlKey || e.repeat) return;
    if (e.key === " ") e.preventDefault();
    push(EV_KEY, e.key.codePointAt(0)!);
  });
}

const gearsHost = {
  start() { installInput(); resize(); status.textContent = ""; },
  nextFrame: () => new Promise<number>((r) => requestAnimationFrame(r)),
  drain: () => queue.splice(0),
};

async function main() {
  if (!("gpu" in navigator)) fail("This browser has no WebGPU (navigator.gpu is missing).");
  const hasJspi = "Suspending" in WebAssembly;
  const forced = new URLSearchParams(location.search).get("variant");  // ?variant=asyncify to test
  const variant = BUILD_ASYNC === "auto" ? (forced ?? (hasJspi ? "jspi" : "asyncify")) : BUILD_ASYNC;
  if (variant === "jspi" && !hasJspi)
    fail("This build needs WebAssembly JSPI (Chrome/Edge 137+, Safari 27+, Firefox 153+). " +
         "Rebuild with `make ASYNC=asyncify` for older browsers.");
  document.getElementById("variant")!.textContent = variant === "jspi" ? "JSPI" : "Asyncify";
  status.textContent = "loading Lean + OpenCASCADE…";
  // emcc's output sits next to this file, or in ./jspi/ and ./asyncify/ on the site.
  const base = BUILD_ASYNC === "auto" ? `./${variant}/` : "./";
  const url = new URL(base + "gears.js", import.meta.url).href;
  const { default: createGears } = await import(url);
  await createGears({
    canvas,
    gearsHost,
    print: (s: string) => console.log(s),
    printErr: (s: string) => console.log(s),
    onAbort: (what: unknown) => fail(`aborted: ${what}`),
  });
}

main().catch((e) => { console.error(e); if (!status.classList.contains("error")) fail(String(e)); });
