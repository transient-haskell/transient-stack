#!/bin/bash
# Runs SeqFail with three nodes, each in its own directory, and shows the program output.
S=$(cd $(dirname $0) && pwd); T=$S/run-seq; rm -rf $T; mkdir -p $T/n0 $T/n1 $T/n2
(cd $T/n1 && sleep 30 | timeout 20 $S/seqfail -p start/127.0.0.1/9001 > out.log 2>&1 &)
(cd $T/n2 && sleep 30 | timeout 20 $S/seqfail -p start/127.0.0.1/9002 > out.log 2>&1 &)
sleep 4
(cd $T/n0 && sleep 30 | timeout 10 $S/seqfail -p start/127.0.0.1/9000/add/127.0.0.1/9001/n/add/127.0.0.1/9002/n/go > out.log 2>&1)
sleep 1
for n in n0 n1 n2; do
  echo "=== $n"
  grep -av "^=======>" $T/$n/out.log | grep -a "RESULT\|ERROR" | head
done
