const fs = require("fs");
const path = require("path");
const { chromium } = require("playwright-core");

async function main() {
  const url = process.argv[2];
  const outPath = process.argv[3];
  const chromePath =
    process.env.CHROME_PATH || "C:/Program Files/Google/Chrome/Application/chrome.exe";

  if (!url || !outPath) {
    console.error("Usage: node tools/savetik_fetch.js <douyin-url> <out-json>");
    process.exit(2);
  }

  const browser = await chromium.launch({
    headless: true,
    executablePath: chromePath,
  });

  try {
    const page = await browser.newPage();
    await page.route(/google|doubleclick|googlesyndication|fundingchoices/, (route) =>
      route.abort()
    );

    await page.goto("https://savetik.co/zh-cn/douyin-downloader", {
      waitUntil: "networkidle",
      timeout: 60000,
    });

    const data = await page.evaluate(async (inputUrl) => {
      const body = new URLSearchParams({
        q: inputUrl,
        lang: "zh-cn",
        cftoken: "",
      }).toString();

      const response = await fetch("/api/ajaxSearch", {
        method: "POST",
        headers: {
          "content-type": "application/x-www-form-urlencoded; charset=UTF-8",
          "x-requested-with": "XMLHttpRequest",
        },
        body,
      });

      const json = await response.json();
      const container = document.createElement("div");
      container.innerHTML = json.data || "";

      const links = Array.from(container.querySelectorAll("a"))
        .map((anchor) => ({
          text: anchor.innerText.trim().replace(/\s+/g, " "),
          href: anchor.href,
          className: anchor.className,
        }))
        .filter((link) => link.href.includes("dl.snapcdn.app/get"));

      return {
        status: json.status,
        message: json.msg || "",
        transcript: container.querySelector("h3")?.innerText || "",
        duration: container.querySelector("h3 + p")?.innerText || "",
        thumbnail: container.querySelector(".image-tik img")?.src || "",
        links,
      };
    }, url);

    fs.mkdirSync(path.dirname(outPath), { recursive: true });
    fs.writeFileSync(outPath, JSON.stringify(data, null, 2), "utf8");
    console.log(JSON.stringify({
      status: data.status,
      duration: data.duration,
      transcriptChars: data.transcript.length,
      links: data.links.map((link) => link.text),
    }, null, 2));
  } finally {
    await browser.close();
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
