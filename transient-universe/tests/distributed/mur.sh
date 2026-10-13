#!/bin/bash
# usage: mur.sh <tag> <port> <binary> <variant: bob|alice|nocookie> [saveonexit|nosave]
# run 1: alice creates the endpoint (enterguess) and the process ends. run 2: restart in the same directory, invoke it.
S=$(cd $(dirname $0) && pwd); T=$S/run-$1; P=$2; B=$3; V=$4; SAVE=${5:-saveonexit}; rm -rf $T; mkdir -p $T
EXTRA=""; [ "$SAVE" = "saveonexit" ] && EXTRA="/saveonexit"
getc() { curl --raw -sN -m 2 "http://127.0.0.1:$P/$1" | grep -ao 'state=[a-z]*' | head -1 | cut -d= -f2; }
c() { curl --raw -sN -m 2 ${2:+-H "Cookie: state=$2"} "http://127.0.0.1:$P/$1" > /dev/null; }
(cd $T && sleep 30 | timeout 12 $S/$B -p start/127.0.0.1/$P$EXTRA > out1.log 2>&1 &)
sleep 4
C1=$(getc enterw/alice); c guessgame/u $C1; c enterlock/7 $C1
sleep 9                                  # run 1 ends by timeout (SIGTERM)
echo "run1: endpoint published: $(sed 's/\x1b\[[0-9;]*m//g' $T/out1.log | grep -ac 'ADDED ENDPOINT","enterguess"'), saved: $(sed 's/\x1b\[[0-9;]*m//g' $T/out1.log | grep -ac 'saved')"
(cd $T && sleep 30 | timeout 14 $S/$B -p start/127.0.0.1/$P > out2.log 2>&1 &)
sleep 4
case $V in
  bob)      C2=$(getc enterw/bob); c enterguess/S$C1/7 $C2 ;;
  alice)    c enterguess/7 $C1 ;;
  nocookie) c enterguess/S$C1/7 ;;
esac
sleep 3
L=$(sed 's/\x1b\[[0-9;]*m//g' $T/out2.log)
echo "run2 ($V): $(echo "$L" | grep -ao 'GUESS [a-z]* ([0-9]*,[0-9]*)' | tr '\n' ' ') | result msg: $(echo "$L" | grep -a "MSEND" | grep -ac 'entered number') | errors: $(echo "$L" | grep -a 'rror' | grep -ac -v 'ErrorCall\|mmfdata')"
