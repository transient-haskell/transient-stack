#!/bin/bash
# computations in the Widget monad without rendering, in node over jsdom (usage: calc.sh)
D=$(cd $(dirname $0) && pwd); R=$D/../../..; W=$D/run-calc; rm -rf $W; mkdir -p $W
source ~/.ghc-wasm/env
cat > $W/cabal.project <<EOP
packages: $D $R/../TCache/TCache.cabal $R/transient $R/transient-universe $R/perch
EOP
wasm32-wasi-cabal build --project-file=$W/cabal.project --builddir=$W/dist exe:calc-test > $W/build.log 2>&1 || { echo "FAIL (build, $W/build.log)"; exit 1; }
cp $(find $W/dist -name calc-test.wasm | head -1) $W/calc.wasm
node $(wasm32-wasi-ghc --print-libdir)/post-link.mjs --input $W/calc.wasm --output $W/ghc_wasm_jsffi.js
cat > $W/run.mjs <<'EOJ'
import { WASI } from "node:wasi";
import fs from "node:fs";
import { JSDOM } from "jsdom";
import jsffi from "./ghc_wasm_jsffi.js";
const dom = new JSDOM("<!doctype html><html><head></head><body></body></html>", { url: "http://localhost/" });
globalThis.window = dom.window; globalThis.document = dom.window.document;
globalThis.alert = s => console.log("ALERT:", s);
const wasi = new WASI({ version: "preview1", args: ["calc"], env: {} });
const __exports = {};
const { instance } = await WebAssembly.instantiate(fs.readFileSync(process.argv[2]), { wasi_snapshot_preview1: wasi.wasiImport, ghc_wasm_jsffi: jsffi(__exports) });
Object.assign(__exports, instance.exports);
wasi.initialize(instance);
await instance.exports.hs_start();
await new Promise(r => setTimeout(r, 300));
EOJ
cd $W && npm install jsdom > npm.log 2>&1 && timeout 40 node run.mjs calc.wasm < /dev/null 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -a -E 'START|RESULT|rror' | tee node.log >/dev/null; grep -aq "RESULT Just 20" node.log && echo PASS || echo FAIL
