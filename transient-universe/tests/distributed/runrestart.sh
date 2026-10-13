#!/bin/bash
# usage: runrestart.sh <tag> [swap]
S=$(cd $(dirname $0) && pwd); T=$S/run-$1; rm -rf $T; mkdir -p $T/n0 $T/n1 $T/n2
NODES=add/127.0.0.1/9001/n/add/127.0.0.1/9002/n
(cd $T/n1 && sleep 60 | timeout 45 $S/apprestart -p start/127.0.0.1/9001 > out.log 2>&1 &)
(cd $T/n2 && sleep 60 | timeout 45 $S/apprestart -p start/127.0.0.1/9002 > out.log 2>&1 &)
sleep 4
(cd $T/n0 && sleep 30 | APPWAIT_SWAP=$2 timeout 10 $S/apprestart -p start/127.0.0.1/9000/$NODES/go > out1.log 2>&1)
sleep 2
(cd $T/n0 && sleep 30 | APPWAIT_SWAP=$2 timeout 10 $S/apprestart -p start/127.0.0.1/9000/$NODES/jobs/exec > out2.log 2>&1)
sleep 1
F='TERM\|RESOLVED\|AFTER JOB\|rror\|xception'
for f in n0/out1.log n0/out2.log n1/out.log n2/out.log; do echo "=== $f"; grep -av "^=======>" $T/$f | sed 's/\x1b\[[0-9;]*m//g' | grep -a "$F" | cut -c1-200 | head -8; done
