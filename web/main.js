import { Renderer } from "/gl.js";

const canvas = document.getElementById("ui");
const errorBox = document.getElementById("boot-error");
const status = document.getElementById("status");
const fileInput = document.getElementById("file");
const params = new URLSearchParams(location.search);
const token = params.get("token") || "";
const encoder = new TextEncoder();
const screens = { overview: 0, timeline: 1, advisor: 2, events: 3, capture: 4 };
const themes = { dark: 0, graphite: 0, paper: 1, light: 1, latte: 2, frappe: 3, macchiato: 4, mocha: 5 };
let exports = null;
let renderer = null;
let live = false;
let source = null;
let last = performance.now();
let raf = 0;
let busy = false;
let loadGeneration = 0;

function fail(error) {
  errorBox.hidden = false;
  errorBox.textContent = String(error && error.stack ? error.stack : error);
  status.textContent = "error";
}

function api(path) {
  return `${path}${path.includes("?") ? "&" : "?"}token=${encodeURIComponent(token)}`;
}

function setStatus(text) {
  status.textContent = text;
}

function resize() {
  if (!exports) return;
  const w = Math.max(320, Math.floor(canvas.clientWidth || window.innerWidth));
  const h = Math.max(240, Math.floor(canvas.clientHeight || window.innerHeight));
  if (canvas.width !== w || canvas.height !== h) {
    canvas.width = w;
    canvas.height = h;
    exports.web_ui_resize(w, h);
  }
}

function drawFrame() {
  if (!exports) return;
  const count = exports.web_ui_frame();
  const stride = exports.web_ui_instance_stride();
  const ip = exports.web_ui_instances_ptr();
  const ap = exports.web_ui_atlas_ptr();
  const as = exports.web_ui_atlas_size();
  const av = exports.web_ui_atlas_version();
  if (count && ip && ap) {
    renderer.draw(ip, count, stride, exports.memory, canvas.width, canvas.height, ap, as, av);
  }
  setStatus(`console · ${count} instances · host_mutation=false`);

  if (exports.web_ui_take_open()) fileInput.click();
  if (exports.web_ui_take_reload()) reloadSource();
  flushCopy();
}

function flushCopy() {
  const len = exports?.web_ui_copy_len?.() || 0;
  if (!len) return;
  const ptr = exports.web_ui_copy_ptr();
  const text = new TextDecoder().decode(new Uint8Array(exports.memory.buffer, ptr, len));
  exports.web_ui_copy_clear();
  if (navigator.clipboard?.writeText) {
    navigator.clipboard.writeText(text).catch(() => {});
  }
}

function loadJournalText(text, label) {
  const data = encoder.encode(text);
  const ptr = data.length ? exports.web_alloc(data.length) : 0;
  if (data.length && !ptr) throw new Error("wasm allocation failed");
  if (data.length) new Uint8Array(exports.memory.buffer, ptr, data.length).set(data);
  const ok = exports.web_ui_load_journal(ptr, data.length);
  if (ptr) exports.web_free(ptr, data.length);
  if (!ok) throw new Error("journal parse failed");
  setStatus(`${label} loaded`);
}

async function loadRecorderMetadata() {
  try {
    const response = await fetch(api("/api/recorder"));
    if (!response.ok) return;
    const data = encoder.encode(await response.text());
    const ptr = data.length ? exports.web_alloc(data.length) : 0;
    if (data.length && !ptr) return;
    if (data.length) new Uint8Array(exports.memory.buffer, ptr, data.length).set(data);
    exports.web_ui_load_recorder(ptr, data.length);
    if (ptr) exports.web_free(ptr, data.length);
  } catch (error) {
    console.warn("recorder metadata unavailable", error);
  }
}

function loadDemoText(text) {
  const data = encoder.encode(text);
  const ptr = data.length ? exports.web_alloc(data.length) : 0;
  if (data.length && !ptr) throw new Error("wasm allocation failed");
  if (data.length) new Uint8Array(exports.memory.buffer, ptr, data.length).set(data);
  const ok = exports.web_ui_load_demo(ptr, data.length);
  if (ptr) exports.web_free(ptr, data.length);
  if (!ok) throw new Error("demo model parse failed");
}

async function reloadSource() {
  if (source === "demo") {
    const response = await fetch("/assets/design-demo.json");
    if (!response.ok) throw new Error(`demo: HTTP ${response.status}`);
    loadDemoText(await response.text());
    drawFrame();
    return;
  }
  const response = await fetch(api("/api/journal"));
  if (!response.ok) throw new Error(`journal: HTTP ${response.status}`);
  loadJournalText(await response.text(), live ? "live journal" : "journal");
  await loadRecorderMetadata();
  drawFrame();
}

async function boot() {
  canvas.focus();
  if (!canvas.getContext("webgl2")) throw new Error("WebGL2 is unavailable in this browser");
  renderer = new Renderer(canvas);
  await renderer.init();
  const response = await fetch("/assets/xsprof-web.wasm");
  if (!response.ok) throw new Error(`wasm: HTTP ${response.status}`);
  const { instance } = await WebAssembly.instantiateStreaming(response, {});
  exports = instance.exports;
  window.__xsprof = { exports, renderer, drawFrame: () => drawFrame(), stop: () => cancelAnimationFrame(raf), ready: false };
  resize();
  if (!exports.web_ui_init(canvas.width, canvas.height)) throw new Error("UI init failed");

  const initialScreen = screens[String(params.get("screen") || "overview")] ?? 0;
  exports.web_ui_set_screen(initialScreen);
  const initialTheme = themes[String(params.get("theme") || "dark")] ?? 0;
  exports.web_ui_set_theme(initialTheme);

  const metaResponse = await fetch(api("/api/meta"));
  if (!metaResponse.ok) throw new Error(`meta: HTTP ${metaResponse.status}`);
  const meta = await metaResponse.json();
  live = meta.source === "live";
  if (params.get("demo") === "1") live = false;
  exports.web_ui_set_live(live ? 1 : 0);
  source = live ? "live" : "journal";

  if (params.get("demo") === "1") {
    try {
      const demoResponse = await fetch("/assets/design-demo.json");
      if (demoResponse.ok) {
        loadDemoText(await demoResponse.text());
        source = "demo";
      } else {
        const journal = await fetch(api("/api/journal"));
        if (!journal.ok) throw new Error(`journal: HTTP ${journal.status}`);
        loadJournalText(await journal.text(), "journal");
      }
    } catch (error) {
      console.warn("demo model unavailable, falling back to journal", error);
      const journal = await fetch(api("/api/journal"));
      if (journal.ok) loadJournalText(await journal.text(), "journal");
    }
  } else {
    const journal = await fetch(api("/api/journal"));
    if (!journal.ok) throw new Error(`journal: HTTP ${journal.status}`);
    loadJournalText(await journal.text(), live ? "live journal" : "journal");
  }

  if (source !== "demo") await loadRecorderMetadata();
  drawFrame();
  window.__xsprof.ready = true;
  if (live) startLive();
  requestAnimationFrame(loop);
}

function loop(now) {
  raf = requestAnimationFrame(loop);
  if (!exports || busy) return;
  const dt = Math.min(100, Math.max(0, now - last));
  last = now;
  exports.web_ui_tick(Math.floor(dt));
  drawFrame();
}

function startLive() {
  if (!live || typeof EventSource === "undefined") return;
  let timer = 0;
  let pending = false;
  const events = new EventSource(api("/api/events"));
  const schedule = () => {
    pending = true;
    if (timer) return;
    timer = setTimeout(async () => {
      timer = 0;
      if (!pending || busy) return;
      pending = false;
      busy = true;
      try {
        await reloadSource();
      } catch (error) {
        console.warn(error);
      } finally {
        busy = false;
      }
    }, 300);
  };
  events.onmessage = schedule;
  events.addEventListener("reset", schedule);
  events.onerror = () => setStatus("live stream reconnecting…");
  window.addEventListener("pagehide", () => events.close(), { once: true });
}

function canvasPoint(event) {
  const rect = canvas.getBoundingClientRect();
  return {
    x: (event.clientX - rect.left) * (canvas.width / Math.max(1, rect.width)),
    y: (event.clientY - rect.top) * (canvas.height / Math.max(1, rect.height)),
  };
}

let down = null;
canvas.addEventListener("pointerdown", (event) => {
  if (!exports) return;
  const point = canvasPoint(event);
  down = { ...point, id: event.pointerId };
  exports.web_ui_pointer_down(point.x, point.y);
  canvas.setPointerCapture?.(event.pointerId);
});
canvas.addEventListener("pointermove", (event) => {
  if (!exports || !down) return;
  const point = canvasPoint(event);
  exports.web_ui_pointer_move(point.x, point.y);
  drawFrame();
});
canvas.addEventListener("pointerup", (event) => {
  if (!exports || !down) return;
  const point = canvasPoint(event);
  exports.web_ui_pointer_up(point.x, point.y);
  down = null;
  drawFrame();
});
canvas.addEventListener("pointercancel", () => {
  down = null;
});

function keyCode(event) {
  switch (event.key) {
    case "ArrowUp": return 0x11;
    case "ArrowDown": return 0x12;
    case "ArrowLeft": return 0x13;
    case "ArrowRight": return 0x14;
    case "Escape": return 0x1b;
    case "Enter": return 0x0a;
    case "Backspace": return 0x7f;
    case "Tab": return 0;
    default:
      if (event.key.length === 1) return event.key.codePointAt(0);
      return 0;
  }
}

window.addEventListener("keydown", (event) => {
  if (!exports) return;
  if (event.key === "Tab") return;
  const cp = keyCode(event);
  if (!cp) return;
  const meta = event.metaKey || event.ctrlKey;
  if (meta || cp === 32 || cp === 0x1b || cp === 0x11 || cp === 0x12 || cp === 0x13 || cp === 0x14) {
    event.preventDefault();
  }
  exports.web_ui_key(cp, event.metaKey ? 1 : 0, event.ctrlKey ? 1 : 0, event.shiftKey ? 1 : 0);
  drawFrame();
}, { passive: false });

canvas.addEventListener("wheel", (event) => {
  if (!exports) return;
  event.preventDefault();
  const delta = Math.max(-120, Math.min(120, event.deltaY)) * 0.8;
  exports.web_ui_scroll(delta);
  drawFrame();
}, { passive: false });

fileInput.addEventListener("change", async () => {
  const file = fileInput.files?.[0];
  if (!file) return;
  busy = true;
  try {
    exports.web_ui_set_live(0);
    loadJournalText(await file.text(), file.name);
    source = "journal";
    drawFrame();
  } catch (error) {
    fail(error);
  } finally {
    fileInput.value = "";
    busy = false;
  }
});

window.addEventListener("dragover", (event) => event.preventDefault());
window.addEventListener("drop", async (event) => {
  event.preventDefault();
  const file = event.dataTransfer?.files?.[0];
  if (!file || !exports) return;
  busy = true;
  try {
    exports.web_ui_set_live(0);
    exports.web_ui_set_live(0);
    loadJournalText(await file.text(), file.name);
    source = "journal";
    drawFrame();
  } catch (error) {
    fail(error);
  } finally {
    busy = false;
  }
});

let resizeTimer = 0;
window.addEventListener("resize", () => {
  if (resizeTimer) clearTimeout(resizeTimer);
  resizeTimer = setTimeout(() => {
    resizeTimer = 0;
    resize();
    drawFrame();
  }, 80);
});

boot().catch(fail);
