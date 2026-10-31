// Headless wasm lab check. No browser or WebGL is needed: the UI draw list is
// built, but the JS renderer is not involved. Run after `zig build web`.
import fs from "node:fs";

const wasm = fs.readFileSync("zig-out/web/assets/xsprof-web.wasm");
const { instance } = await WebAssembly.instantiate(wasm, {});
const e = instance.exports;
if (!e.web_init(1280, 720)) throw new Error("wasm init failed");

function put(text) {
  const data = new TextEncoder().encode(text);
  const ptr = e.web_alloc(data.length);
  if (!ptr) throw new Error("wasm allocation failed");
  new Uint8Array(e.memory.buffer, ptr, data.length).set(data);
  return [ptr, data.length];
}

{
  const [ptr, len] = put(fs.readFileSync("fixtures/ui/healthy.ndjson", "utf8"));
  if (!e.web_load_journal(ptr, len)) throw new Error("journal load failed");
  e.web_free(ptr, len);
}
if (!e.web_frame()) throw new Error("journal frame failed");
{
  if (!e.web_generate_trace()) throw new Error("trace export failed");
  const ptr = e.web_trace_result_ptr();
  const len = e.web_trace_result_len();
  const text = new TextDecoder().decode(new Uint8Array(e.memory.buffer, ptr, len));
  if (!text.includes('"traceEvents"')) throw new Error("trace JSON missing");
}
{
  const [ptr, len] = put(fs.readFileSync("scenarios/healthy.json", "utf8"));
  if (!e.web_run_scenario(ptr, len)) throw new Error("scenario failed");
  e.web_free(ptr, len);
  const resultPtr = e.web_scenario_result_ptr();
  const resultLen = e.web_scenario_result_len();
  const text = new TextDecoder().decode(
    new Uint8Array(e.memory.buffer, resultPtr, resultLen),
  );
  if (!text.includes('"status":"passed"')) throw new Error("scenario did not pass");
  console.log("web_lab_smoke: PASS");
}
