#!/bin/bash
# usage: runeverything.sh            (from anywhere, inside the nix shell: see CLAUDE.md)
#
# Runs all the distributed tests:
#   1. compiles the programs of the scenarios that kill and restart nodes (they are not in the .cabal) next to this script
#   2. runall.sh                : those scenarios, one PASS / FAIL line each
#   3. cabal test distributed   : the tests of AssertTests.hs, each one in four nodes
# The exit code is the number of scenarios and tests that did not pass. It takes about an hour.
S=$(cd $(dirname $0) && pwd)
ROOT=$(cd $S/../../.. && pwd)          # transient-stack
FAILS=0

echo "## compiling the programs of the scenarios"
cd $ROOT
cabal build --offline lib:transient lib:transient-universe || exit 255
for t in AppWait:appwait SeqFail:seqfail AppRestart:apprestart AppThree:appthree AppMore:appmore \
         MultiUser:multiuser CollectTest:collecttest RunAtRestart:runatrestart AppMinput:appminput \
         ParseSerial:parseserial AppJob:ajob; do
  src=${t%%:*}; bin=${t##*:}
  rm -f $S/$bin
  cabal exec --offline -- ghc -package transient -package transient-universe -threaded -w -O0 \
      -outputdir $S/build-$bin -o $S/$bin transient-universe/tests/$src.hs > /dev/null 2>&1
  [ -x $S/$bin ] || { echo "NOT BUILT  $bin"; FAILS=$((FAILS + 1)); }
done

echo "## scenarios (runall.sh)"
bash $S/runall.sh
FAILS=$((FAILS + $?))

echo "## tests of AssertTests.hs (cabal test distributed)"
cabal test distributed --offline --test-show-details=direct
FAILS=$((FAILS + $?))

echo "## $FAILS failures"
exit $FAILS
