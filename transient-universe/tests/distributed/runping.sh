#!/bin/bash
# usage: runping.sh <tag> <binary> <base port>
# The caller (n0) calls n1 before n1 is up: the send fails and the job is kept for n1. Later n1 starts with its jobs;
# it connects to the known nodes, n0 gets the Ping of n1 and launches the job again. n2 stays alive.
S=$(cd $(dirname $0) && pwd); T=$S/run-$1; B=$2; P=$3; rm -rf $T; mkdir -p $T/n0 $T/n1 $T/n2
export AJ_CASE=both AJ_SLOW=${AJ_SLOW:-4000000}
(cd $T/n2 && sleep 90 | timeout 80 $S/$B -p start/127.0.0.1/$((P+2)) > out.log 2>&1 &)
sleep 3
(cd $T/n0 && sleep 90 | timeout 70 $S/$B -p start/127.0.0.1/$P/saveonexit/add/127.0.0.1/$((P+1))/n/add/127.0.0.1/$((P+2))/n/jobs/exec/go > out.log 2>&1 &)
sleep 8                                     # n0 has tried to call n1, which is down
(cd $T/n1 && sleep 60 | timeout 50 $S/$B -p start/127.0.0.1/$((P+1))/add/127.0.0.1/$P/n/jobs/exec > out.log 2>&1 &)
sleep 25
clean() { sed 's/\x1b\[[0-9;]*m//g' "$@" 2>/dev/null; }
echo "n0: CALLER AFTER JOB: $(clean $T/n0/out.log | grep -ac 'CALLER AFTER JOB')  RESULT: $(clean $T/n0/out.log | grep -ao 'RESULT ([0-9,]*)' | tr '\n' ';')  BACK: $(clean $T/n0/out.log | grep -ac '^BACK')"
echo "n1: WORK: $(clean $T/n1/out.log | grep -ac 'WORK')"
echo "n0 connection errors (the failed send): $(clean $T/n0/out.log | grep -ac 'Connection refused')"
echo "n0 pings launched: $(clean $T/n0/out.log | grep -ac 'runJobs(commJobs)')"
