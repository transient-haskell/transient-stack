#!/bin/bash
# The distributedApps example: server and browser from the same source. (based on browser.sh) An Axiom test (static, click, widget or form) in a real browser: the node (any transient node) serves the page and the wasm; Chromium
# loads it, writes in the box, clicks the button and the page shows the answer. See ../../../transient-universe/tests/wasm/README.md
# usage: browser.sh [port] [static|click|widget|form|widgets] [executable (by default the same name)]      inside the nix shell, with the wasm toolchain and Chromium for playwright installed
P=${1:-8761}; APP=${2:-mapreduce}; EXE=${3:-dapps}; SRC=${4:-$(cd $(dirname $0)/../../../transient-universe/examples && pwd)/distributedApps.hs}; D=$(cd $(dirname $0) && pwd); R=$D/../../..; U=$R/transient-universe/tests/wasm; W=$D/run-browser; rm -rf $W; mkdir -p $W/srv/static/shim
cd $R
cabal build lib:transient lib:transient-universe > $W/srv-libs.log 2>&1 || { echo "FAIL (server libs, $W/srv-libs.log)"; exit 1; }
cabal exec -- ghc -package transient -package transient-universe -package containers -package mtl -package bytestring -package directory -package text -package vector -threaded -w -O0 -i$R/axiom/src -i$R/perch/src -outputdir $W/build-srv -o $W/node $SRC > $W/srv-build.log 2>&1 || { echo "FAIL (server build, $W/srv-build.log)"; exit 1; }
(source ~/.ghc-wasm/env
 cat > $W/cabal.project <<EOP
packages: $D $R/../TCache/TCache.cabal $R/transient $R/transient-universe $R/perch
EOP
 wasm32-wasi-cabal build --project-file=$W/cabal.project --builddir=${AXIOM_DIST:-$W/dist} exe:$EXE-test > $W/wasm-build.log 2>&1 || exit 1
 cp $(find ${AXIOM_DIST:-$W/dist} -name $EXE-test.wasm | head -1) $W/srv/static/app.wasm
 node $(wasm32-wasi-ghc --print-libdir)/post-link.mjs --input $W/srv/static/app.wasm --output $W/srv/static/ghc_wasm_jsffi.js
 mkdir -p $W/npm && cd $W/npm && npm init -y > /dev/null && npm install @bjorn3/browser_wasi_shim > npm.log 2>&1 && cp -r node_modules/@bjorn3/browser_wasi_shim/dist/* $W/srv/static/shim/) || { echo "FAIL (wasm build or shim, $W)"; exit 1; }
cp $U/browser/index.html $U/browser/loader.js $W/srv/static/
# EXTRA (default 2) more server nodes of the same program, added to the main one by its menu (add: host, port, services, connect)
EXTRA=${EXTRA:-2}; ADD=""
for i in $(seq 1 $EXTRA); do
  mkdir -p $W/n$i; (cd $W/n$i && sleep 100 | timeout -s KILL 90 $W/node -p start/localhost/$((P+i)) > srv.log 2>&1 &)
  ADD="${ADD}add\nlocalhost\n$((P+i))\n\ny\n"
done
sleep 3
(cd $W/srv && (sleep 2; printf "$ADD"; sleep 100) | timeout -s KILL 90 $W/node -p start/localhost/$P > srv.log 2>&1 &)
sleep 6
(source ~/.ghc-wasm/env; export PLAYWRIGHT_BROWSERS_PATH=${PLAYWRIGHT_BROWSERS_PATH:-/root/pw-browsers} NODE_PATH=$HOME/.ghc-wasm/nodejs/lib/node_modules; timeout 60 node $D/check.cjs $P $APP > $W/browser.log 2>&1)
if grep -aq "BROWSER ok" $W/browser.log; then echo PASS; else echo "FAIL (logs in $W)"; head -5 $W/browser.log | cut -c1-300; exit 1; fi
