#!/usr/bin/env node
// Developer-only headless boot/use recording. Requires playwright-core.
const { chromium } = require("playwright-core");
const fs = require("node:fs");
const path = require("node:path");

const baseUrl = process.env.XSPROF_EVIDENCE_URL;
const token = process.env.XSPROF_EVIDENCE_TOKEN || "";
const out = process.env.XSPROF_EVIDENCE_VIDEO || "design/media/xsprof-ui-demo.webm";
if (!baseUrl) {
  console.error("ui_record: XSPROF_EVIDENCE_URL is required");
  process.exit(2);
}
fs.mkdirSync(path.dirname(out), { recursive: true });
const dir = fs.mkdtempSync("/tmp/xsprof-video-");

(async () => {
  const browser = await chromium.launch({
    headless: true,
    args: ["--use-gl=angle", "--use-angle=swiftshader", "--enable-unsafe-swiftshader", "--ignore-gpu-blocklist"],
  });
  const context = await browser.newContext({
    viewport: { width: 1440, height: 900 },
    deviceScaleFactor: 1,
    recordVideo: { dir, size: { width: 1440, height: 900 } },
  });
  const page = await context.newPage();
  const errors = [];
  page.on("pageerror", (error) => errors.push(String(error)));
  const demo = process.env.XSPROF_EVIDENCE_DEMO !== "0";
  await page.goto(`${baseUrl}?token=${encodeURIComponent(token)}${demo ? "&demo=1" : ""}&theme=dark&screen=overview`, { waitUntil: "networkidle" });
  await page.waitForFunction(() => window.__xsprof?.ready, { timeout: 10000 });
  await page.waitForTimeout(1200);
  await page.keyboard.press("2"); await page.waitForTimeout(400);
  await page.mouse.move(420, 210); await page.mouse.down();
  await page.mouse.move(760, 210, { steps: 18 }); await page.waitForTimeout(220);
  await page.mouse.up(); await page.waitForTimeout(500);
  await page.keyboard.press("f"); await page.waitForTimeout(250);
  await page.keyboard.press(" "); await page.waitForTimeout(2400);
  await page.keyboard.press(" "); await page.waitForTimeout(300);
  await page.keyboard.press("3"); await page.waitForTimeout(900);
  await page.keyboard.press("4"); await page.waitForTimeout(700);
  await page.keyboard.press("/"); await page.waitForTimeout(150);
  await page.keyboard.type("worker"); await page.waitForTimeout(800);
  await page.keyboard.press("Escape"); await page.waitForTimeout(300);
  await page.keyboard.press("Control+k"); await page.waitForTimeout(700);
  await page.keyboard.press("Escape"); await page.waitForTimeout(250);
  await page.keyboard.press("w"); await page.waitForTimeout(650);
  await page.keyboard.press("6"); await page.waitForTimeout(800);
  await page.keyboard.press("Escape"); await page.waitForTimeout(600);
  await page.keyboard.press("5"); await page.waitForTimeout(1800);
  await page.keyboard.press("?"); await page.waitForTimeout(900);
  await page.keyboard.press("Escape"); await page.waitForTimeout(250);
  await page.keyboard.press("4"); await page.waitForTimeout(900);
  await page.keyboard.press("1"); await page.waitForTimeout(500);
  if (errors.length) console.error("ui_record: page errors", errors);
  await context.close();
  await browser.close();
  const files = fs.readdirSync(dir).filter((name) => name.endsWith(".webm"));
  if (!files.length) throw new Error("ui_record: no video written");
  fs.copyFileSync(path.join(dir, files[0]), out);
  console.log(`ui_record: wrote ${out}`);
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
