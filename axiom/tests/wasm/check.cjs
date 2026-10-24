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
  // checkboxes: nothing until the first event, then the latest value of each box
  cb: async page => {
    await page.waitForSelector("input[type=checkbox]", { timeout: 30000 });
    await page.locator("input[type=checkbox]").nth(0).click();
    await texts(page, 'returns: ["Red","Green"]');
  },
  get cb1() { return this.cb; }, get cb2() { return this.cb; },
  // one box: the click unchecks it
  async cb3(page) { await page.waitForSelector("input[type=checkbox]", { timeout: 30000 }); await page.locator("input[type=checkbox]").nth(0).click(); await texts(page, "returns: []"); },
  // the whole page of widgets.hs: a click in a checkbox does not delete the select nor the link
  // transient-universe/examples/distributedApps.hs: the map-reduce widget runs in the server (atRemote) and the browser shows the result
  mapreduce: async page => {
    await page.click("text=map-reduce", { timeout: 25000 });
    await page.waitForSelector("textarea", { timeout: 30000 });
    await page.fill("textarea", "a b a");
    await page.click("input[value=send]");
    await texts(page, "word a appears 2 times", "word b appears 1 times");
  },
  // links with a text after each one: the three stay and the click on one gives its value
  links: async page => {
    await texts(page, "link-a", "link-b", "link-c");
    await page.click("text=link-b");
    await texts(page, "chose: \"B\"", "link-a", "link-c");
  },
  // a text area and a button that gives its content
  area: async page => {
    await page.waitForSelector("textarea", { timeout: 30000 });
    await page.fill("textarea", "a b a");
    await page.click("input[value=send]");
    await texts(page, "got: a b a");
  },
  // the same, after a menu of links
  area2: async page => {
    await page.click("text=link-one", { timeout: 25000 });
    await page.waitForSelector("textarea", { timeout: 30000 });
    await page.fill("textarea", "a b a");
    await page.click("input[value=send]");
    await texts(page, "got: a b a 5");
  },
  // shows the page after the click on the first link (to see the html: HTML=1)
  show2: async page => { await page.click("text=link-one", { timeout: 25000 }); await page.waitForSelector("textarea", { timeout: 30000 }); await page.waitForTimeout(1500); throw new Error("show"); },
  // the chat of distributedApps: the message goes to the server, which sends it to the chatbox of the page
  chat: async page => {
    await page.click("a:has-text('chat')", { timeout: 25000 });
    await page.waitForSelector("input[size='60']", { timeout: 30000 });
    await page.fill("input[size='60']", "hello chat");
    await page.dispatchEvent("input[size='60']", "change");     // the change of the box sends the message
    await texts(page, "anonymous@localhost:", "hello chat");
  },
  // the monitor of nodes of distributedApps: the table of the nodes of the server
  monitor: async page => {
    await page.click("a:has-text('monitor nodes')", { timeout: 25000 });
    await texts(page, "Nodes connected", "localhost");
    if ((await page.locator("table tr").count()) < 1) throw new Error("no nodes in the table");
  },
  all: async page => {
    await page.waitForSelector("a", { timeout: 60000 });
    await page.locator("input[type=checkbox]").nth(0).click();
    await texts(page, 'returns: ["Red","Green"]', "This link say Hi!");
    if ((await page.locator("select").count()) !== 1) throw new Error("the select is not there");
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
  const errors = [];
  page.on("dialog", d => { console.log("ALERT", d.message().slice(0, 120)); d.dismiss(); });
  page.on("pageerror", e => console.log("PAGE ERROR", String(e).slice(0, 300)));
  page.on("console", m => { const t = m.text(); errors.push(t.replace(/\x1b\[[0-9;]*m/g, "").slice(0, 220)); });
  await page.goto(`http://localhost:${port}/`);
  let ok = true;
  try { await steps[app](page); } catch (e) { ok = false; console.log(String(e).slice(0, 200)); }
  if (!ok) errors.filter(e => e.trim()).slice(-(+process.env.CONSOLE_N || 14)).forEach(e => console.log("CONSOLE", e));
  if (!ok && process.env.HTML) console.log("HTML", (await page.innerHTML("body")).slice(0, 3000));
  console.log(ok ? "BROWSER ok" : "BROWSER fail: " + JSON.stringify((await page.innerText("body")).replace(/\n+/g, " | ")).slice(0, 700));
  await browser.close();
  process.exit(ok ? 0 : 1);
})().catch(e => { console.log("ERROR", String(e).slice(0, 400)); process.exit(1); });
