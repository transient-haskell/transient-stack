#!/bin/bash
# usage: runcol.sh <tag> <binary> <port>   call 1 -> restart (jobs/exec) -> call 2
S=$(cd $(dirname $0) && pwd); T=$S/run-$1; B=$2; P=$3; rm -rf $T; mkdir -p $T
c() { curl --raw -siN -m 2 ${2:+-H "Cookie: state=$2"} "http://127.0.0.1:$P/$1" > $T/last.out; }
(cd $T && sleep 30 | timeout 12 $S/$B -p start/127.0.0.1/$P/saveonexit > out1.log 2>&1 &)
sleep 4; c test/a; sleep 9
(cd $T && sleep 30 | timeout 14 $S/$B -p start/127.0.0.1/$P/jobs/exec > out2.log 2>&1 &)
sleep 5; c test/b; sleep 3
# the endpoint "results" has to exist and work after the restart: it is invoked with the session of the call that completed the
# collection (the cookie comes in the headers of the response, which curl -i shows) and the program leaves a mark when it runs. An endpoint that
# does not exist leaves none.
CB=$(grep -aoi 'state=[a-z]*' $T/last.out | head -1 | cut -d= -f2)
c results/u $CB; sleep 2
# the programs write what they collect to files (the console output of several threads gets mixed up character by character)
echo "collected: $(cat $T/collected.txt 2>/dev/null | tr -d '\n') results: $(cat $T/reached-results.txt 2>/dev/null | wc -l) called: $(cat $T/results-called.txt 2>/dev/null | wc -l)"
for r in 1 2; do echo "run$r saved=$(sed 's/\x1b\[[0-9;]*m//g' $T/out$r.log | grep -ac '^saved')"; done
