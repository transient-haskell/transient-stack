#!/bin/bash
# the four tests of Axiom in wasm, sharing one build directory (usage: all.sh)
D=$(cd $(dirname $0) && pwd); export AXIOM_DIST=${AXIOM_DIST:-$D/dist-all}
for t in calc static click run form; do echo "$t: $($D/$t.sh 2>&1 | tail -1)"; done
