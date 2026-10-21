#!/bin/bash
# Hello.hs in a real browser: the node (the server) serves the page; Chromium loads the wasm from it, and the program asks the server
# through the websocket. Needs Chromium for playwright: `playwright install chromium` (in /root/pw-browsers) and its libraries.
# usage: browser.sh [port]      inside the nix shell, with the wasm toolchain installed (see README.md)
P=${1:-8700}; D=$(cd $(dirname $0) && pwd); R=$D/../../..; W=$D/run-browser; rm -rf $W; mkdir -p $W/srv/static/shim
cd $R
cabal build lib:transient lib:transient-universe > $W/srv-libs.log 2>&1 || { echo "FAIL (server libs, $W/srv-libs.log)"; exit 1; }
cabal exec -- ghc -package transient -package transient-universe -threaded -w -O0 -outputdir $W/build-srv -o $W/hello-srv $D/Hello.hs > $W/srv-build.log 2>&1 || { echo "FAIL (server build, $W/srv-build.log)"; exit 1; }
(source ~/.ghc-wasm/env
 cat > $W/cabal.project <<EOP
packages: $D $R/../TCache/TCache.cabal $R/transient $R/transient-universe
EOP
 wasm32-wasi-cabal build --project-file=$W/cabal.project --builddir=$W/dist-wasm exe:hello > $W/wasm-build.log 2>&1 || exit 1
 cp $(find $W/dist-wasm -name hello.wasm | head -1) $W/srv/static/app.wasm
 node $(wasm32-wasi-ghc --print-libdir)/post-link.mjs --input $W/srv/static/app.wasm --output $W/srv/static/ghc_wasm_jsffi.js
 mkdir -p $W/npm && cd $W/npm && npm init -y > /dev/null && npm install @bjorn3/browser_wasi_shim > npm.log 2>&1 && cp -r node_modules/@bjorn3/browser_wasi_shim/dist/* $W/srv/static/shim/) || { echo "FAIL (wasm build or shim, $W)"; exit 1; }
cp $D/browser/index.html $D/browser/loader.js $W/srv/static/
(cd $W/srv && sleep 60 | timeout -s KILL 50 $W/hello-srv -p start/localhost/$P > srv.log 2>&1 &)
sleep 4
(source ~/.ghc-wasm/env; export PLAYWRIGHT_BROWSERS_PATH=${PLAYWRIGHT_BROWSERS_PATH:-/root/pw-browsers} NODE_PATH=$HOME/.ghc-wasm/nodejs/lib/node_modules; timeout 40 node $D/browser/check-hello.cjs $P > $W/browser.log 2>&1)
sleep 1
if sed 's/\x1b\[[0-9;]*m//g' $W/srv/srv.log | grep -aq "SERVER: request received" && grep -aq "BROWSER ok" $W/browser.log; then echo PASS; else echo "FAIL (logs in $W)"; cat $W/browser.log | head -5; exit 1; fi
