#!/usr/bin/env node
// Developer-only headless capture of the design console. Requires
// playwright-core + Chromium in the environment; never used by zig build check.
const { chromium } = require("playwright-core");
const fs = require("node:fs");
const path = require("node:path");

const baseUrl = process.env.XSPROF_EVIDENCE_URL;
const token = process.env.XSPROF_EVIDENCE_TOKEN || "";
const outDir = process.env.XSPROF_EVIDENCE_OUT || "design/screenshots/xsprof";
if (!baseUrl) {
  console.error("ui_capture: XSPROF_EVIDENCE_URL is required");
  process.exit(2);
}
fs.mkdirSync(outDir, { recursive: true });

(async () => {
  const browser = await chromium.launch({
    headless: true,
    args: ["--use-gl=angle", "--use-angle=swiftshader", "--enable-unsafe-swiftshader", "--ignore-gpu-blocklist"],
  });
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 1 });
  const errors = [];
  page.on("pageerror", (error) => errors.push(String(error)));
  const demo = process.env.XSPROF_EVIDENCE_DEMO !== "0";
  const url = `${baseUrl}?token=${encodeURIComponent(token)}${demo ? "&demo=1" : ""}&theme=dark&screen=overview`;
  await page.goto(url, { waitUntil: "networkidle" });
  await page.waitForFunction(() => window.__xsprof?.ready, { timeout: 10000 });
  await page.waitForTimeout(250);

  const screens = [["1", "overview"], ["2", "timeline"], ["3", "advisor"], ["4", "events"], ["5", "capture"]];
  for (const [key, name] of screens) {
    await page.keyboard.press(key);
    await page.waitForTimeout(120);
    await page.screenshot({ path: path.join(outDir, `${name}-graphite.png`) });
  }
  await page.keyboard.press("1");
  const themes = [[0, "dark"], [1, "paper"], [2, "latte"], [3, "frappe"], [4, "macchiato"], [5, "mocha"]];
  for (const [index, name] of themes) {
    await page.keyboard.press("w");
    await page.waitForTimeout(60);
    await page.keyboard.press(String(index + 1));
    await page.waitForTimeout(80);
    await page.keyboard.press("Escape");
    await page.waitForTimeout(80);
    await page.screenshot({ path: path.join(outDir, `overview-${name}.png`) });
  }
  await page.keyboard.press("w");
  await page.keyboard.press("1");
  await page.keyboard.press("Escape");
  await page.keyboard.press("Control+k");
  await page.waitForTimeout(80);
  await page.screenshot({ path: path.join(outDir, "overlay-palette.png") });
  await page.keyboard.press("Escape");
  await page.keyboard.press("w");
  await page.waitForTimeout(80);
  await page.screenshot({ path: path.join(outDir, "overlay-appearance.png") });
  await page.keyboard.press("Escape");
  await page.keyboard.press("?");
  await page.waitForTimeout(80);
  await page.screenshot({ path: path.join(outDir, "overlay-help.png") });
  await page.keyboard.press("Escape");

  if (errors.length) {
    console.error("ui_capture: page errors", errors);
    process.exitCode = 1;
  }
  console.log(`ui_capture: wrote ${screens.length + themes.length + 3} screenshots to ${outDir}`);
  await browser.close();
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
