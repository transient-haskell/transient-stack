#!/bin/bash
# usage: runcol.sh <tag> <binary> <port>   call 1 -> restart (jobs/exec) -> call 2
S=$(cd $(dirname $0) && pwd); T=$S/run-$1; B=$2; P=$3; rm -rf $T; mkdir -p $T
c() { curl --raw -sN -m 2 "http://127.0.0.1:$P/$1" > /dev/null; }
(cd $T && sleep 30 | timeout 12 $S/$B -p start/127.0.0.1/$P/saveonexit > out1.log 2>&1 &)
sleep 4; c test/a; sleep 9
(cd $T && sleep 30 | timeout 14 $S/$B -p start/127.0.0.1/$P/jobs/exec > out2.log 2>&1 &)
sleep 5; c test/b; sleep 3
for r in 1 2; do L=$(sed 's/\x1b\[[0-9;]*m//g' $T/out$r.log); echo "run$r: inputs=$(echo "$L" | grep -ac 'MINPUT RESULT') resultsEndpoint=$(echo "$L" | grep -ac 'ADDED ENDPOINT","results"') saved=$(echo "$L" | grep -ac '^saved')"; done
echo "run2 MINPUT RESULT: $(sed 's/\x1b\[[0-9;]*m//g' $T/out2.log | grep -ao 'MINPUT RESULT","[a-z]*' | tr '\n' ' ')"
