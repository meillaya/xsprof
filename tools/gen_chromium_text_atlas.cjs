#!/usr/bin/env node
// Developer-only generator for browser-matched text masks. Requires Playwright
// and ffmpeg. Produces lib/xsui/assets/fonts/chromium_text_atlas.bin.
const { chromium } = require("playwright-core");
const { execFileSync } = require("node:child_process");
const fs = require("node:fs");
const path = require("node:path");

const ROOT = path.resolve(__dirname, "..");
const OUT = path.join(ROOT, "lib/xsui/assets/fonts/chromium_text_atlas.bin");
const SIZES = [8.5, 9, 9.5, 10, 10.5, 11, 12, 12.5, 13, 14, 15, 16, 18, 20, 22, 27, 28, 34];
const WEIGHTS = [400, 700];
const SYMBOLS = "→←↑↓·—–…“”‘’−×✓●○◐■□↔⌘⏎⌫";
const PHASE_X = [0, 0.25, 0.5, 0.75];
const PHASE_Y = [0, 0.5];
const CELL_W = 48, CELL_H = 56, COLS = 15, ROWS = 10;
const BOARD_W = CELL_W * COLS * 2;
const BOARD_H = CELL_H * ROWS * 4;

function cps() {
  const out = [];
  for (let cp = 32; cp <= 126; cp += 1) out.push(cp);
  for (const ch of SYMBOLS) out.push(ch.codePointAt(0));
  return [...new Set(out)].sort((a, b) => a - b);
}

function decodePng(png) {
  return execFileSync("ffmpeg", ["-v", "error", "-f", "png_pipe", "-i", "-", "-f", "rawvideo", "-pix_fmt", "rgba", "-"], {
    input: png,
    maxBuffer: 64 * 1024 * 1024,
  });
}

(async () => {
  const browser = await chromium.launch({ headless: true });
  const page = await browser.newPage({ viewport: { width: BOARD_W, height: BOARD_H }, deviceScaleFactor: 1 });
  await page.goto("file://" + path.join(ROOT, "design/index.html"));
  await page.waitForFunction(() => !!window.XSPROF_SESSION);
  await page.evaluate(() => document.fonts.ready);

  const chars = cps();
  const records = [];
  const chunks = [];
  let pixelBytes = 0;
  for (const size of SIZES) {
    for (const weight of WEIGHTS) {
      const metrics = await page.evaluate(({ size, weight }) => {
        const c = document.createElement("canvas").getContext("2d");
        c.font = `${weight} ${size}px "JetBrains Mono", ui-monospace, monospace`;
        const m = c.measureText("Mg");
        return { asc: m.fontBoundingBoxAscent, desc: m.fontBoundingBoxDescent };
      }, { size, weight });
      const lineHeight = 38;
      const baselineInLine = (lineHeight - (metrics.asc + metrics.desc)) / 2 + metrics.asc;
            await page.evaluate(({ chars, size, weight, phaseX, phaseY, cellW, cellH, cols, rows, baselineInLine, boardW, boardH }) => {
        document.body.innerHTML = "";
        document.documentElement.style.cssText = "margin:0;padding:0;background:transparent;overflow:hidden;";
        document.body.style.cssText = `margin:0;padding:0;width:${boardW}px;height:${boardH}px;background:transparent;overflow:hidden;`;
        const board = document.createElement("div");
        board.style.cssText = `position:relative;width:${boardW}px;height:${boardH}px;background:transparent;`;
        document.body.appendChild(board);
        for (let yi = 0; yi < phaseY.length; yi += 1) {
          const glyphTop = 38 + phaseY[yi] - baselineInLine;
          for (let xi = 0; xi < phaseX.length; xi += 1) {
            const phase = xi | (yi << 2);
            const gx = (phase % 2) * (cellW * cols);
            const gy = Math.floor(phase / 2) * (cellH * rows);
            for (let i = 0; i < chars.length; i += 1) {
              const cx = gx + (i % cols) * cellW;
              const cy = gy + Math.floor(i / cols) * cellH;
              const cell = document.createElement("div");
              cell.style.cssText = `position:absolute;left:${cx}px;top:${cy}px;width:${cellW}px;height:${cellH}px;overflow:visible;`;
              const span = document.createElement("span");
              span.textContent = String.fromCodePoint(chars[i]);
              span.style.cssText = `position:absolute;left:${8 + phaseX[xi]}px;top:${glyphTop}px;` +
                `line-height:${38}px;height:${38}px;font-family:"JetBrains Mono",ui-monospace,monospace;` +
                `font-size:${size}px;font-weight:${weight};font-style:normal;color:#fff;white-space:pre;` +
                `-webkit-font-smoothing:antialiased;text-rendering:auto;`;
              cell.appendChild(span);
              board.appendChild(cell);
            }
          }
        }
      }, { chars, size, weight, phaseX: PHASE_X, phaseY: PHASE_Y, cellW: CELL_W, cellH: CELL_H, cols: COLS, rows: ROWS, baselineInLine, boardW: BOARD_W, boardH: BOARD_H });
      const png = await page.screenshot({ omitBackground: true, animations: "disabled" });
      const rgba = decodePng(png);
      for (let yi = 0; yi < PHASE_Y.length; yi += 1) {
        for (let xi = 0; xi < PHASE_X.length; xi += 1) {
          const phase = xi | (yi << 2);
          const gx = (phase % 2) * (CELL_W * COLS);
          const gy = Math.floor(phase / 2) * (CELL_H * ROWS);
          for (let i = 0; i < chars.length; i += 1) {
            const cx = gx + (i % COLS) * CELL_W;
            const cy = gy + Math.floor(i / COLS) * CELL_H;
            let minX = CELL_W, minY = CELL_H, maxX = -1, maxY = -1;
            for (let y = 0; y < CELL_H; y += 1) {
              for (let x = 0; x < CELL_W; x += 1) {
                if (rgba[((cy + y) * BOARD_W + cx + x) * 4 + 3] !== 0) {
                  if (x < minX) minX = x;
                  if (x > maxX) maxX = x;
                  if (y < minY) minY = y;
                  if (y > maxY) maxY = y;
                }
              }
            }
            if (maxX < minX) continue;
            const w = maxX - minX + 1, h = maxY - minY + 1;
            const pixels = Buffer.alloc(w * h);
            for (let y = 0; y < h; y += 1) {
              for (let x = 0; x < w; x += 1) {
                pixels[y * w + x] = rgba[((cy + minY + y) * BOARD_W + cx + minX + x) * 4 + 3];
              }
            }
            records.push({ cp: chars[i], sizeQ: Math.round(size * 16), weight, phase, left: minX - 8, top: minY - 38, width: w, height: h, offset: pixelBytes });
            chunks.push(pixels);
            pixelBytes += pixels.length;
          }
        }
      }
      process.stderr.write(`rendered ${size}/${weight}: ${records.length} masks\n`);
    }
  }
  const header = Buffer.alloc(28);
  header.write("XSTA", 0, 4, "ascii");
  header.writeUInt16LE(1, 4);
  header.writeUInt16LE(4096, 6);
  header.writeUInt16LE(4096, 8);
  header.writeUInt32LE(records.length, 10);
  header.writeUInt32LE(28, 14);
  header.writeUInt32LE(28 + records.length * 24, 18);
  header.writeUInt32LE(pixelBytes, 22);
  const entry = Buffer.alloc(records.length * 24);
  records.forEach((r, i) => {
    const at = i * 24;
    entry.writeUInt32LE(r.cp, at);
    entry.writeUInt16LE(r.sizeQ, at + 4);
    entry.writeUInt16LE(r.weight === 700 ? 1 : 0, at + 6);
    entry.writeUInt8(r.phase, at + 8);
    entry.writeInt16LE(r.left, at + 10);
    entry.writeInt16LE(r.top, at + 12);
    entry.writeUInt16LE(r.width, at + 14);
    entry.writeUInt16LE(r.height, at + 16);
    entry.writeUInt32LE(r.offset, at + 18);
  });
  fs.mkdirSync(path.dirname(OUT), { recursive: true });
  fs.writeFileSync(OUT, Buffer.concat([header, entry, ...chunks]));
  const meta = {
    schema: "xsprof/chromium-text-atlas/v1",
    source: "design/index.html",
    renderer: "dom-screenshot",
    chromium: browser.version(),
    atlas: 4096,
    masks: records.length,
    phasesX: PHASE_X,
    phasesY: PHASE_Y,
    sizes: SIZES,
    weights: WEIGHTS,
    symbols: SYMBOLS,
    bytes: fs.statSync(OUT).size,
  };
  fs.writeFileSync(OUT.replace(/\.bin$/, ".json"), JSON.stringify(meta, null, 2) + "\n");
  console.log(`chromium text atlas: ${records.length} masks, ${meta.bytes} bytes -> ${OUT}`);
  await browser.close();
})().catch((error) => { console.error(error); process.exit(1); });
