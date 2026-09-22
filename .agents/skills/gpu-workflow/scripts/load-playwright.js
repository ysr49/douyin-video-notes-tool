const fs = require("fs");
const path = require("path");

function loadPlaywright() {
  const candidates = [];
  if (process.env.PLAYWRIGHT_CORE_PATH) {
    candidates.push(process.env.PLAYWRIGHT_CORE_PATH);
  }
  const repoRoot = path.resolve(__dirname, "..", "..", "..", "..");
  candidates.push(path.join(repoRoot, "node_modules", "playwright-core"));
  candidates.push(path.join(process.cwd(), "node_modules", "playwright-core"));
  for (const candidate of candidates) {
    try {
      if (candidate && fs.existsSync(candidate)) {
        return require(candidate);
      }
    } catch {
      // try the next candidate
    }
  }
  return require("playwright-core");
}

function defaultIdmWrapper() {
  return path.resolve(
    __dirname,
    "..",
    "..",
    "idm-download",
    "scripts",
    "idm-download.ps1"
  );
}

module.exports = { loadPlaywright, defaultIdmWrapper };
