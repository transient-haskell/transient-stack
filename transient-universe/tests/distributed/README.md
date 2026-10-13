# Distributed tests of the applicative, reentrancy and restarts

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
starts the nodes, drives the test and prints a summary. Nothing here is listed in the `.cabal`: the programs are
compiled against the libraries already built, and the scripts look for the binaries **next to themselves**.

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

## Things to know

* The terms start about 100 ms apart, not together: delays closer than that give ties. The scripts that take
  delays expect them in microseconds and separated by 1.5 s or more.
* `curl` does not read everything these endpoints send (the cookie goes inside the chunked stream): the
  scripts use `--raw` and read the result in the server log.
* The persistence of the state needs `saveonexit` (command line), a `job` or a `collect`.
* A hung test does not stop the others only if they are run one by one (`assertone.sh`).
