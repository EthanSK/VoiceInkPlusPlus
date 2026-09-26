// Renders the Agent Flow promo video from scene.html.
//
// Pipeline: headless Google Chrome (via playwright-core) loads scene.html, and for every
// frame we call window.renderAt(seconds) and screenshot the 1920×1080 stage. PNG frames
// stream straight into ffmpeg's stdin, so no frame files touch the disk.
//
// Why frame-by-frame instead of screen recording: the scene has no timers or CSS
// animations, so each frame is a pure function of time. The output is identical on every
// run, never drops frames, and does not open a visible window on Ethan's Mac.
//
// Usage (from this folder, after `npm install`):
//   node render.mjs            → ../docs/assets/agentflow-promo.mp4 and the poster JPEG
//   node render.mjs --stills   → out/still-<t>.png at a few key moments, for quick QA
//   node render.mjs --scale 1  → faster 1× render (default 2× supersampling for crisp text)
//
// Requirements: Google Chrome installed (channel "chrome") and ffmpeg on PATH.

import { chromium } from "playwright-core";
import { spawn } from "node:child_process";
import { mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const assets = join(here, "..", "docs", "assets");
const videoPath = join(assets, "agentflow-promo.mp4");
const posterPath = join(assets, "agentflow-promo-poster.jpg");

const args = process.argv.slice(2);
const stillsOnly = args.includes("--stills");
const scaleIndex = args.indexOf("--scale");
// 2× device scale renders at 3840×2160 and ffmpeg downsamples with Lanczos. This gives
// noticeably cleaner small text (the XML tags) than Chrome's 1× antialiasing.
const deviceScale = scaleIndex >= 0 ? Number(args[scaleIndex + 1]) : 2;
const FPS = 30;
// The poster is the moment both references are visible in the recorder, which explains
// the product in a single still.
const POSTER_TIME = 13.2;

const browser = await chromium.launch({ channel: "chrome", headless: true });
try {
  const page = await browser.newPage({
    viewport: { width: 1920, height: 1080 },
    deviceScaleFactor: deviceScale,
  });
  await page.goto(pathToFileURL(join(here, "scene.html")).href);
  // Wait for the scene's init() plus system fonts and the icon image, so the first frame
  // is not rendered with fallback fonts or a missing logo.
  await page.waitForFunction(() => window.promoReady === true);
  await page.evaluate(async () => {
    await document.fonts.ready;
    await Promise.all([...document.images].map((img) => img.decode().catch(() => {})));
  });
  const duration = await page.evaluate(() => window.DURATION);

  const frameAt = async (seconds, type = "png") => {
    await page.evaluate((t) => window.renderAt(t), seconds);
    return page.screenshot({ type, ...(type === "jpeg" ? { quality: 88 } : {}) });
  };

  if (stillsOnly) {
    const outDir = join(here, "out");
    mkdirSync(outDir, { recursive: true });
    const times = args.filter((a) => /^\d+(\.\d+)?$/.test(a) && a !== String(deviceScale)).map(Number);
    const moments = times.length ? times : [2.6, 6.6, 8.1, 11.8, 13.2, 14.4, 18.0, 21.5, 28.5, 33];
    for (const t of moments) {
      const file = join(outDir, `still-${t.toFixed(2)}.png`);
      await page.evaluate((s) => window.renderAt(s), t);
      await page.screenshot({ path: file });
      console.log(file);
    }
  } else {
    // H.264 High profile, yuv420p and +faststart so every browser can start playback
    // before the whole file downloads. -tune animation suits flat motion graphics. No
    // audio track: the site embeds the video with controls and it is meant to be read.
    const ffmpeg = spawn(
      "ffmpeg",
      [
        "-y", "-loglevel", "error",
        "-f", "image2pipe", "-framerate", String(FPS), "-c:v", "png", "-i", "-",
        "-vf", "scale=1920:1080:flags=lanczos",
        "-c:v", "libx264", "-preset", "slow", "-tune", "animation", "-crf", "20",
        "-profile:v", "high", "-level", "4.1", "-pix_fmt", "yuv420p",
        "-movflags", "+faststart", "-an",
        videoPath,
      ],
      { stdio: ["pipe", "inherit", "inherit"] },
    );
    const ffmpegDone = new Promise((resolve, reject) => {
      ffmpeg.on("error", reject);
      ffmpeg.on("close", (code) => (code === 0 ? resolve() : reject(new Error(`ffmpeg exited ${code}`))));
    });

    const total = Math.round(duration * FPS);
    for (let f = 0; f < total; f++) {
      const png = await frameAt(f / FPS);
      // Respect pipe backpressure so memory stays flat on long renders.
      if (!ffmpeg.stdin.write(png)) await new Promise((r) => ffmpeg.stdin.once("drain", r));
      if (f % 150 === 0) console.log(`frame ${f}/${total}`);
    }
    ffmpeg.stdin.end();
    await ffmpegDone;
    console.log(videoPath);

    // Poster at 1× so the JPEG stays small; the page shows it before playback starts.
    const posterPage = await browser.newPage({ viewport: { width: 1920, height: 1080 }, deviceScaleFactor: 1 });
    await posterPage.goto(pathToFileURL(join(here, "scene.html")).href);
    await posterPage.waitForFunction(() => window.promoReady === true);
    await posterPage.evaluate(() => document.fonts.ready);
    await posterPage.evaluate((t) => window.renderAt(t), POSTER_TIME);
    await posterPage.screenshot({ path: posterPath, type: "jpeg", quality: 86 });
    console.log(posterPath);
  }
} finally {
  await browser.close();
}
