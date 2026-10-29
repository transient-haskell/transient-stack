// usage: node check-hello.cjs <port>   opens the node in Chromium and waits for the answer of the server in the websocket
const { chromium } = require("playwright");
const port = process.argv[2];
(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage();
  let got = false;
  page.on("websocket", ws => ws.on("framereceived", f => { if (String(f.payload).includes("hello from the server")) got = true; }));
  page.on("pageerror", e => console.log("PAGE ERROR", String(e).slice(0, 300)));
  page.on("requestfailed", r => console.log("REQUEST FAILED", r.url()));
  await page.goto(`http://localhost:${port}/`);
  for (let i = 0; i < 200 && !got; i++) await page.waitForTimeout(100);
  console.log(got ? "BROWSER ok" : "BROWSER no answer");
  await browser.close();
  process.exit(got ? 0 : 1);
})().catch(e => { console.log("ERROR", String(e).slice(0, 400)); process.exit(1); });
