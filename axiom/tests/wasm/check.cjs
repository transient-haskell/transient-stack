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
  // the other widgets of widgets.hs, all in the same page: the link, the radio buttons and the select
  widgetsmore: async page => {
    await page.waitForSelector("a", { timeout: 60000 });
    await page.click("a");
    await texts(page, "returns Hi!");
    await page.click("input[type=radio][value=red]");
    await texts(page, "returns: \"red\"");
    // an event of a widget does not delete the rendering of the others
    await texts(page, "This link say Hi!", "returns Hi!");
    await page.selectOption("select", "green");
    await page.click("select");
    await texts(page, "returns: \"green\"");
  },
  // checkboxes: the initial state and the latest value after a click
  cb: async page => {
    await texts(page, 'returns: ["Green"]');
  },
  // one box: the click unchecks it
  async cb3(page) { await this.cb(page); await page.locator("input[type=checkbox]").nth(0).click(); await texts(page, "returns: []"); },
  // two boxes: a click in the first one gives the latest value of each one
  async cb1(page) { await this.cb(page); await page.locator("input[type=checkbox]").nth(0).click(); await texts(page, 'returns: ["Red","Green"]'); },
  async cb2(page) { await this.cb(page); await page.locator("input[type=checkbox]").nth(0).click(); await texts(page, 'returns: ["Red","Green"]'); },
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
  const errors = [];
  page.on("dialog", d => { console.log("ALERT", d.message().slice(0, 120)); d.dismiss(); });
  page.on("pageerror", e => console.log("PAGE ERROR", String(e).slice(0, 300)));
  page.on("console", m => { const t = m.text(); errors.push(t.replace(/\x1b\[[0-9;]*m/g, "").slice(0, 220)); });
  await page.goto(`http://localhost:${port}/`);
  let ok = true;
  try { await steps[app](page); } catch (e) { ok = false; console.log(String(e).slice(0, 200)); }
  if (!ok) errors.slice(-14).forEach(e => console.log("CONSOLE", e));
  console.log(ok ? "BROWSER ok" : "BROWSER fail: " + JSON.stringify((await page.innerText("body")).replace(/\n+/g, " | ")).slice(0, 700));
  await browser.close();
  process.exit(ok ? 0 : 1);
})().catch(e => { console.log("ERROR", String(e).slice(0, 400)); process.exit(1); });
