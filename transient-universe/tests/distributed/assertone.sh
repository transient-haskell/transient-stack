#!/bin/bash
# usage: assertone.sh <index> <binary> <port>  -> prints PASA / NO PASA reading RESULT.txt (not the interleaved log)
S=$(cd $(dirname $0) && pwd); i=$1; B=$2; P=$3
ASSERT_ONLY="$i" $S/runassert.sh ao$i-$B $B $P > /dev/null
if [ -s $S/run-ao$i-$B/n0/RESULT.txt ]; then echo "PASA ($(tr -d '\n' < $S/run-ao$i-$B/n0/RESULT.txt | cut -c9-))"; else echo "NO PASA"; fi
