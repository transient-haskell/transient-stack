#!/bin/bash
# runs AfterEvent.hs against the transient of the repo (inside the nix shell, from the root of transient-stack)
D=$(cd $(dirname $0) && pwd); W=$D/run-after; rm -rf $W; mkdir -p $W
cd $D/.. && cabal build lib:transient > $W/build.log 2>&1 || { echo "FAIL (build, $W/build.log)"; exit 1; }
cabal exec -- ghc -package transient -w -O0 -threaded -outputdir $W/o -o $W/after $D/AfterEvent.hs >> $W/build.log 2>&1 || { echo "FAIL (build, $W/build.log)"; exit 1; }
(cd $W && sleep 4 | timeout -s KILL 3 ./after $W/out.txt > /dev/null 2>&1)
printf 'ma2\nRESULT2 y\nma\nRESULT hello\nmb w1\nma\nRESULT hello\nmb w2\nma\nRESULT hello\n' | cmp -s - $W/out.txt && echo PASS || { echo FAIL; cat $W/out.txt; }
