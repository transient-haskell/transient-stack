#!/bin/bash
# An Axiom widget (text box + button) in the GHC wasm backend, in node over jsdom. A pure client-side application (runBody).
# usage: run.sh     with the wasm toolchain installed (see ../../../transient-universe/tests/wasm/README.md)
D=$(cd $(dirname $0) && pwd); R=$D/../../..; W=$D/run-wasm; rm -rf $W; mkdir -p $W
source ~/.ghc-wasm/env
cat > $W/cabal.project <<EOP
packages: $D $R/../TCache/TCache.cabal $R/transient $R/transient-universe $R/perch
EOP
wasm32-wasi-cabal build --project-file=$W/cabal.project --builddir=$W/dist exe:widget-test > $W/build.log 2>&1 || { echo "FAIL (build, $W/build.log)"; exit 1; }
cp $(find $W/dist -name widget-test.wasm | head -1) $W/widget.wasm
node $(wasm32-wasi-ghc --print-libdir)/post-link.mjs --input $W/widget.wasm --output $W/ghc_wasm_jsffi.js
cp $D/run.mjs $W/
cd $W && npm install jsdom > npm.log 2>&1 && timeout 40 node run.mjs widget.wasm < /dev/null 2>&1 | grep -v -i warning | tee node.log | tail -5
