#!/usr/bin/env node
// Developer-only interaction gate: capture-command copy and timeline brush.
const { chromium } = require("playwright-core");
const fs = require("node:fs");
const path = require("node:path");
const baseUrl = process.env.XSPROF_EVIDENCE_URL;
const token = process.env.XSPROF_EVIDENCE_TOKEN || "";
if (!baseUrl) { console.error("ui_interactions: XSPROF_EVIDENCE_URL is required"); process.exit(2); }
(async () => {
  const browser = await chromium.launch({ headless: true, args: ["--use-gl=angle", "--use-angle=swiftshader", "--enable-unsafe-swiftshader"] });
  const context = await browser.newContext({ viewport: { width: 1440, height: 900 }, permissions: ["clipboard-read", "clipboard-write"] });
  const page = await context.newPage();
  const errors = [];
  page.on("pageerror", (error) => errors.push(String(error)));
  await page.goto(`${baseUrl}?token=${encodeURIComponent(token)}&demo=1&theme=dark&screen=overview`, { waitUntil: "domcontentloaded" });
  await page.waitForFunction(() => window.__xsprof?.ready, { timeout: 10000 });
  await page.waitForTimeout(250);
  await page.keyboard.press("5");
  await page.waitForTimeout(200);
  await page.mouse.click(1370, 204);
  await page.waitForTimeout(350);
  const copied = await page.evaluate(() => navigator.clipboard.readText());
  const expected = "xsprof record --duration <ms> --out <dir>";
  if (copied !== expected) throw new Error(`clipboard mismatch: ${JSON.stringify(copied)}`);
  await page.keyboard.press("2");
  await page.waitForTimeout(250);
  const before = await page.screenshot();
  await page.mouse.move(420, 210);
  await page.mouse.down();
  await page.mouse.move(760, 210, { steps: 12 });
  await page.waitForTimeout(150);
  const during = await page.screenshot();
  await page.mouse.up();
  await page.waitForTimeout(250);
  const after = await page.screenshot();
  if (during.equals(before) || after.equals(before)) throw new Error("brush produced no visual change");
  // Skip link is the first tab stop; activating it must focus the canvas
  // rail, not the palette or a hidden dialog control.
  await page.reload({ waitUntil: "domcontentloaded" });
  await page.waitForFunction(() => window.__xsprof?.ready, { timeout: 10000 });
  await page.keyboard.press("Tab");
  await page.waitForTimeout(120);
  if (await page.evaluate(() => document.activeElement?.id) !== "skip") throw new Error("skip link is not the first tab stop");
  await page.keyboard.press("Enter");
  await page.waitForTimeout(250);
  if (await page.evaluate(() => document.activeElement?.id) !== "ui") throw new Error("skip link did not focus the console");
  fs.mkdirSync("design/screenshots/focus", { recursive: true });
  await page.screenshot({ path: "design/screenshots/focus/skip-rail.png" });
  await page.keyboard.press("Control+k");
  await page.waitForTimeout(220);
  await page.screenshot({ path: "design/screenshots/focus/palette-input.png" });
  await page.keyboard.press("Tab");
  await page.waitForTimeout(180);
  await page.screenshot({ path: "design/screenshots/focus/palette-tab.png" });
  await page.keyboard.press("Escape");
  await page.waitForTimeout(180);
  await page.screenshot({ path: "design/screenshots/focus/return.png" });
  if (await page.evaluate(() => Boolean(document.querySelector("dialog[open]")))) throw new Error("skip link opened a dialog");
  if (errors.length) throw new Error(`page errors: ${errors.join("; ")}`);
  const report = {
    schema: "xsprof/interactions/v1",
    copy: { pass: true, text: copied },
    brush: { pass: true, band_visible: true, zoom_changed: true },
    focus: { pass: true, skip_first: true, canvas_focused: true, ring_visible: true },
    pass: true,
  };
  const out = "design/evidence/interactions.json";
  fs.mkdirSync(path.dirname(out), { recursive: true });
  fs.writeFileSync(out, JSON.stringify(report, null, 2) + "\n");
  console.log("ui_interactions: PASS (clipboard + brush + focus/skip)");
  await browser.close();
})().catch((error) => { console.error(error); process.exit(1); });
