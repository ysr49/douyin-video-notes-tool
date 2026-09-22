const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");
const { loadPlaywright, defaultIdmWrapper } = require("./load-playwright");
const { chromium } = loadPlaywright();

const manifestPath = process.argv[2];
const outputDir = process.argv[3];
const statePath = process.argv[4];
const idmWrapper = process.argv[5] || defaultIdmWrapper();
const maxNewDownloads = Number(process.argv[6] || 0);
const transcriptionStatePath = process.argv[7] || "";
const chromePath =
  process.env.CHROME_PATH || "C:/Program Files/Google/Chrome/Application/chrome.exe";

if (!manifestPath || !outputDir || !statePath) {
  console.error(
    "Usage: node douyin-idm-author-download.js <manifest.json> <output-dir> <download-state.json> [idm-wrapper] [max-new-downloads] [transcription-state.json]"
  );
  process.exit(2);
}

function saveJson(filePath, value) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  const temporary = `${filePath}.tmp`;
  fs.writeFileSync(temporary, `${JSON.stringify(value, null, 2)}\n`, "utf8");
  fs.renameSync(temporary, filePath);
}

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, "utf8").replace(/^\uFEFF/, ""));
}

function loadState() {
  if (!fs.existsSync(statePath)) {
    return { started_at: new Date().toISOString(), items: {} };
  }
  return readJson(statePath);
}

function loadFinalizedIds() {
  if (!transcriptionStatePath || !fs.existsSync(transcriptionStatePath)) {
    return new Set();
  }
  const state = readJson(transcriptionStatePath);
  const finalized = new Set();
  for (const [id, item] of Object.entries(state.items || {})) {
    if (!item?.gpu_verified) continue;
    const outputs = Array.isArray(item.outputs) ? item.outputs : [];
    const valid = [".txt", ".srt", ".vtt"].every((extension) =>
      outputs.some((output) => {
        try {
          return (
            path.extname(String(output)).toLowerCase() === extension &&
            fs.statSync(output).isFile() &&
            fs.statSync(output).size > 0
          );
        } catch {
          return false;
        }
      }),
    );
    if (valid) finalized.add(String(id));
  }
  return finalized;
}

function resolvedMediaUrl(detail) {
  const video = detail?.aweme_detail?.video || detail?.awemeDetail?.video;
  const candidates = [
    ...(video?.play_addr?.url_list || []),
    ...(video?.download_addr?.url_list || []),
  ];
  return candidates.find((value) => /^https?:\/\//.test(value)) || "";
}

function runIdm(url, id) {
  const result = spawnSync(
    "powershell.exe",
    [
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      idmWrapper,
      "-Url",
      url,
      "-OutputDir",
      outputDir,
      "-FileName",
      `${id}.mp4`,
      "-TimeoutSeconds",
      "1800",
    ],
    {
      encoding: "utf8",
      windowsHide: true,
      timeout: 1_900_000,
      maxBuffer: 4 * 1024 * 1024,
    }
  );
  const output = `${result.stdout || ""}\n${result.stderr || ""}`;
  const proofLine = output
    .split(/\r?\n/)
    .filter((line) => line.startsWith("IDM_DOWNLOAD_RESULT="))
    .at(-1);
  if (result.status !== 0 || !proofLine) {
    throw new Error(`IDM failed with exit code ${result.status}: ${output.slice(-1000)}`);
  }
  const proof = JSON.parse(proofLine.slice("IDM_DOWNLOAD_RESULT=".length));
  if (!proof.success || !proof.media_verified) {
    throw new Error("IDM returned without verified media proof.");
  }
  return proof;
}

(async () => {
  const raw = readJson(manifestPath);
  const allItems = Array.isArray(raw) ? raw : raw.items || raw.posts || [];
  let items = allItems
    .filter((item) => item.type === "video" || /\/video\/\d+/.test(item.url || ""))
    .map((item) => ({
      id: String(item.id || item.aweme_id || (item.url || "").match(/\/video\/(\d+)/)?.[1] || ""),
      url: item.url,
    }))
    .filter((item) => item.id && item.url);
  fs.mkdirSync(outputDir, { recursive: true });
  const state = loadState();
  const finalizedIds = loadFinalizedIds();
  let downloadedThisRun = 0;
  state.source_manifest = path.resolve(manifestPath);
  state.output_dir = path.resolve(outputDir);
  state.total = items.length;

  const browser = await chromium.launch({ headless: true, executablePath: chromePath });
  const context = await browser.newContext({
    viewport: { width: 1365, height: 900 },
    userAgent:
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36",
  });
  const page = await context.newPage();

  for (let index = 0; index < items.length; index += 1) {
    const item = items[index];
    const previous = state.items[item.id];
    if (finalizedIds.has(item.id)) {
      console.log(`[${index + 1}/${items.length}] ${item.id} finalized`);
      continue;
    }
    if (previous?.success && fs.existsSync(previous.path || "")) {
      console.log(`[${index + 1}/${items.length}] ${item.id} reused`);
      continue;
    }
    if (maxNewDownloads > 0 && downloadedThisRun >= maxNewDownloads) {
      break;
    }
    try {
      const responsePromise = page.waitForResponse(
        (response) =>
          response.url().includes("/aweme/v1/web/aweme/detail") &&
          response.url().includes(`aweme_id=${item.id}`),
        { timeout: 45_000 }
      );
      await page.goto(item.url, { waitUntil: "domcontentloaded", timeout: 90_000 });
      const response = await responsePromise;
      const detail = await response.json();
      const mediaUrl = resolvedMediaUrl(detail);
      if (!mediaUrl) throw new Error("Resolved detail response has no media URL.");
      const proof = runIdm(mediaUrl, item.id);
      state.items[item.id] = {
        success: true,
        path: proof.path,
        bytes: proof.bytes,
        duration_seconds: proof.probe?.duration_seconds,
        completed_at: new Date().toISOString(),
      };
      downloadedThisRun += 1;
      console.log(
        `[${index + 1}/${items.length}] ${item.id} ok bytes=${proof.bytes} duration=${proof.probe?.duration_seconds}`
      );
    } catch (error) {
      state.items[item.id] = {
        success: false,
        error: String(error?.message || error).slice(0, 2000),
        failed_at: new Date().toISOString(),
      };
      console.error(`[${index + 1}/${items.length}] ${item.id} failed: ${error.message}`);
    }
    state.completed = Object.values(state.items).filter((item) => item.success).length;
    state.failed = Object.values(state.items).filter((item) => !item.success).length;
    state.updated_at = new Date().toISOString();
    saveJson(statePath, state);
  }

  await browser.close();
  state.completed = Object.values(state.items).filter((item) => item.success).length;
  state.failed = Object.values(state.items).filter((item) => !item.success).length;
  state.finished_at = new Date().toISOString();
  saveJson(statePath, state);
  console.log(
    `DOUYIN_IDM_BATCH_RESULT=${JSON.stringify({
      success: state.failed === 0 && state.completed === items.length,
      total: items.length,
      completed: state.completed,
      failed: state.failed,
      downloaded_this_run: downloadedThisRun,
      finalized: finalizedIds.size,
      state: path.resolve(statePath),
    })}`
  );
  process.exitCode = state.failed === 0 ? 0 : 1;
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
