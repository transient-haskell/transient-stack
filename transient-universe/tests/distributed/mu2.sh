#!/bin/bash
# usage: mu2.sh <tag> <port> <binary>   alice publishes; bob guesses 3 (wrong), carol guesses 7 (right) through the same endpoint
S=$(cd $(dirname $0) && pwd); T=$S/run-$1; P=$2; B=$3; rm -rf $T; mkdir -p $T
(cd $T && sleep 60 | timeout 40 $S/$B -p start/127.0.0.1/$P > out.log 2>&1 &)
sleep 4
c() { curl --raw -sN -m 2 ${2:+-H "Cookie: state=$2"} "http://127.0.0.1:$P/$1" > /dev/null; }
getc() { curl --raw -sN -m 2 "http://127.0.0.1:$P/$1" | grep -ao 'state=[a-z]*' | head -1 | cut -d= -f2; }
C1=$(getc enterw/alice); c guessgame/u $C1; c enterlock/7 $C1
C2=$(getc enterw/bob);   c guessgame/u $C2;   c enterguess/S$C1/3 $C2
C3=$(getc enterw/carol); c guessgame/u $C3;   c enterguess/S$C1/7 $C3
sleep 2
L=$(sed 's/\x1b\[[0-9;]*m//g' $T/out.log)
echo "$L" | grep -ao 'GUESS [a-z]* ([0-9]*,[0-9]*)' | sort | uniq -c
echo "$L" | grep -a "MSEND" | grep -a "entered number" | sed 's/.*Service (fromList \[("httpnode","")\])\]),\([0-9]*\),.*msg\\":\(.\{0,70\}\).*/conn=\1 msg=\2/'
echo "errors: $(echo "$L" | grep -ac 'rror')  exceptions: $(echo "$L" | grep -ac 'xception')"
