import { Renderer } from "/gl.js";

const canvas = document.getElementById("ui");
const status = document.getElementById("status");
const errorBox = document.getElementById("error");
const params = new URLSearchParams(location.search);
const token = params.get("token") || "";
const screenNames = ["Overview", "Timeline", "Advisor", "Events", "Capture"];
let screen = Math.max(0, Math.min(4, Number(params.get("screen") || 0)));
const light = params.get("theme") === "light";
const encoder = new TextEncoder();
let exports = null;
let renderer = null;
let live = false;
let paused = false;
let follow = true;
let liveSource = null;
const fileInput = document.getElementById("file");

function fail(message) {
  errorBox.hidden = false;
  errorBox.textContent = String(message);
  status.textContent = "error";
}

function api(path) {
  return `${path}${path.includes("?") ? "&" : "?"}token=${encodeURIComponent(token)}`;
}

function loadJournalText(text, resetScreen) {
  const data = encoder.encode(text);
  const ptr = data.length ? exports.web_alloc(data.length) : 0;
  if (data.length && !ptr) throw new Error("wasm allocation failed");
  if (data.length) new Uint8Array(exports.memory.buffer, ptr, data.length).set(data);
  const ok = exports.web_load_journal(ptr, data.length);
  if (ptr) exports.web_free(ptr, data.length);
  if (!ok) throw new Error("journal parse failed");
  if (!resetScreen) exports.web_set_screen(screen);
}

function frame() {
  const count = exports.web_frame();
  const stride = exports.web_instance_stride();
  const ip = exports.web_instances_ptr();
  const ap = exports.web_atlas_ptr();
  const as = exports.web_atlas_size();
  const av = exports.web_atlas_version();
  if (count && ip && ap) {
    renderer.draw(ip, count, stride, exports.memory, canvas.width, canvas.height, ap, as, av);
  }
  status.textContent = `${screenNames[screen]} · ${count} instances · refusals=${exports.web_refusals()} caps=${exports.web_capabilities()} · host_mutation=false`;
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
    const dpr = 1;
    canvas.width = Math.max(640, Math.floor(canvas.clientWidth * dpr));
    canvas.height = Math.max(360, Math.floor(canvas.clientHeight * dpr));
  }
  size();
  if (!exports.web_init(canvas.width, canvas.height)) throw new Error("UI init failed");
  if (light) exports.web_set_theme(1);

  const metaResponse = await fetch(api("/api/meta"));
  if (!metaResponse.ok) throw new Error(`meta: HTTP ${metaResponse.status}`);
  const meta = await metaResponse.json();
  live = meta.source === "live";
  if (live) exports.web_set_live(1);

  const journal = await fetch(api("/api/journal"));
  if (!journal.ok) throw new Error(`journal: HTTP ${journal.status}`);
  loadJournalText(await journal.text(), true);
  exports.web_set_screen(screen);
  frame();

  if (live) startLive();

  function stopLive() {
    if (liveSource) {
      liveSource.close();
      liveSource = null;
    }
    live = false;
    exports.web_set_live(0);
    exports.web_set_paused(0);
    exports.web_set_follow(1);
    paused = false;
    follow = true;
  }

  async function reloadLive() {
    const response = await fetch(api("/api/journal"));
    if (!response.ok) return;
    loadJournalText(await response.text(), false);
    frame();
  }

  function setPaused(value) {
    paused = value;
    exports.web_set_paused(paused ? 1 : 0);
    if (!paused) follow = true, exports.web_set_follow(1), reloadLive();
    frame();
  }

  async function openFile(file) {
    if (!file) return;
    stopLive();
    const text = await file.text();
    loadJournalText(text, true);
    exports.web_set_screen(screen);
    frame();
  }

  fileInput.addEventListener("change", () => openFile(fileInput.files[0]));
  window.addEventListener("dragover", (event) => event.preventDefault());
  window.addEventListener("drop", (event) => {
    event.preventDefault();
    openFile(event.dataTransfer.files[0]);
  });

  function startLive() {
    const source = new EventSource(api("/api/events"));
    liveSource = source;
    let pending = "";
    let timer = 0;
    function scheduleFlush() {
      if (timer) return;
      timer = setTimeout(flush, 250);
    }
    function flush() {
      timer = 0;
      if (!pending) return;
      const data = encoder.encode(pending);
      pending = "";
      const ptr = exports.web_alloc(data.length);
      if (!ptr) return;
      new Uint8Array(memory.buffer, ptr, data.length).set(data);
      exports.web_append_journal(ptr, data.length);
      exports.web_free(ptr, data.length);
      frame();
    }
    source.onmessage = (event) => {
      if (paused || !follow) return;
      pending += event.data + "\n";
      scheduleFlush();
    };
    source.addEventListener("reset", async () => {
      const response = await fetch(api("/api/journal"));
      if (!response.ok) return;
      loadJournalText(await response.text(), false);
      frame();
    });
    source.onerror = () => {
      status.textContent = "live stream reconnecting…";
    };
  }

  window.addEventListener("resize", () => {
    size();
    exports.web_resize(canvas.width, canvas.height);
    frame();
  });
  function canvasPoint(event) {
    const rect = canvas.getBoundingClientRect();
    return {
      x: (event.clientX - rect.left) * (canvas.width / Math.max(1, rect.width)),
      y: (event.clientY - rect.top) * (canvas.height / Math.max(1, rect.height)),
    };
  }

  canvas.addEventListener("pointerdown", (event) => {
    if (!exports) return;
    const point = canvasPoint(event);
    exports.web_pointer(point.x, point.y, 1, 1, 0);
    frame();
  });
  window.addEventListener("pointerup", (event) => {
    if (!exports) return;
    const point = canvasPoint(event);
    exports.web_pointer(point.x, point.y, 0, 0, 0);
  });
  canvas.addEventListener("wheel", (event) => {
    if (!exports) return;
    event.preventDefault();
    const point = canvasPoint(event);
    exports.web_pointer(point.x, point.y, 0, 0, event.deltaY);
    frame();
  }, { passive: false });
  window.addEventListener("keydown", (event) => {
    if (event.key >= "1" && event.key <= "5") {
      screen = Number(event.key) - 1;
      exports.web_set_screen(screen);
      frame();
      return;
    }
    if (event.key === "p" && live) {
      setPaused(!paused);
      return;
    }
    if (event.key === "f" && live) {
      follow = !follow;
      exports.web_set_follow(follow ? 1 : 0);
      if (follow) reloadLive();
      frame();
      return;
    }
    if (event.key === "o") {
      fileInput.click();
      return;
    }
    let key = 255;
    if (event.key === "0") key = 0;
    else if (event.key === "Escape") key = 1;
    else if (event.key === "ArrowLeft") key = 2;
    else if (event.key === "ArrowRight") key = 3;
    if (key !== 255) {
      exports.web_key(key);
      frame();
    }
  });
}

boot().catch(fail);
