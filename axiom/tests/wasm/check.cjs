// usage: node check.cjs <port> <app>   opens the node in Chromium and checks what the app (static, click, widget or form) shows
const { chromium } = require("playwright");
const [port, app] = process.argv.slice(2);
const texts = (page, ...ts) => page.waitForFunction(ts => ts.every(t => document.body.innerText.includes(t)), ts, { timeout: 15000 });
const steps = {
  // a render in every line, no events
  static: async page => { await texts(page, "one", "two 2", "three"); },
  // a button and a render after it: the click draws "clicked" and the button stays once
  click: async page => {
    await page.waitForSelector("input[type=submit]", { timeout: 30000 });
    await page.click("input[type=submit]");
    await texts(page, "clicked");
    if ((await page.locator("input[type=submit]").count()) !== 1) throw new Error("the button is not once");
  },
  // a text box that raises the event
  widget: async page => {
    await page.waitForSelector("input[type=text]", { timeout: 30000 });
    await page.fill("input[type=text]", "Ana");
    await page.dispatchEvent("input[type=text]", "change");
    await texts(page, "hello Ana");
  },
  // axiom/tests/widgets.hs as it is: the form of a Person (name, age, button "send")
  widgets: async page => {
    await page.waitForSelector("input[placeholder='Enter the name']", { timeout: 60000 });
    await page.fill("input[placeholder='Enter the name']", "Ana");
    await page.fill("input[placeholder='Enter the age (Int)']", "30");
    await page.click("input[value=send]");
    await texts(page, "input boxes returned:", "Person {name = \"Ana\", age = 30}");
  },
  // text box <** button
  form: async page => {
    await page.waitForSelector("input[type=text]", { timeout: 30000 });
    await page.fill("input[type=text]", "Ana");
    await page.click("input[type=submit]");
    await texts(page, "hello Ana");
  },
};
(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage();
  page.on("pageerror", e => console.log("PAGE ERROR", String(e).slice(0, 300)));
  await page.goto(`http://localhost:${port}/`);
  let ok = true;
  try { await steps[app](page); } catch (e) { ok = false; console.log(String(e).slice(0, 200)); }
  console.log(ok ? "BROWSER ok" : "BROWSER fail: " + (await page.content()).slice(0, 500));
  await browser.close();
  process.exit(ok ? 0 : 1);
})().catch(e => { console.log("ERROR", String(e).slice(0, 400)); process.exit(1); });
