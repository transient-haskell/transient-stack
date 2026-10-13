#!/bin/bash
# usage: runparse.sh   : the applicative in Serial mode (parsers); the binary parseserial is next to this script
S=$(cd $(dirname $0) && pwd)
for a in sync async-new async-old async-bytes; do
  echo "-- $a"; timeout 20 $S/parseserial $a 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -a "PASS\|FAIL\|END\|NO RESULT\|rror"
done
