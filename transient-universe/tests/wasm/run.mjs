import { WASI } from "node:wasi";
import fs from "node:fs";
import jsffi from "./ghc_wasm_jsffi.js";
const port = process.argv[2];
globalThis.window = { location: { hostname: "localhost", port, protocol: "http:", pathname: "/" } };
const RealWS = globalThis.WebSocket;
globalThis.WebSocket = class extends RealWS {
  constructor(u){ console.log("JS: new WebSocket", u); super(u);
    this.addEventListener("message", e => console.log("JS: recv", JSON.stringify(e.data).slice(0,120)));
    this.addEventListener("error", e => console.log("JS: error", e.message));
    this.addEventListener("close", e => console.log("JS: close", e.code)); }
  send(s){ console.log("JS: send", JSON.stringify(s).slice(0,120)); super.send(s); }
};
const wasi = new WASI({ version: "preview1", args: ["hello"], env: {} });
const __exports = {};
const { instance } = await WebAssembly.instantiate(fs.readFileSync(process.argv[3]), { wasi_snapshot_preview1: wasi.wasiImport, ghc_wasm_jsffi: jsffi(__exports) });
Object.assign(__exports, instance.exports);
wasi.initialize(instance);
instance.exports.hs_start().then(() => console.log('JS: hs_start finished'), e => console.log('JS: hs_start threw', String(e).slice(0,300)));
await new Promise(r => setTimeout(r, 8000));
process.exit(0);
