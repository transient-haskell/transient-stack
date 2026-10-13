#!/bin/bash
# usage: runmore.sh <tag> <case> <d1,d2,d3,d4>   (delays in microseconds)
S=$(cd $(dirname $0) && pwd); T=$S/run-$1; rm -rf $T; mkdir -p $T/n0 $T/n1 $T/n2 $T/n3
for i in 1 2 3; do (cd $T/n$i && sleep 60 | timeout 45 $S/appmore -p start/127.0.0.1/900$i > out.log 2>&1 &); done
sleep 4
(cd $T/n0 && sleep 60 | APPWAIT_CASE=$2 APPWAIT_D=$3 timeout 30 $S/appmore -p start/127.0.0.1/9000/add/127.0.0.1/9001/n/add/127.0.0.1/9002/n/add/127.0.0.1/9003/n/go > out.log 2>&1)
sleep 1
L=$(sed 's/\x1b\[[0-9;]*m//g' $T/n0/out.log)
arrival=$(echo "$L" | grep -ao 'SMORE",[0-9]*,\[Fragment {unFragment = "u/\[\?[0-9]\]\?/"' | grep -o '[0-9]/"$' | grep -o '^[0-9]' | awk '!s[$0]++' | tr '\n' ' ')
out=$(echo "$L" | grep -ao 'RESOLVED \[[0-9,]*\]\|TEST END' | tr '\n' ';')
back=$(echo "$L" | grep -ao 'BACK FROM N[0-9]' | wc -l)
errs=$(cat $T/n*/out.log | sed 's/\x1b\[[0-9;]*m//g' | grep -ao 'error parsing <[^>]*>' | sort | uniq -c | tr '\n' ' ')
echo "$2 [$3] arrival: $arrival| $out BACK=$back/3 $errs"
