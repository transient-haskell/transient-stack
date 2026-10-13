#!/bin/bash
# usage: runminput.sh <tag> <liftA2|derived> <first endpoint: t1|t2> <port>
S=$(cd $(dirname $0) && pwd); T=$S/run-$1; rm -rf $T; mkdir -p $T; P=$4
(cd $T && sleep 30 | APPMINPUT_CASE=$2 timeout 14 $S/appminput -p start/127.0.0.1/$P > out.log 2>&1 &)
sleep 4
if [ "$3" = "t1" ]; then A="t1/hello"; B="t2/world"; else A="t2/world"; B="t1/hello"; fi
curl -s -m 3 http://127.0.0.1:$P/$A > /dev/null; sleep 1
curl -s -m 3 http://127.0.0.1:$P/$B > /dev/null; sleep 2
L=$(sed 's/\x1b\[[0-9;]*m//g' $T/out.log)
res=$(echo "$L" | grep -ao 'MINPUT RESOLVED [a-z]*' | tr '\n' ';')
fin=$(echo "$L" | grep -ao '"msg":\["RESULT","[a-z]*"\]' | tr '\n' ';')
errs=$(echo "$L" | grep -ao 'error parsing <[^>]*>' | sort | uniq -c | tr '\n' ' ')
echo "$2, first call $A: $res $fin $errs"
