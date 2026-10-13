#!/bin/bash
# usage: runboth.sh <tag> <first: n1|n0> <binary> <base port>
# The caller (n0) and the remote node (n1) are killed together while n1 waits inside the runAt; n2 stays alive.
# Both restart with their jobs; <first> is the one that restarts first.
S=$(cd $(dirname $0) && pwd); T=$S/run-$1; F=$2; B=$3; P=$4; rm -rf $T; mkdir -p $T/n0 $T/n1 $T/n2
NODES=add/127.0.0.1/$((P+1))/n/add/127.0.0.1/$((P+2))/n
export AJ_CASE=both AJ_SLOW=${AJ_SLOW:-12000000}
(cd $T/n2 && sleep 90 | timeout 80 $S/$B -p start/127.0.0.1/$((P+2)) > out.log 2>&1 &)
(cd $T/n1 && sleep 90 | timeout 10 $S/$B -p start/127.0.0.1/$((P+1))/saveonexit > out1.log 2>&1 &)
sleep 3
(cd $T/n0 && sleep 90 | timeout 7 $S/$B -p start/127.0.0.1/$P/saveonexit/$NODES/go > out1.log 2>&1 &)
sleep 12                                   # both died at t=10
r1() { (cd $T/n1 && sleep 60 | timeout 50 $S/$B -p start/127.0.0.1/$((P+1))/jobs/exec > out2.log 2>&1 &); }
r0() { (cd $T/n0 && sleep 60 | timeout 50 $S/$B -p start/127.0.0.1/$P/$NODES/jobs/exec > out2.log 2>&1 &); }
if [ $F = n1 ]; then r1; sleep 4; r0; else r0; sleep 4; r1; fi
sleep 40
clean() { sed 's/\x1b\[[0-9;]*m//g' "$@" 2>/dev/null; }
echo "first=$F"
echo "n0: CALLER AFTER JOB run1/run2: $(clean $T/n0/out1.log | grep -ac 'CALLER AFTER JOB') / $(clean $T/n0/out2.log | grep -ac 'CALLER AFTER JOB')  RESULT: $(clean $T/n0/out2.log | grep -ao 'RESULT ([0-9,]*)' | tr '\n' ';')  BACK: $(clean $T/n0/out2.log | grep -ac '^BACK')"
echo "n1: WORK run1/run2: $(clean $T/n1/out1.log | grep -ac 'WORK') / $(clean $T/n1/out2.log | grep -ac 'WORK')"
for f in n0/out2.log n1/out2.log; do echo "errors $f: $(clean $T/$f | grep -a 'ERROR\|CloudException\|ConnectionError\|xception:\|error called' | grep -v 'mmfdata\|Enter' | sort | uniq -c | head -3 | cut -c1-180 | tr '\n' '|')"; done
