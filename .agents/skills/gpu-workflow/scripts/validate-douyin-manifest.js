const fs = require("fs");

const manifestPath = process.argv[2];
const expectedCount = Number(process.argv[3] || 0);
if (!manifestPath) {
  throw new Error("Usage: node validate-douyin-manifest.js <manifest.json> [expected-visible-count]");
}

const items = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
if (!Array.isArray(items)) {
  throw new Error("Manifest must be a JSON array.");
}

const allowedTypes = new Set(["video", "note", "article"]);
const invalid = items.filter(
  (item) => !item || !item.id || !item.url || !allowedTypes.has(item.type),
);
const uniqueIds = new Set(items.map((item) => String(item.id)));
const uniqueUrls = new Set(items.map((item) => String(item.url)));
const types = items.reduce((counts, item) => {
  counts[item.type] = (counts[item.type] || 0) + 1;
  return counts;
}, {});

const result = {
  success:
    invalid.length === 0 &&
    uniqueIds.size === items.length &&
    uniqueUrls.size === items.length &&
    (!expectedCount || items.length === expectedCount),
  expected_count: expectedCount || null,
  total: items.length,
  unique_ids: uniqueIds.size,
  unique_urls: uniqueUrls.size,
  types,
  invalid_count: invalid.length,
  manifest: manifestPath,
};

console.log(`GPU_WORKFLOW_MANIFEST_RESULT=${JSON.stringify(result)}`);
if (!result.success) process.exit(1);
