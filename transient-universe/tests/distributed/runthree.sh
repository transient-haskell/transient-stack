#!/bin/bash
# usage: runthree.sh <tag> <d1,d2,d3>
S=$(cd $(dirname $0) && pwd); T=$S/run-$1; rm -rf $T; mkdir -p $T/n0 $T/n1 $T/n2 $T/n3
for i in 1 2 3; do (cd $T/n$i && sleep 60 | timeout 45 $S/appthree -p start/127.0.0.1/900$i > out.log 2>&1 &); done
sleep 4
(cd $T/n0 && sleep 60 | APPWAIT_D=$2 timeout 30 $S/appthree -p start/127.0.0.1/9000/add/127.0.0.1/9001/n/add/127.0.0.1/9002/n/add/127.0.0.1/9003/n/go > out.log 2>&1)
sleep 1
for n in n0 n1 n2 n3; do echo "=== $n: $(sed 's/\x1b\[[0-9;]*m//g' $T/$n/out.log | grep -ao 'APPLICATIVE RESOLVED ([0-9,]*)\|BACK FROM N[0-9] ([0-9,]*)\|TEST END\|TERM[0-9] executed\|AFTER APPLICATIVE AT N[0-9] ([0-9,]*)\|error parsing <[^>]*>' | tr '\n' ';')"; done
