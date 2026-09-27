#!/usr/bin/env node
// Visual evidence for a PR; prints the paths it wrote.
//   node scripts/agent/evidence.mjs --url <base> [--path /x] [--name before|after] [--video] [--seconds N] [--gif] [--mp4] [--script steps.mjs] [--out dir]
//     full-page PNGs at 400 and 1280px via the repo's own playwright; --video records webm (--gif/--mp4 need ffmpeg);
//     --script exports `default async (page) => {}`, run before the stills and during the video
import { execFileSync as ex } from "node:child_process";
import { mkdirSync, mkdtempSync, readdirSync as ls, readFileSync, renameSync } from "node:fs";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { parseArgs } from "node:util";

const B = { type: "boolean" }, S = { type: "string" };
const { values: o } = parseArgs({ options: { url: S, path: { ...S, default: "/" }, name: { ...S, default: "after" }, out: { ...S, default: join(tmpdir(), "std-evidence") },
  script: S, seconds: { ...S, default: "4" }, video: B, gif: B, mp4: B, help: B } });
if (o.help || !o.url) {
  console.log(readFileSync(new URL(import.meta.url), "utf8").split("\n").slice(1, 5).map((l) => l.slice(3)).join("\n"));
  process.exit(o.help ? 0 : 2);
}
const die = (m) => { console.error(`evidence: ${m}`); process.exit(1); };
const slug = (s) => s.replace(/[^a-z0-9]+/gi, "-").replace(/^-|-$/g, "") || "home";
mkdirSync(o.out, { recursive: true });
const written = [];

{
  const req = createRequire(join(process.cwd(), "package.json"));
  let chromium;
  for (const m of ["playwright", "@playwright/test"]) try { ({ chromium } = req(m)); break; } catch {}
  if (!chromium) die("playwright is not installed here: add it as a dev dependency, then `npx playwright install chromium`");
  const target = new URL(o.path, o.url).href, name = `${o.name}-${slug(o.path)}`;
  const steps = o.script ? (await import(pathToFileURL(resolve(o.script)).href)).default : async () => {};
  const browser = await chromium.launch();
  for (const width of [400, 1280]) {
    const page = await browser.newPage({ viewport: { width, height: width === 400 ? 860 : 800 } });
    await page.goto(target, { waitUntil: "networkidle" });
    await steps(page);
    const file = join(o.out, `${name}-${width}.png`);
    await page.screenshot({ path: file, fullPage: true });
    written.push(file);
    await page.close();
  }
  if (o.video || o.gif || o.mp4) {
    const dir = mkdtempSync(join(tmpdir(), "std-video-")), size = { width: 1280, height: 800 };
    const ctx = await browser.newContext({ viewport: size, recordVideo: { dir, size } });
    const page = await ctx.newPage();
    await page.goto(target, { waitUntil: "networkidle" });
    await steps(page);
    await page.waitForTimeout(Number(o.seconds) * 1000);
    await ctx.close();
    const webm = join(o.out, `${name}.webm`);
    renameSync(join(dir, ls(dir)[0]), webm);
    written.push(webm);
    const ff = (a, file) => { try { ex("ffmpeg", ["-loglevel", "error", "-y", "-i", webm, ...a, file]); written.push(file); } catch { console.error(`evidence: ffmpeg failed or missing; skipped ${file}`); } };
    if (o.gif) ff(["-vf", "fps=10,scale=800:-1:flags=lanczos"], webm.replace(/webm$/, "gif"));
    if (o.mp4) ff(["-c:v", "libx264", "-pix_fmt", "yuv420p", "-movflags", "+faststart"], webm.replace(/webm$/, "mp4"));
  }
  await browser.close();
}
console.log(written.join("\n"));
