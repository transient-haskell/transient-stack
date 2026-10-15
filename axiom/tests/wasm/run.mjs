// usage: node run.mjs <file.wasm>   (jsdom in ./node_modules)
import { WASI } from "node:wasi";
import fs from "node:fs";
import { JSDOM } from "jsdom";
import jsffi from "./ghc_wasm_jsffi.js";
const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", { url: "http://localhost/" });
globalThis.window = dom.window; globalThis.document = dom.window.document;
globalThis.alert = s => console.log("ALERT:", s);   // Axiom uses alert for debugging
const wasi = new WASI({ version: "preview1", args: ["widget"], env: {} });
const __exports = {};
const { instance } = await WebAssembly.instantiate(fs.readFileSync(process.argv[2]), { wasi_snapshot_preview1: wasi.wasiImport, ghc_wasm_jsffi: jsffi(__exports) });
Object.assign(__exports, instance.exports);
wasi.initialize(instance);
instance.exports.hs_start().then(() => {}, e => console.log("hs_start threw", String(e).slice(0, 300)));
const until = async (cond, ms = 15000) => { const t0 = Date.now(); while (!cond() && Date.now() - t0 < ms) await new Promise(r => setTimeout(r, 50)); return cond(); };
const q = s => document.querySelector(s);
const rendered = await until(() => q("input[type=submit]"));
const html0 = document.body.innerHTML;
let ok = rendered;
let html1 = "";
if (rendered) {
  const box = q("input[type=text]");
  box.value = "Ana";
  q("input[type=submit]").dispatchEvent(new dom.window.Event("click", { bubbles: true }));
  ok = await until(() => document.body.innerHTML.includes("hello Ana"));
  html1 = document.body.innerHTML;
}
console.log(ok ? "PASS" : "FAIL\nbefore: " + html0 + "\nafter: " + html1);
process.exit(ok ? 0 : 1);
