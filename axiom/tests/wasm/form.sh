#!/bin/bash
# The form text box <** button in the GHC wasm backend, in node over jsdom. A pure client-side application (runBody).
# usage: run.sh     with the wasm toolchain installed (see ../../../transient-universe/tests/wasm/README.md)
D=$(cd $(dirname $0) && pwd); R=$D/../../..; W=$D/run-form; rm -rf $W; mkdir -p $W
source ~/.ghc-wasm/env
cat > $W/cabal.project <<EOP
packages: $D $R/../TCache/TCache.cabal $R/transient $R/transient-universe $R/perch
EOP
wasm32-wasi-cabal build --project-file=$W/cabal.project --builddir=${AXIOM_DIST:-$W/dist} exe:form-test > $W/build.log 2>&1 || { echo "FAIL (build, $W/build.log)"; exit 1; }
cp $(find ${AXIOM_DIST:-$W/dist} -name form-test.wasm | head -1) $W/form.wasm
node $(wasm32-wasi-ghc --print-libdir)/post-link.mjs --input $W/form.wasm --output $W/ghc_wasm_jsffi.js
cp $D/form.mjs $W/run.mjs
cd $W && npm install jsdom > npm.log 2>&1 && timeout 40 node run.mjs form.wasm < /dev/null 2>&1 | grep -v -i warning | tee node.log | tail -5
