import { Renderer } from "/gl.js";

const canvas = document.getElementById("ui");
const status = document.getElementById("status");
const errorBox = document.getElementById("error");
const params = new URLSearchParams(location.search);
const token = params.get("token") || "";
const screenNames = ["Overview", "Timeline", "Advisor", "Events", "Capture"];
let screen = Math.max(0, Math.min(4, Number(params.get("screen") || 0)));
const light = params.get("theme") === "light";
let exports = null;
let renderer = null;

function fail(message) {
  errorBox.hidden = false;
  errorBox.textContent = String(message);
  status.textContent = "error";
}

function api(path) {
  return `${path}${path.includes("?") ? "&" : "?"}token=${encodeURIComponent(token)}`;
}

async function boot() {
  if (!canvas.getContext("webgl2")) throw new Error("WebGL2 is unavailable");
  renderer = new Renderer(canvas);
  await renderer.init();
  const response = await fetch("/assets/xsprof-web.wasm");
  if (!response.ok) throw new Error(`wasm: HTTP ${response.status}`);
  const { instance } = await WebAssembly.instantiateStreaming(response, {});
  exports = instance.exports;
  const memory = exports.memory;

  function size() {
    const dpr = 1; // logical-pixel v1; DPR scaling lands with the native pass
    canvas.width = Math.max(640, Math.floor(canvas.clientWidth * dpr));
    canvas.height = Math.max(360, Math.floor(canvas.clientHeight * dpr));
  }
  size();
  if (!exports.web_init(canvas.width, canvas.height)) throw new Error("UI init failed");
  if (light) exports.web_set_theme(1);

  const journal = await fetch(api("/api/journal"));
  if (!journal.ok) throw new Error(`journal: HTTP ${journal.status}`);
  const data = new TextEncoder().encode(await journal.text());
  const ptr = exports.web_alloc(data.length);
  if (!ptr) throw new Error("wasm allocation failed");
  new Uint8Array(memory.buffer, ptr, data.length).set(data);
  const ok = exports.web_load_journal(ptr, data.length);
  exports.web_free(ptr, data.length);
  if (!ok) throw new Error("journal parse failed");
  exports.web_set_screen(screen);

  function frame() {
    const count = exports.web_frame();
    const stride = exports.web_instance_stride();
    const ip = exports.web_instances_ptr();
    const ap = exports.web_atlas_ptr();
    const as = exports.web_atlas_size();
    frame.last = { count, stride, ip, ap, as };
    if (count && ip && ap) {
      renderer.draw(ip, count, stride, memory, canvas.width, canvas.height, ap, as);
    }
    status.textContent = `${screenNames[screen]} · ${count} instances · refusals=${exports.web_refusals()} caps=${exports.web_capabilities()} · host_mutation=false`;
  }
  frame();

  window.addEventListener("resize", () => {
    size();
    exports.web_resize(canvas.width, canvas.height);
    frame();
  });
  window.addEventListener("keydown", (event) => {
    if (event.key >= "1" && event.key <= "5") {
      screen = Number(event.key) - 1;
      exports.web_set_screen(screen);
      frame();
    } else if (event.key === "w") {
      exports.web_set_theme(1);
      frame();
      exports.web_set_theme(0);
    }
  });
}

boot().catch(fail);
