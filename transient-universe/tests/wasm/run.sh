#!/bin/bash
# The same program (Hello.hs) as server (GHC of the nix shell) and as browser (GHC wasm backend, ~/.ghc-wasm).
# The browser runs in node (stub of window.location, the WebSocket of node) and asks the server through a real websocket.
# usage: run.sh [port]      run it inside the nix shell, with the wasm toolchain installed (see README.md)
P=${1:-8600}; D=$(cd $(dirname $0) && pwd); R=$D/../../..; W=$D/run-wasm; rm -rf $W; mkdir -p $W/srv
cd $R
cabal build lib:transient lib:transient-universe > $W/srv-libs.log 2>&1 || { echo "FAIL (server libs, $W/srv-libs.log)"; exit 1; }
cabal exec -- ghc -package transient -package transient-universe -threaded -w -O0 -outputdir $W/build-srv -o $W/hello-srv $D/Hello.hs > $W/srv-build.log 2>&1 || { echo "FAIL (server build, $W/srv-build.log)"; exit 1; }
(source ~/.ghc-wasm/env
 cat > $W/cabal.project <<EOP
packages: $D $R/../TCache/TCache.cabal $R/transient $R/transient-universe
EOP
 wasm32-wasi-cabal build --project-file=$W/cabal.project --builddir=$W/dist-wasm exe:hello > $W/wasm-build.log 2>&1 || exit 1
 cp $(find $W/dist-wasm -name hello.wasm | head -1) $W/hello.wasm
 node $(wasm32-wasi-ghc --print-libdir)/post-link.mjs --input $W/hello.wasm --output $D/ghc_wasm_jsffi.js) || { echo "FAIL (wasm build, $W/wasm-build.log)"; exit 1; }
(cd $W/srv && sleep 40 | timeout 30 $W/hello-srv -p start/localhost/$P > srv.log 2>&1 &)
sleep 4
(source ~/.ghc-wasm/env; cd $D && timeout 25 node run.mjs $P $W/hello.wasm < /dev/null > $W/node.log 2>&1)
sleep 1
strip() { sed 's/\x1b\[[0-9;]*m//g' "$@"; }
if strip $W/srv/srv.log | grep -aq "SERVER: request received" && grep -aq 'JS: recv .*hello from the server' $W/node.log; then echo PASS; else echo "FAIL (logs in $W)"; exit 1; fi
