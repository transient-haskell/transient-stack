#!/bin/bash
# usage: runall.sh [name-filter]
#
# Runs the scenarios that need several processes (nodes that are killed and restarted, nodes started in a given
# order) and checks the result of each one against what is expected. It prints PASS or FAIL for every scenario and the
# number of failures at the end (the exit code is the number of failures).
#
# The scenarios that do not need to kill or restart processes (the applicative with any number of terms, the derived
# operators, the parsers in Serial mode...) are in AssertTests.hs. The binaries (see README.md) are next to this script.
#
# A scenario that is expected to fail is marked XFAIL: it is run, but its failure is not counted.
S=$(cd $(dirname $0) && pwd)
FILTER=${1:-}
FAILS=0
n=0

# expect <name> <regex> <command...>   : runs the command and looks for the regex in its output.
# Several regexes can be given separated by ';;': all of them have to be found.
expect() {
  local name=$1 re=$2; shift 2
  [ -n "$FILTER" ] && [[ "$name" != *$FILTER* ]] && return
  n=$((n + 1))
  local out ok=1 r; out=$("$@" 2>&1)
  while [ -n "$re" ]; do
    r=${re%%;;*}; [ "$re" = "$r" ] && re= || re=${re#*;;}
    echo "$out" | grep -aqE -- "$r" || ok=0
  done
  if [ $ok = 1 ]; then echo "PASS  $name"
  else echo "FAIL  $name"; echo "$out" | tail -6 | sed 's/^/        /'; FAILS=$((FAILS + 1)); fi
}

# count <name> <min> <regex> <command...>   : the regex must appear at least <min> times
count() {
  local name=$1 min=$2 re=$3; shift 3
  [ -n "$FILTER" ] && [[ "$name" != *$FILTER* ]] && return
  n=$((n + 1))
  local out c; out=$("$@" 2>&1); c=$(echo "$out" | grep -aEc -- "$re")
  if [ "$c" -ge "$min" ]; then echo "PASS  $name"
  else echo "FAIL  $name   (expected at least $min x $re, found $c)"; echo "$out" | tail -6 | sed 's/^/        /'; FAILS=$((FAILS + 1)); fi
}

cd $S

# --- the applicative in the nodes, with the log sent to them
expect "seqfail: three calls in sequence"                'RESULT \(1,2\)'          ./runseq.sh
count  "appwait: sequence"                          1 'TEST END'                    ./run.sh seq 0 1
count  "appwait: applicative"                       1 'TEST END'                    ./run.sh app 0 0
count  "appwait: applicative, the first term last"  1 'TEST END'                    ./run.sh appswap 1 0
for d in "1000000,2500000,4000000" "4000000,2500000,1000000" "2500000,4000000,1000000"; do
  count "appthree: $d" 1 'TEST END' ./runthree.sh three "$d"
done

# --- restarts
count  "apprestart: the job after the applicative"  2 'AFTER JOB \(1,2\)'           ./runrestart.sh restart 0
expect "runatrestart: the called node restarts"          'RESULT before after'      ./runrr.sh rr runatrestart 9970
expect "multiuser: restart, invoked without session"      'GUESS alice \(7,7\).*result msg: 1.*errors: 0' ./mur.sh mur 9420 multiuser nocookie
expect "multiuser: restart, invoked by the same session"  'GUESS alice \(7,7\).*result msg: 1.*errors: 0' ./mur.sh mua 9440 multiuser alice
expect "multiuser: restart, invoked by another session"   'GUESS alice \(7,7\).*result msg: 1.*errors: 0' ./mur.sh mub 9450 multiuser bob
expect "minput: two sessions invoke the endpoint of a third"  'GUESS alice \(7,3\);;GUESS alice \(7,7\);;errors: 0' ./mu2.sh mu 9430 multiuser
expect "collectc: restart"                               'inputs=2 resultsEndpoint=1;;MINPUT RESULT' ./runcol.sh col collecttest 9960

# --- jobs and calls to other nodes (AppJob). The summary line says: the result and the number of BACK arrived
job() { AJ_SLOW=$1 ./runajob.sh "$2" "$3" "$4" ajob "$5"; }
expect "ajob: job in the body of the called node, it falls"        'RESULT \(1,2\); BACK: 1'  job 8000000  j1 jobterm n2 9700
expect "ajob: nested runAt, the inner node falls"                  'RESULT \(12,0\); BACK: 1' job 8000000  j2 nested  n2 9710
expect "ajob: job before an applicative, the caller falls"         'RESULT \(1,2\); BACK: 1'  job 15000000 j3 caller  n0 9720
expect "ajob: job before a call, the caller falls"                 'RESULT \(1,0\); BACK: 1'  job 15000000 j4 seqjob  n0 9730
expect "ajob: job inside a term, nothing falls"                    'RESULT \(1,2\); BACK: 1'  job 3000000  j5 injob   none 9740
expect "ajob: job inside a term, the caller falls"                 'RESULT \(1,2\); BACK: 1'  job 15000000 j6 injob   n0 9750
expect "ajob: a term of two calls"                                 'RESULT \(4,2\); BACK: 1'  job 3000000  j7 seqterm none 9760
expect "jobTask: finished before the fall, it is not launched again" 'after-job: 1 / 0'       job 1000000  j8 task    n0 9770
expect "jobTask: the caller falls, the task is executed again"     'after-job: 1 / 1'         job 15000000 j9 task    n0 9780
expect "both nodes fall, the called one restarts first"            'RESULT \(1,0\);  BACK: 1' ./runboth.sh b1 n1 ajob 9790
expect "both nodes fall, the caller restarts first"                'RESULT \(1,0\);  BACK: 1' ./runboth.sh b2 n0 ajob 9800
expect "ping: the called node starts after the call failed"        'RESULT \(1,0\);  BACK: 1' ./runping.sh pg ajob 9810

echo "$((n - FAILS)) of $n scenarios passed"
exit $FAILS
