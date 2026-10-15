#!/bin/bash
# widgets with rendering and without events, in node over jsdom (usage: static.sh)
D=$(cd $(dirname $0) && pwd); R=$D/../../..; W=$D/run-static; rm -rf $W; mkdir -p $W
source ~/.ghc-wasm/env
cat > $W/cabal.project <<EOP
packages: $D $R/../TCache/TCache.cabal $R/transient $R/transient-universe $R/perch
EOP
wasm32-wasi-cabal build --project-file=$W/cabal.project --builddir=$W/dist exe:static-test > $W/build.log 2>&1 || { echo "FAIL (build, $W/build.log)"; exit 1; }
cp $(find $W/dist -name static-test.wasm | head -1) $W/static.wasm
node $(wasm32-wasi-ghc --print-libdir)/post-link.mjs --input $W/static.wasm --output $W/ghc_wasm_jsffi.js
cat > $W/run.mjs <<'EOJ'
import { WASI } from "node:wasi";
import fs from "node:fs";
import { JSDOM } from "jsdom";
import jsffi from "./ghc_wasm_jsffi.js";
const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", { url: "http://localhost/" });
globalThis.window = dom.window; globalThis.document = dom.window.document;
globalThis.alert = s => {};
const wasi = new WASI({ version: "preview1", args: ["static"], env: {} });
const __exports = {};
const { instance } = await WebAssembly.instantiate(fs.readFileSync(process.argv[2]), { wasi_snapshot_preview1: wasi.wasiImport, ghc_wasm_jsffi: jsffi(__exports) });
Object.assign(__exports, instance.exports);
wasi.initialize(instance);
await instance.exports.hs_start();
await new Promise(r => setTimeout(r, 500));
const ps = [...document.body.querySelectorAll("p")].map(p => p.textContent).join("|");
console.log("BODY " + document.body.innerHTML);
console.log("TEXTS " + ps);
EOJ
cd $W && npm install jsdom > npm.log 2>&1 && timeout 40 node run.mjs static.wasm < /dev/null 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -a -E '^(BODY|TEXTS)' | tee node.log | cut -c1-300
grep -aq "TEXTS one|two 2|three" node.log && echo PASS || echo FAIL
