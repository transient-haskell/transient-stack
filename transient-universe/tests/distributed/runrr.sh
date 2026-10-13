#!/bin/bash
# usage: runrr.sh <tag> <binary> <port>  : the called node is killed during the wait of a runAt and restarted with its jobs
S=$(cd $(dirname $0) && pwd); T=$S/run-$1; B=$2; P=$3; rm -rf $T; mkdir -p $T/n0 $T/n1
(cd $T/n1 && sleep 60 | timeout 10 $S/$B -p start/127.0.0.1/$((P+1))/saveonexit > out1.log 2>&1 &)
sleep 3
(cd $T/n0 && sleep 60 | timeout 45 $S/$B -p start/127.0.0.1/$P/add/127.0.0.1/$((P+1))/n/go > out.log 2>&1 &)
sleep 8                                   # n1 died at t=10 during its wait
(cd $T/n1 && sleep 60 | timeout 30 $S/$B -p start/127.0.0.1/$((P+1))/jobs/exec > out2.log 2>&1 &)
sleep 25
n1a=$(sed 's/\x1b\[[0-9;]*m//g' $T/n1/out1.log | grep -ac "N1 WORKING"); n1b=$(sed 's/\x1b\[[0-9;]*m//g' $T/n1/out2.log | grep -ac "N1 WORKING")
echo "n1 run1: N1 WORKING x$n1a, saved=$(grep -ac '^saved' $T/n1/out1.log) | n1 run2 (restart): N1 WORKING x$n1b"
echo "A: $(sed 's/\x1b\[[0-9;]*m//g' $T/n0/out.log | grep -ao 'RESULT [a-z ]*' | head -2 | tr '\n' ';')"
for f in n0/out.log n1/out2.log; do echo "errores en $f:"; sed 's/\x1b\[[0-9;]*m//g' $T/$f | grep -a "ERROR\|CloudException\|ConnectionError\|No connection\|error called\|xception:" | grep -v "mmfdata\|Enter" | sort | uniq -c | head -4 | cut -c1-200; done
