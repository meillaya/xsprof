#!/usr/bin/env node
// Developer-only responsive evidence: console and prototype at the CSS
// breakpoints. Requires playwright-core.
const { chromium } = require("playwright-core");
const fs = require("node:fs");
const path = require("node:path");
const baseUrl = process.env.XSPROF_EVIDENCE_URL;
const token = process.env.XSPROF_EVIDENCE_TOKEN || "";
if (!baseUrl) { console.error("ui_breakpoints: XSPROF_EVIDENCE_URL is required"); process.exit(2); }
const sizes = [[1024, 768], [780, 900], [420, 900]];
const views = [["1", "overview"], ["2", "timeline"], ["3", "advisor"], ["4", "events"], ["5", "capture"]];
const root = "design/screenshots/breakpoints";
fs.mkdirSync(path.join(root, "xsprof"), { recursive: true });
fs.mkdirSync(path.join(root, "prototype"), { recursive: true });
(async () => {
  const browser = await chromium.launch({ headless: true, args: ["--use-gl=angle", "--use-angle=swiftshader", "--enable-unsafe-swiftshader", "--ignore-gpu-blocklist"] });
  for (const [width, height] of sizes) {
    const ref = await browser.newPage({ viewport: { width, height }, deviceScaleFactor: 1 });
    await ref.goto("file://" + process.cwd() + "/design/index.html");
    await ref.waitForFunction(() => !!window.XSPROF_SESSION);
    const page = await browser.newPage({ viewport: { width, height }, deviceScaleFactor: 1 });
    await page.goto(`${baseUrl}?token=${encodeURIComponent(token)}&demo=1&theme=dark&screen=overview`, { waitUntil: "networkidle" });
    await page.waitForFunction(() => window.__xsprof?.ready, { timeout: 10000 });
    for (const [key, name] of views) {
      await ref.keyboard.press(key);
      await page.keyboard.press(key);
      await page.waitForTimeout(120);
      await ref.screenshot({ path: path.join(root, "prototype", `${name}-${width}.png`) });
      await page.screenshot({ path: path.join(root, "xsprof", `${name}-${width}.png`) });
    }
    await ref.close();
    await page.close();
  }
  await browser.close();
  console.log(`ui_breakpoints: wrote ${sizes.length * views.length * 2} screenshots to ${root}`);
})().catch((error) => { console.error(error); process.exit(1); });
