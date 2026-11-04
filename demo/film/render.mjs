// Offline renderer: steps the film frame by frame in the system Chrome and
// pipes JPEG frames into ffmpeg. Deterministic: frame n shows exactly n/fps.
//
//   npm i --prefix <dir> playwright-core
//   PLAYWRIGHT_CORE=<dir>/node_modules/playwright-core node demo/film/render.mjs out.mp4 [fps] [seconds]
//
// Needs Google Chrome and ffmpeg on PATH. The page loads three.js and fonts
// from their CDNs, so the first frame waits for the network.
import { spawn } from "node:child_process";
import { createRequire } from "node:module";
import { fileURLToPath, pathToFileURL } from "node:url";
import path from "node:path";

const require = createRequire(import.meta.url);
const { chromium } = require(process.env.PLAYWRIGHT_CORE || "playwright-core");
const out = process.argv[2] || "continuum-film.mp4";
const fps = Number(process.argv[3] || 30);
const seconds = Number(process.argv[4] || 180);
const here = path.dirname(fileURLToPath(import.meta.url));
const url = pathToFileURL(path.join(here, "index.html")).href + "?render=1";

const browser = await chromium.launch({ channel: "chrome", args: ["--use-angle=metal", "--ignore-gpu-blocklist"] });
const page = await browser.newPage({ viewport: { width: 1920, height: 1080 }, deviceScaleFactor: 1 });
page.on("console", (m) => { if (m.type() === "error") console.error("page:", m.text()); });
await page.goto(url, { waitUntil: "networkidle" });
await page.waitForFunction(() => typeof window.__frame === "function");
await page.evaluate(() => document.fonts.ready);

const ffmpeg = spawn("ffmpeg", ["-y", "-loglevel", "error", "-f", "image2pipe", "-framerate", String(fps), "-c:v", "mjpeg",
  "-i", "-", "-c:v", "libx264", "-preset", "slow", "-crf", "18", "-pix_fmt", "yuv420p", "-movflags", "+faststart", out],
  { stdio: ["pipe", "inherit", "inherit"] });
const total = Math.round(fps * seconds);
for (let n = 0; n < total; n++) {
  await page.evaluate(([t, dt]) => window.__frame(t, dt), [n / fps, 1 / fps]);
  const jpg = await page.screenshot({ type: "jpeg", quality: 92 });
  if (!ffmpeg.stdin.write(jpg)) await new Promise((r) => ffmpeg.stdin.once("drain", r));
  if (n % (fps * 10) === 0) console.log("frame", n, "/", total);
}
ffmpeg.stdin.end();
await new Promise((r) => ffmpeg.on("close", r));
await browser.close();
console.log("RENDERED", out);
