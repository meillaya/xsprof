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
  if (errors.length) throw new Error(`page errors: ${errors.join("; ")}`);
  const report = {
    schema: "xsprof/interactions/v1",
    copy: { pass: true, text: copied },
    brush: { pass: true, band_visible: true, zoom_changed: true },
    pass: true,
  };
  const out = "design/evidence/interactions.json";
  fs.mkdirSync(path.dirname(out), { recursive: true });
  fs.writeFileSync(out, JSON.stringify(report, null, 2) + "\n");
  console.log("ui_interactions: PASS (clipboard + brush)");
  await browser.close();
})().catch((error) => { console.error(error); process.exit(1); });
