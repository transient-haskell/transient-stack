#!/bin/bash
# Compile a transient program from its source and run it, to see it in a browser:
#   - the server (the node) with GHC,
#   - the browser side with the GHC wasm backend (the same source; BROWSER is defined for wasm),
#   - the node serves the page and the wasm: open http://<host>:<port>/ with a browser.
# usage: runapp.sh <source.hs> [arguments of the node, by default: -p start/localhost/8000]
#
# To run an example directly from its source, put in the third line of the file (see execthirdline.sh):
#   #!/usr/bin/env ../tests/execthirdline.sh
#   -- compile for ghc and wasm and run the node; open the page with a browser
#   -- ../tests/wasm/runapp.sh
# and execute  ./distributedApps.hs -p start/localhost/8000
#
# The source must export the entry point of the wasm: foreign export javascript "hs_start" main :: IO ()   (inside #if defined(wasm32_HOST_ARCH))
# Requirements: the nix shell of CLAUDE.md (it is entered by this script if it is not in it) and the wasm toolchain (~/.ghc-wasm).
# The work directory is ./.runapp-<name> (WORK=... to change it); the compilations are kept there between runs.
# The node reads the console (stdin): the menus of the program work as in any node.

SRC=$(readlink -f "${1:?usage: runapp.sh <source.hs> [node arguments]}"); shift
[ -f "$SRC" ] || { echo "no source: $SRC"; exit 1; }
D=$(cd $(dirname $0) && pwd); R=$(cd $D/../../.. && pwd)
if [ -z "$IN_NIX_SHELL" ]; then
  exec nix develop --accept-flake-config /root/cardano-node --command "$0" "$SRC" "$@"
fi
NAME=$(basename $SRC .hs); SRCDIR=$(dirname $SRC)
W=${WORK:-$PWD/.runapp-$NAME}; mkdir -p $W/srv/static/shim $W/app
ARGS=("$@"); [ ${#ARGS[@]} -eq 0 ] && ARGS=(-p start/localhost/8000)

# --- the server, with GHC
echo "== server (ghc)"
(cd $R && cabal build lib:transient lib:transient-universe > $W/srv-libs.log 2>&1) || { echo "FAIL (libs, $W/srv-libs.log)"; exit 1; }
(cd $R && cabal exec -- ghc -package transient -package transient-universe -package containers -package mtl -package bytestring \
   -package directory -package text -package vector -threaded -w -O0 -i$R/axiom/src -i$R/perch/src -i$SRCDIR \
   -outputdir $W/build-srv -o $W/node $SRC > $W/srv-build.log 2>&1) || { echo "FAIL (server, $W/srv-build.log)"; exit 1; }

# --- the browser side, with the wasm backend
echo "== browser (wasm)"
MODS=""; grep -q "import.*GHCJS.HPlay.View" $SRC && MODS="GHCJS.HPlay.View"; grep -q "import.*GHCJS.HPlay.Cell" $SRC && MODS="$MODS, GHCJS.HPlay.Cell"
OTHER=""; [ -n "$MODS" ] && OTHER="other-modules: ${MODS#, }"
cat > $W/app/app.cabal <<EOC
cabal-version: 2.4
name: app
version: 0
executable app
  main-is: $(basename $SRC)
  hs-source-dirs: $SRCDIR, $R/axiom/src
  $OTHER
  build-depends: base, transformers, containers, mtl, bytestring, directory, vector, text, transient, transient-universe, ghcjs-perch
  default-language: Haskell2010
  ghc-options: -no-hs-main -optl-mexec-model=reactor
  if arch(wasm32)
    cpp-options: -DBROWSER
    build-depends: ghc-experimental
EOC
cat > $W/cabal.project <<EOP
packages: $W/app $R/../TCache/TCache.cabal $R/transient $R/transient-universe $R/perch
EOP
(source ~/.ghc-wasm/env
 wasm32-wasi-cabal build --project-file=$W/cabal.project --builddir=$W/dist exe:app > $W/wasm-build.log 2>&1 || exit 1
 cp $(find $W/dist -name app.wasm | head -1) $W/srv/static/app.wasm
 node $(wasm32-wasi-ghc --print-libdir)/post-link.mjs --input $W/srv/static/app.wasm --output $W/srv/static/ghc_wasm_jsffi.js
 if [ ! -d $W/npm/node_modules/@bjorn3 ]; then
   mkdir -p $W/npm && cd $W/npm && npm init -y > /dev/null && npm install @bjorn3/browser_wasi_shim > npm.log 2>&1 || exit 1
 fi
 cp -r $W/npm/node_modules/@bjorn3/browser_wasi_shim/dist/* $W/srv/static/shim/) || { echo "FAIL (wasm, $W/wasm-build.log)"; exit 1; }
cp $D/browser/index.html $D/browser/loader.js $W/srv/static/

# --- run the node: it serves the page (/) and the files of ./static (/file/)
echo "== node: ${ARGS[*]}      (the page: http://<host>:<port>/)"
cd $W/srv && exec $W/node "${ARGS[@]}"
