#!/bin/bash
# usage: runassert.sh <tag> <binary> <base port>   leader + 3 nodes
S=$(cd $(dirname $0) && pwd); T=$S/run-$1; B=$2; P=$3; rm -rf $T; mkdir -p $T/n0 $T/n1 $T/n2 $T/n3
for i in 1 2 3; do (cd $T/n$i && sleep 40 | timeout 30 $S/$B -p start/127.0.0.1/$((P+i)) > out.log 2>&1 &); done
sleep 5
(cd $T/n0 && sleep 40 | timeout 20 $S/$B -p start/127.0.0.1/$P/add/127.0.0.1/$((P+1))/n/add/127.0.0.1/$((P+2))/n/add/127.0.0.1/$((P+3))/n/go > out.log 2>&1)
sleep 1
L=$(sed 's/\x1b\[[0-9;]*m//g' $T/n0/out.log)
echo "$L" | grep -a "^PASSED\|ALL ASSERT\|nodes connected" | cut -c1-120
echo "fallos: $(cat $T/n*/out.log | sed 's/\x1b\[[0-9;]*m//g' | grep -a -i 'assertion\|Assertion failed\|error called' | sort | uniq -c | head -5 | tr '\n' ';')"
