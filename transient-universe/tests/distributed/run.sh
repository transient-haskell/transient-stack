#!/bin/bash
# usage: run.sh <tag> [swap]
S=$(cd $(dirname $0) && pwd); T=$S/run-$1; rm -rf $T; mkdir -p $T/n0 $T/n1 $T/n2
(cd $T/n1 && sleep 40 | timeout 25 $S/appwait -p start/127.0.0.1/9001 > out.log 2>&1 &)
(cd $T/n2 && sleep 40 | timeout 25 $S/appwait -p start/127.0.0.1/9002 > out.log 2>&1 &)
sleep 4
(cd $T/n0 && sleep 40 | APPWAIT_SWAP=$2 APPWAIT_MONAD=$3 timeout 15 $S/appwait -p start/127.0.0.1/9000/add/127.0.0.1/9001/n/add/127.0.0.1/9002/n/go > out.log 2>&1)
sleep 1
for n in n0 n1 n2; do
  echo "=== $n"
  grep -av "^=======>" $T/$n/out.log | grep -a "TERM\|RESOLVED\|AFTER \|BACK\|TEST END\|rror\|xception" | head -20
done
