# Distributed tests of the applicative, reentrancy and restarts

## How to run them

From the repository root, inside the nix shell (see CLAUDE.md):

```bash
cabal test distributed                           # the 26 tests of AssertTests.hs, each one in four nodes (about 20 minutes)
DISTRIBUTED_ONLY="3 9" cabal test distributed    # only the tests with those indices (positions in the list `tests`, from 0)
transient-universe/tests/distributed/runall.sh   # the scenarios that kill and restart nodes (about 30 minutes)
transient-universe/tests/distributed/runeverything.sh   # compiles what is needed and runs both
```

`cabal test distributed` is the driver `RunDistributed.hs`: it starts four nodes of `assert-tests` on the same machine
(the leader and three more), runs one test at a time and reads the result from the `RESULT.txt` that the leader writes (the
console of the nodes is full of interleaved traces). It leaves the logs of each test in `dist-distributed/test<index>/n<node>/`.
The exit code of the three commands is the number of tests that did not pass.

## Where each test is

* `AssertTests.hs` (in `tests/`): everything that does not need to kill or restart a process. The distributed `check*`
  tests run on four connected nodes and verify their result with `assert`: the applicative with two, three or four terms,
  nested and in sequence, the operators that `Cloud` derives from the applicative (`<>`, `+`, a new operator written once
  for any `Applicative`) and the applicative in Serial mode (parsers over a string and over a stream). Run one with
  `assertone.sh <index> <binary> <port>`.
* `runall.sh`: the scenarios that need several processes (a node that falls and restarts, nodes that start in a given
  order). It checks the result of each one and prints `PASS` or `FAIL`; the exit code is the number of failures.
  `runall.sh <part of a name>` runs only the scenarios whose name contains it.
* The tables below describe each program and script. The summary lines that they print are the ones that `runall.sh` checks.

Each test is a program that runs in several nodes of the same machine (ports 9000-9970) and a script that
starts the nodes, drives the test and prints a summary. Only `assert-tests` and the test-suite `distributed` are listed in
the `.cabal`: the programs of the scenarios are compiled against the libraries already built (`runeverything.sh` does it),
and the scripts look for the binaries **next to themselves**.

```bash
# from the repository root, inside the nix shell (see CLAUDE.md)
cabal build transient-universe
mkdir -p /tmp/dtests && cp transient-stack/transient-universe/tests/distributed/*.sh /tmp/dtests/
cd /tmp/dtests
for t in AppWait:appwait SeqFail:seqfail AppRestart:apprestart AppThree:appthree AppMore:appmore \
         MultiUser:multiuser CollectTest:collecttest RunAtRestart:runatrestart AppMinput:appminput \
         AssertTests:asserttests ParseSerial:parseserial AppJob:ajob; do
  src=${t%%:*}; bin=${t##*:}
  cabal exec -- ghc -package transient -package transient-universe -threaded -w -O0 \
      -outputdir build-$bin -o $bin transient-stack/transient-universe/tests/$src.hs
done
```

Each run creates a directory `run-<tag>` next to the script, with the log of every node. The logs are full
of traces, interleaved between threads: the scripts read only the lines that matter and the results are
counted, not read by eye.

| Program | Script | What it checks |
|---|---|---|
| `SeqFail` | `runseq.sh` | three remote calls in sequence (node1, node2, node1) |
| `AppWait` | `run.sh <tag> <swap> <monad>` | applicative of two remote terms, either order of termination, and the same in sequence; then a call to each node |
| `AppThree` | `runthree.sh <tag> <d1,d2,d3>` | applicative of three terms in any order of termination |
| `AppMore` | `runmore.sh <tag> <case> <d1,d2,d3,d4>` | `right` nested on the right, `four` terms, `twice` in sequence, `mono` (derived `<>`), `monoA` (`liftA2 (<>)`). It prints the **real** order of arrival of the responses |
| `AppRestart` | `runrestart.sh <tag> <swap>` | restart of the caller after an applicative, with a `job` |
| `RunAtRestart` | `runrr.sh <tag> <binary> <port>` | the called node restarts in the middle of a `runAt` and responds to the caller afterwards |
| `MultiUser` | `mu.sh`, `mu2.sh`, `mur.sh` | endpoints created by one session and invoked by another (`publish` / `published`), with and without restart |
| `CollectTest` | `runcol.sh <tag> <binary> <port>` | `collectc` with `minput` across a restart |
| `AppJob` | `runajob.sh <tag> <case> <n2\|n0\|none> <binary> <port>` | runAt + job with a node killed and restarted (`jobterm`, `nested`, `caller`; `injob` and `seqterm`: a job and a sequence inside the first term). `AJ_SLOW` sets the slow term (µs) |
| `ParseSerial` | `runparse.sh` | the applicative in Serial mode: parsers over a string and over streams (chunks cutting the numbers, one byte per chunk). The asynchronous-chunks cases give NO RESULT with the old applicative too |
| `AppJob both` (and `seqjob`: the caller restarts while the remote stays up) | `runboth.sh <tag> <n1\|n0> <binary> <port>` | the caller and the remote node die together while the remote waits, and restart in either order. Works restarting either node first. With an applicative (`caller`, `injob`) and the caller dead, the result arrives twice: the job stays inside the applicative |
| `AppJob both` + `runping.sh <tag> <binary> <port>` | the caller sends to a node that is down; the job waits for it; when the node starts with its jobs it greets the known nodes and the caller launches the job again |
| `AppJob task` | `runajob.sh <tag> task n0 <binary> <port>` | `jobTask`: closed only when the task is completed. If the caller falls before, the task is executed again (at least once) |
| `AppMinput` | `runminput.sh` | applicative of REST inputs (`minput`) |
| `AssertTests` | `runassert.sh <tag> <binary> <port>`, `assertone.sh <index> <binary> <port>` | the assertion suite (four nodes). `assertone.sh` runs one test (`ASSERT_ONLY`) and reads `RESULT.txt` |

## The tests of `AssertTests.hs`

The index is the position in the list `tests`. Each test asserts its own result (`assert`) in the leader.

| # | Test | What it checks |
|---|---|---|
| 0 | `testlocalExceptions` | exceptions in a local computation |
| 1 | `checkWormholeTeleportComposition` | `wormhole` and `teleport` composed by hand |
| 2 | `checkApplicativeWithRemote` | applicative of two `atRemote` in one `wormhole` |
| 3 | `checkAlternativesWithAtRemote` | alternative of two `atRemote` in one `wormhole`: both answers, once each (`collect 0`) |
| 4 | `checkStreaming` | a node that streams several results |
| 5 | `checkEmptyInRemoteNodeWhenTheRemoteCallbackToTheCaller` | `empty` in the called node when it calls back to the caller |
| 6 | `checkAlternativeDistributed` | alternative of two `runAt` to different nodes (`collect 0`) |
| 7, 8 | `checkApplicativeDistributed`, `checkMonadicDistributed` | the same calls with `<*>` and with `>>=` |
| 9 | `checkReentrantDistributed` | node1 → node2 → node1 → node2: the second visit of a node must not run the first one again |
| 10 | `checkNonSerializableMutableVariables` | variables that are not serialized and survive successive invocations |
| 11 | `checkMapReduce` | map-reduce over the nodes |
| 12–15 | `checkApplicativeThreeTerms`, `…FourTerms`, `…NestedRight`, `…Twice` | applicative of 3 and 4 terms, nested, in sequence |
| 16–18 | `checkSemigroupDerived`, `checkNumDerived`, `checkNewOperator` | the operators that `Cloud` derives from the applicative |
| 19 | `checkParseSerial` | the applicative in Serial mode (parsers) |
| 20 | `checkKeyedMailbox` | mailboxes with a key |
| 21, 22 | `checkRunAtSelfInCalledNode`, `checkOnNodesFromCalledNode` | a node that calls itself; `onNodes` from a called node |
| 23 | `checkChainOfThreeNodes` | node1 → node2 → node3, composed monadically (the reentrant one without returning to the first node) |
| 24 | `checkAlternativeOfTwoRunAtToTheSameNode` | alternative of two `runAt` to the **same** node: each one has its own `wormhole` and answers with its value |
| 25 | `checkFiveSequentialCalls` | five calls in sequence to the same node (the fifth one used to not come back) |

## Cleanup of the endpoints of a remote call

A remote call creates endpoints (closures with a listener) in both nodes. When the work of the called node ends, the endpoints must
disappear, in the reverse order of the creation, and when the caller does not need the answers any more (a `collect` that
has enough results) the called node must stop working. Two notifications of `teleport` do it:

* `notifyCallingNode`: when no threads are left in the **called** node, it sends a `SLast` without log to the caller, which removes
  the listener of the endpoint (a counter, `localVisits`, tells how many visits of that endpoint expect their final message).
* `notifyCalledNode`: when no threads are left under the endpoint of the **caller**, it sends a `SLast` whose origin is
  `killClosureId`; the called node kills what hangs from that endpoint (the stream that the caller does not collect any more).

Tests that need that cleanup: the `collect 0` of 3 and 6, `checkReentrantDistributed` and the whole `runall.sh`
(the scenarios with restarts). `collect 0` ends only when the listeners of the endpoints of the call are gone.

Not covered yet: a test that asserts that **no threads or endpoints are left** in the thread tree when a computation ends.
Today it is only seen by counting the `endpoint` lines of `coreoptions/ps` at the end of a run.

## The same tests in the Rust port

`transient-stack-rust` (`transient-rs/transient-core/tests`) has these tests, each one in four nodes of the same process and with the
name of the Haskell one in its documentation: `distributed.rs` (0 to 8, 10, 12 to 18, 21 and 22), `cleanup.rs` (9, 23, 24 and 25),
`parse.rs` (19) and `evar_mailbox.rs` (20). Not ported: 11 (`checkMapReduce`, there is no map-reduce in Rust). In addition they
assert, as the Haskell ones do not, that nothing hangs from the thread where the calls started when the computation ends, and
`FinishInRemote` is a test (`test_finish_in_remote`, and the same through a chain of calls): the called node counts what it
produces and must stop when the caller has its `collect 5`.

## Programs written to diagnose, not run by any script

In `tests/` there are standalone programs that were written to reproduce a problem and are not part of the suites above:
`Hang*.hs` (calls in sequence and streaming with and without `setSession`), `FinishInRemote.hs` (a `collect 5` over a remote
stream), `Alt*.hs` (alternatives with and without `collect`), `ChainOfThreeNodes.hs`, `OnFinishVariant.hs`, `SelfFinish.hs` and
`Endpoints.hs`. Some are covered now by a test of `AssertTests.hs`: `Hang.hs` by test 25, `ChainOfThreeNodes.hs` by test 23 and
the alternatives (`Alt*.hs`) by tests 3, 6 and 24. The others are **not** covered by any suite and still have to be run by hand
(compile with `ghc -package transient -package transient-universe -threaded -w -O0`): `FinishInRemote.hs` (a `collect 5`
over a stream that the called node should stop producing), `HangStream*.hs` (streaming with and without `setSession`, in one
and in two chained calls), `OnFinishVariant.hs`, `SelfFinish.hs` and `Endpoints.hs`.

## Things to know

* The checks of `multiuser` (`mur.sh`) and `collectc` (`runcol.sh`) do not read traces: `mur.sh` reads the messages that the
  program sends to the client in the HTTP responses of `curl` (it kept them in `curl.out`), and `CollectTest` writes what it
  collects to `collected.txt` and `reached-results.txt`. They used to grep trace lines (`MSEND`, `ADDED ENDPOINT`,
  `MINPUT RESULT`) that the library no longer emits, and they failed even though the programs worked. The console output of
  several threads gets mixed up character by character (`keep` leaves stdout unbuffered), so grepping the program's own
  `putStrLn` is not reliable either.

* The terms start about 100 ms apart, not together: delays closer than that give ties. The scripts that take
  delays expect them in microseconds and separated by 1.5 s or more.
* `curl` does not read everything these endpoints send (the cookie goes inside the chunked stream): the
  scripts use `--raw` and read the result in the server log.
* The persistence of the state needs `saveonexit` (command line), a `job` or a `collect`.
* A hung test does not stop the others only if they are run one by one (`assertone.sh`).
