#!/bin/bash
# usage: runajob.sh <tag> <case> <victim: n2|n0> <binary> <base port>
# n1 and n2 run the program; the victim is killed by timeout (saveonexit) during the slow part and restarted with jobs/exec.
S=$(cd $(dirname $0) && pwd); T=$S/run-$1; C=$2; V=$3; B=$4; P=$5; rm -rf $T; mkdir -p $T/n0 $T/n1 $T/n2
NODES=add/127.0.0.1/$((P+1))/n/add/127.0.0.1/$((P+2))/n
t2=60; t0=60; [ $V = n2 ] && t2=10; [ $V = n0 ] && t0=10
(cd $T/n1 && sleep 80 | timeout 60 $S/$B -p start/127.0.0.1/$((P+1)) > out.log 2>&1 &)
(cd $T/n2 && sleep 80 | timeout $t2 $S/$B -p start/127.0.0.1/$((P+2))/saveonexit > out1.log 2>&1 &)
sleep 3
(cd $T/n0 && sleep 80 | AJ_CASE=$C timeout $t0 $S/$B -p start/127.0.0.1/$P/saveonexit/$NODES/go > out1.log 2>&1 &)
sleep 12
if [ $V = n2 ]; then (cd $T/n2 && sleep 60 | AJ_CASE=$C timeout 35 $S/$B -p start/127.0.0.1/$((P+2))/jobs/exec > out2.log 2>&1 &); fi
if [ $V = n0 ]; then (cd $T/n0 && sleep 60 | AJ_CASE=$C timeout 35 $S/$B -p start/127.0.0.1/$P/$NODES/jobs/exec > out2.log 2>&1 &); fi
sleep 30
clean() { sed 's/\x1b\[[0-9;]*m//g' "$@" 2>/dev/null; }
echo "case=$C victim=$V"
echo "n0 RESULT: $(clean $T/n0/out1.log $T/n0/out2.log | grep -ao 'RESULT ([0-9,]*)' | tr '\n' ';') BACK: $(clean $T/n0/out1.log $T/n0/out2.log | grep -ac '^BACK')"
echo "WORK n1: $(clean $T/n1/out.log | grep -ac 'WORK\|TERM') n2 run1: $(clean $T/n2/out1.log | grep -ac 'WORK\|TERM') n2 run2: $(clean $T/n2/out2.log | grep -ac 'WORK\|TERM')  caller after-job: $(clean $T/n0/out1.log | grep -ac 'CALLER AFTER JOB') / $(clean $T/n0/out2.log | grep -ac 'CALLER AFTER JOB')"
for f in n0/out1.log n0/out2.log n2/out2.log; do echo "errors $f: $(clean $T/$f | grep -a 'ERROR\|CloudException\|xception:\|error called' | grep -v 'mmfdata\|Enter' | sort | uniq -c | head -3 | cut -c1-180 | tr '\n' '|')"; done
