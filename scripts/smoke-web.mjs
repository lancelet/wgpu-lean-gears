// Headless smoke test for the web build, via the Chrome DevTools Protocol.
// Loads the page, prints the console, sends a drag, a pinch-zoom wheel and a
// SPACE press, and saves screenshots along the way. No npm deps (Node >= 22).
//
//   node scripts/smoke-web.mjs [url] [outdir]
import { spawn } from "node:child_process";
import { mkdtempSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const url = process.argv[2] ?? "http://localhost:8000/";
const out = process.argv[3] ?? "build/smoke";
mkdirSync(out, { recursive: true });
const chrome = process.env.CHROME ?? "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const proc = spawn(chrome, [
  "--headless=new", "--enable-unsafe-webgpu", "--remote-debugging-port=9333",
  "--window-size=1000,700", `--user-data-dir=${mkdtempSync(join(tmpdir(), "gears-"))}`, "about:blank",
], { stdio: "ignore" });

let ws;
for (let i = 0; i < 50 && !ws; i++) {
  await sleep(200);
  try {
    const targets = await (await fetch("http://127.0.0.1:9333/json")).json();
    const page = targets.find((t) => t.type === "page");
    if (page) ws = new WebSocket(page.webSocketDebuggerUrl);
  } catch {}
}
await new Promise((r) => ws.addEventListener("open", r));

let id = 0;
const pending = new Map();
ws.addEventListener("message", (m) => {
  const msg = JSON.parse(m.data);
  if (msg.id && pending.has(msg.id)) { pending.get(msg.id)(msg); pending.delete(msg.id); }
  else if (msg.method === "Runtime.consoleAPICalled")
    console.log("[console]", msg.params.args.map((a) => a.value ?? a.description).join(" "));
  else if (msg.method === "Runtime.exceptionThrown")
    console.log("[exception]", msg.params.exceptionDetails.exception?.description ?? msg.params.exceptionDetails.text);
});
const send = (method, params = {}) => new Promise((r) => { const i = ++id; pending.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const shot = async (name) => {
  const r = await send("Page.captureScreenshot", { format: "png" });
  writeFileSync(join(out, name), Buffer.from(r.result.data, "base64"));
  console.log(`[smoke] wrote ${join(out, name)}`);
};
const evalJs = async (expr) => (await send("Runtime.evaluate", { expression: expr, returnByValue: true })).result.result.value;

await send("Runtime.enable");
await send("Page.enable");
await send("Page.navigate", { url });
await sleep(5000);
console.log("[smoke] status:", JSON.stringify(await evalJs("document.getElementById('status').textContent")));
await shot("1-loaded.png");

// drag to orbit
await send("Input.dispatchMouseEvent", { type: "mousePressed", x: 500, y: 350, button: "left", buttons: 1, clickCount: 1 });
for (let i = 1; i <= 10; i++)
  await send("Input.dispatchMouseEvent", { type: "mouseMoved", x: 500 + i * 15, y: 350 + i * 5, button: "left", buttons: 1 });
await send("Input.dispatchMouseEvent", { type: "mouseReleased", x: 650, y: 400, button: "left", buttons: 0, clickCount: 1 });
// pinch-zoom in (ctrl+wheel, as browsers report trackpad pinch)
for (let i = 0; i < 5; i++)
  await send("Input.dispatchMouseEvent", { type: "mouseWheel", x: 500, y: 350, deltaX: 0, deltaY: -20, modifiers: 2 });
await sleep(500);
await shot("2-orbit-zoom.png");

// SPACE pauses: two screenshots a second apart should be identical
await send("Input.dispatchKeyEvent", { type: "keyDown", key: " ", code: "Space", text: " ", windowsVirtualKeyCode: 32 });
await send("Input.dispatchKeyEvent", { type: "keyUp", key: " ", code: "Space", windowsVirtualKeyCode: 32 });
await sleep(300);
const a = (await send("Page.captureScreenshot", { format: "png" })).result.data;
await sleep(1000);
const b = (await send("Page.captureScreenshot", { format: "png" })).result.data;
console.log(`[smoke] paused frames identical: ${a === b}`);
await send("Input.dispatchKeyEvent", { type: "keyDown", key: " ", code: "Space", text: " ", windowsVirtualKeyCode: 32 });
await send("Input.dispatchKeyEvent", { type: "keyUp", key: " ", code: "Space", windowsVirtualKeyCode: 32 });
await sleep(1000);
const c = (await send("Page.captureScreenshot", { format: "png" })).result.data;
console.log(`[smoke] resumed frames differ: ${b !== c}`);

ws.close();
proc.kill();
process.exit(0);
