#!/bin/bash
# the Axiom tests in a real browser (usage: browser-all.sh), sharing one build directory
D=$(cd $(dirname $0) && pwd); export AXIOM_DIST=${AXIOM_DIST:-$D/dist-all}
i=0; for t in static click widget form widgets; do echo "$t: $($D/browser.sh $((8780+i)) $t 2>&1 | grep -a -E "^(PASS|FAIL)" | tail -1)"; i=$((i+1)); done
