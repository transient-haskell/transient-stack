#!/bin/bash
# Perch in the GHC wasm backend: builds a DOM tree with an event handler and runs it in node over jsdom.
# usage: run.sh      (needs the wasm toolchain in ~/.ghc-wasm, see ../../transient-universe/tests/wasm/README.md)
D=$(cd $(dirname $0) && pwd); W=$D/run-wasm; rm -rf $W; mkdir -p $W
source ~/.ghc-wasm/env
cat > $W/cabal.project <<EOP
packages: $D $D/..
EOP
wasm32-wasi-cabal build --project-file=$W/cabal.project --builddir=$W/dist exe:perch-test > $W/build.log 2>&1 || { echo "FAIL (build, $W/build.log)"; exit 1; }
cp $(find $W/dist -name perch-test.wasm | head -1) $W/perch-test.wasm
node $(wasm32-wasi-ghc --print-libdir)/post-link.mjs --input $W/perch-test.wasm --output $W/ghc_wasm_jsffi.js
cp $D/run.mjs $W/
(cd $W && npm install jsdom > npm.log 2>&1 && node run.mjs perch-test.wasm < /dev/null 2>&1 | grep -v -i -E 'warning')
