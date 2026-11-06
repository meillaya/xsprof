// Headless wasm gate for the visible design console. It verifies the JS/wasm
// export contract and the incremental live-append path without WebGL.
import fs from "node:fs";

const wasm = fs.readFileSync("zig-out/web/assets/xsprof-web.wasm");
const { instance } = await WebAssembly.instantiate(wasm, {});
const e = instance.exports;
const js = fs.readFileSync("web/main.js", "utf8");
const referenced = [...new Set([...js.matchAll(/exports\.(web_[A-Za-z0-9_]+)/g)].map((m) => m[1]))];
const missing = referenced.filter((name) => typeof e[name] !== "function");
if (missing.length) throw new Error(`missing wasm exports: ${missing.join(", ")}`);

function put(text) {
  const data = new TextEncoder().encode(text);
  const ptr = e.web_alloc(data.length);
  if (!ptr) throw new Error("wasm allocation failed");
  new Uint8Array(e.memory.buffer, ptr, data.length).set(data);
  return [ptr, data.length];
}

if (!e.web_ui_init(640, 480)) throw new Error("ui init failed");
e.web_ui_set_live(1);
{
  const [ptr, len] = put(fs.readFileSync("fixtures/ui/healthy.ndjson", "utf8"));
  if (!e.web_ui_load_journal(ptr, len)) throw new Error("live journal load failed");
  e.web_free(ptr, len);
}
const before = e.web_ui_event_count();
if (!before) throw new Error("live journal produced no events");
{
  const line = '{"a":16,"b":1,"c":0,"comm":"rcu_preempt","cpu":0,"event":"sched_wakeup",' +
    '"host_mutation":false,"pid":1745,"schema":"xsprof/event/v1","tid":1745,"ts_ns":999999999999}\n';
  const [ptr, len] = put(line);
  if (!e.web_ui_append_journal(ptr, len)) throw new Error("live append failed");
  e.web_free(ptr, len);
}
const after = e.web_ui_event_count();
if (after !== before + 1) throw new Error(`live append count ${after}, expected ${before + 1}`);
if (!e.web_ui_frame()) throw new Error("frame after append failed");
e.web_ui_scroll(12);
e.web_ui_pointer_leave();
if (typeof e.web_ui_screen !== "function") throw new Error("screen export missing");
for (const name of ["web_ui_a11y_ptr", "web_ui_a11y_len", "web_ui_a11y_version", "web_ui_a11y_focus", "web_ui_a11y_activate"]) {
  if (typeof e[name] !== "function") throw new Error(`${name} export missing`);
}
if (!e.web_ui_frame()) throw new Error("frame with a11y enrichment failed");
const a11yPtr = e.web_ui_a11y_ptr();
const a11yLen = e.web_ui_a11y_len();
if (!a11yPtr || !a11yLen) throw new Error("a11y json is empty");
const a11yText = new TextDecoder().decode(new Uint8Array(e.memory.buffer, a11yPtr, a11yLen));
if (!a11yText.includes("\"schema\":\"xsprof/a11y-tree/v1\"")) throw new Error("a11y schema missing");
const a11yJs = fs.readFileSync("web/a11y.js", "utf8");
if (!a11yJs.includes("syncA11y") || !a11yJs.includes("web_ui_a11y_focus")) throw new Error("a11y mirror missing");

e.web_ui_set_live(0);
{
  const [ptr, len] = put(fs.readFileSync("fixtures/ui/healthy.ndjson", "utf8"));
  if (!e.web_ui_load_journal(ptr, len)) throw new Error("replay load failed");
  e.web_free(ptr, len);
}
{
  const [ptr, len] = put('{"schema":"xsprof/event/v1","event":"marker","host_mutation":false}\n');
  if (e.web_ui_append_journal(ptr, len)) throw new Error("append accepted outside live mode");
  e.web_free(ptr, len);
}
console.log("web_ui_smoke: PASS");
