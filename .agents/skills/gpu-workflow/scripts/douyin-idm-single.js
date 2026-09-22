const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");
const { loadPlaywright, defaultIdmWrapper } = require("./load-playwright");
const { chromium } = loadPlaywright();

const inputUrl = process.argv[2];
const outputDir = process.argv[3];
const idmWrapper = process.argv[4] || defaultIdmWrapper();
const chromePath =
  process.env.CHROME_PATH || "C:/Program Files/Google/Chrome/Application/chrome.exe";

if (!inputUrl || !outputDir) {
  console.error("Usage: node douyin-idm-single.js <douyin-url> <output-dir> [idm-wrapper]");
  process.exit(2);
}

function mediaUrl(detail) {
  const video = detail?.aweme_detail?.video;
  return [
    ...(video?.play_addr?.url_list || []),
    ...(video?.download_addr?.url_list || []),
  ].find((value) => /^https?:\/\//.test(value));
}

(async () => {
  fs.mkdirSync(outputDir, { recursive: true });
  const browser = await chromium.launch({ headless: true, executablePath: chromePath });
  const context = await browser.newContext({
    viewport: { width: 1365, height: 900 },
    userAgent:
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36",
  });
  const page = await context.newPage();
  const responsePromise = page.waitForResponse(
    (response) => response.url().includes("/aweme/v1/web/aweme/detail"),
    { timeout: 45_000 }
  );
  await page.goto(inputUrl, { waitUntil: "domcontentloaded", timeout: 90_000 });
  const response = await responsePromise;
  const detail = await response.json();
  const id = String(detail?.aweme_detail?.aweme_id || "");
  const resolved = mediaUrl(detail);
  if (!id || !resolved) throw new Error("Douyin detail response did not contain a video ID and media URL.");

  const result = spawnSync(
    "powershell.exe",
    [
      "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", idmWrapper,
      "-Url", resolved, "-OutputDir", outputDir, "-FileName", `${id}.mp4`,
      "-TimeoutSeconds", "1800",
    ],
    { encoding: "utf8", windowsHide: true, timeout: 1_900_000, maxBuffer: 4 * 1024 * 1024 }
  );
  const output = `${result.stdout || ""}\n${result.stderr || ""}`;
  const proofLine = output.split(/\r?\n/).filter((line) => line.startsWith("IDM_DOWNLOAD_RESULT=")).at(-1);
  if (result.status !== 0 || !proofLine) throw new Error(`IDM failed: ${output.slice(-1000)}`);
  const proof = JSON.parse(proofLine.slice("IDM_DOWNLOAD_RESULT=".length));
  if (!proof.success || !proof.media_verified) throw new Error("IDM media verification failed.");
  await browser.close();
  console.log(`DOUYIN_IDM_SINGLE_RESULT=${JSON.stringify({success:true,id,path:proof.path,bytes:proof.bytes})}`);
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
