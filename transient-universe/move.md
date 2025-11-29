
Managing Haskell computations as data for storage, restore, translate and distributed computing
===============================================================================================

This is a tutorial about how to handle the complete state of a computation so that it can be serialized, stored, translated, analyzed, restored his execution etc

This text summarizes my reseach with [Transient](https://github.com/transient-haskell) in this aspect which is the least known. I want to make it public since I belive has useful contributions to real world computing problems in novel ways and may make a difference.  The text is the result of a balance between  didactic simplicity (my intention) and the terseness of my laziness.

I use a pseudocode similar to Haskell. This is a very first version which will have errors for sure. But it gives an idea. I will perfect the content from time to time to make it more informative. At first it will be a gist.

Th pseudocode uses an unsophisticated convention tbat are hopefully intiuitive. For example, `this`, `that` `other` are functions which, if no definition is included, mean  `this=return "this"`, `that=return "that"`  and so on. 


Scope
-----

I will detail how a threaded program can store execution state, make optimum use of memory and execute remote computations among different nodes with optimum use of the bandwith, like RPC. This is important to be remarked in order to bypass prejudices arising from the naive examples at the beginning. The program execution stack could replicate itself in different nodes without having penalizations of performance (well... a little). So a routine invoked in a remote node is not isolated in his own sandbox of parameters like in the case of RPC but it is first class and can access all the variables of the calling node. Also any part of the program could be invoked with a URL.

The code can be implemented in any language as long as it has continuations and pure state.

Logging
-------

We can define a simple logging primitive that store the "path" of execution and it can add his result to a log, but also could "replay" in case the computation need to be restored:

```Haskell
 logged comp= case execution state of
    Executing -> do
        result <- comp
        store log result in tbe state
        return result 
    Restoring -> read (that element form the)log
```

That logging could be too long if we want to log subcomputations. A great optimization is to eliminate an entire subcomputation log and substitute it for his result(*).

```Haskell
do
   logged this
   Logged that
   logged other
   where
   that= do
      logged here
      logged there
      return thatreturn
```

So we log `this/e/here/there..`

"e" means that the subcomputation has not finished and has to be executed

 but when the execution reach `thatreturn`, the log, `e/here/there` is erased and the log becomes `this/thatreturn`

```Haskell
 logged comp= case execution state of
    Executing -> do
        log <- getLog -- read the log from pure state
        result <- comp
        setLog $ result <> log  -- add result to the previous log 
        return result 
    Restoring -> do
        r <-read log
        case r of
         "e" -> comp
         _ -> return r
```

With this use of pure state, the program get rid of any logging that the subcomputation `that` may have done before producing the result. 

Pure means that the log changes are not in a mutable variable/state.

Threading
---------

But programs have threads. At this moment is necessary to introduce parallelism and concurrency with the notation of alternatives and applicatives and the primitive `abduce`.

For that purpose we need a language where continations are first class, in which we can get the continuation (`getCont`), store it, re-execute it under a different thread etc. All except serialization. We don´t need to serialize a continuation.

```Haskell
do
 logged prev
 logged (abduce >> this) <|> logged that
 logged other
 
abduce= do
  cont <- getCont
  forkIO $ run cont
  empty
```

`abduce` abduces the rest of the computation so that it dissapear (produces empty) and executes it in another thread. The alternative (<|>) sees that the abduced computation was empty in the current thread, and executes the other computation `that`. So the abduced computation executes `this` and the next in the monad, `other` (see the meaning of <|> and monad in a Haskell program). The current thread in the other side, executes `that` and `other`. 

`abduce` in Transient has thread control, thread pooling, finalization of resources etc but for the purpose of this text, it is enough.
unlike `forkIO` it composes well as we see.

Then we have two histories, two logs, the first would be prev/this/other. The one of the current thread will be prev/w/that/other. "w" in the log means to step over the current computation and apply the log to the next expression when replaying.

```Haskell
 logged comp= case execution state of
    Executing -> do
        log <- getLog -- pure state
        result <- comp
        add result to log
        return result 
    Restoring -> do
        r <-read log
        case r of
         "e" -> comp
         "w" -> empty
         _ -> return r
```


A fork can be expressed with abduce and empty as this:

```Haskell
fork x=  (do(do abduce ;x ); empty) <|> return()
```

That's about parallelism. Concurrency also can be obtained by using applicative operators. Using a definition which makes use of the alternative definition above ([see here](https://github.com/transient-haskell/transient-stack/blob/dde6f6613a946d57bb70879a5c0e7e5a73a91dbe/transient/src/Transient/Internals.hs#L279-L319))

```Haskell

-- standard definitions
a + b = (+) <$> a <*> b
a * b=  (*) <$> a <*> b


async proc= abduce >> proc

do
   r <- (async $ return 2) * (async $ return 3) + return 5
   liftIO $ print r


```

prints `11` . It execute the three terms in parallel. The slowest of thee three threads concurrently calculates the result.

   

Distributed computing
---------------------

Now we can freeze computations and restore them in any computer that run the same program, as long as "this" "that" "other" and all the intermediate values can be serialized into a string.

```Haskell
translate somenode= do
   log <- getLog
   sendTo somenode log
   empty

-- the main would be like
main= do
  fork $ listen for logs
  logged this
  translate othernode
  logged that
```

This program would execute `this` locally and `that` in othernode.

[Transient](https://github.com/transient-haskell) divide translate in two different primitives: teleport, wich translate the computation, and `wormhole` which set the communication with the remote node.

For computations whose results can not be serialized, for example, pointers, references, IO computations, they should be executed in each node.

now suppose that I want to translate a computation to another computer, but only for getting the result of something, a DB access for example, and then getting back with the result of that in the log. That could be done with two "translate".

```Haskell
main= init $ do
       r <-remoteDB "select ..."
       print r

init proc= do
    fork $ wait for logs in some port
    proc

remoteDB query= do
    r <-logged this
    mynode <- getMyNode
    translate dbNode
    result <- logged databasequery $ query r
    translate mynode
    return result
```

Note that the query makes use of parameters that were introduced in the firs node
without explicitly referring to them as parameters. Unlike RPC, the prograam in the remote node can access the complete stack of the application, just like the local one.

We can define a primitive runAt which goes and return back from/to a remote node:

```haskell
runAt someNode todo= do
    mynode <- getMyNode
    translate someNode
    result <- logged todo
    translate mynode
    return result
```



Now suppose that some runAt's are executed repetitively and with a lot frequency and in different parts of the programs. We would like to make the log as short as possible so that the lengt of the data and the time it takes to process the log is minimized. 

If we can send the log not from the beginning, but from a certain point in the program that already has been executed, for example, the first translate, then we have no log and we can make the remote invocation as fast as a remote procedure call.

For that purpose we need a language where continations are first class, in which we can get the continuation, store it, re-execute it under a different threaad. All except serialization. We don´t need to serialize a continuation.

```Haskell
setContinuation= do
    cont <- getCont
    hash <- getHash
    insert somehash cont continuations
```

The hash should be as such that a remote node would calculate the same hash for that precise continuation in that position in the computation in another node. A naive hash would be a counter of invocations to `logged` in the program execution. The program has to find the last continuation invoked in the remote node and invoke that continuation with the differential log, so that the next continuation is created by replaying it, and the computation continues in the remote node


```Haskell
translate somenode= do
   setContinuation
   hash <- getHash
   log <- getLog
   (lastHash,log') <- getLastLogSent somenode allclosureNodes
   deltaLog <- delta log log'
   sendTo somenode laasstHash deltalog
   insert somenode  (hash, deltaLog) allclosureNodes
   empty


-- allclosureNodes should be a pure container, so different paths of execution
-- have different invoked closure/continuations

getLastLogSent node= do
  lookup node allclosureNodes

delta log log'= ...

setLastLogSent hash node log=
  insert node (hash,log) allclosureNodes

init proc= do
    fork $  do
       (hash,log) <- wait for logs in some port
       cont <- lookup hash coontinuations
       setLog $ Recovering log
       run cont
    proc
```

The delta function has some complexity. Consider this code

```Haskell
do
  logged this
  runAt node1 $ do 
         logged that
         other
  runAt node1 $ logged otherMore
```

The second runAt has `this/e/that/other` as the log of the last invocation to that node and the sending node will have `that` annotated in his state before calling at the second runAt, but clearly if the log at this moment should be `this/other/e`, since the first runAt has been completed and his result, `other` has been returned.

So the execution path is not informative enough. That "e" is due to the runAt that must be executed, but in order to calculate the log for the second runAt, we need to know how many log elements have been executed under that "e". 
The information stored about the execution should be  `this/e(that,other)` instead of `this/e/that/other`. The parenthesis means that under the execution of "e" the path executed was that and the final result, if reached, is `other`.
Now we can calculate the right path by getting that info and discarding the executions "e" which has been completed (have the second element of the parenthesis filled) and instead, substitute it by his result, that is  

```
e(that,other) -> other
```

so that    


this/e(that,other) -> this/other                                                                         (1)

I said that the complete log if we invoke the closure/continuation 0 at the beginning of the remote node is  this/other/e         (2)

So look, because runAt is after all, the composition of two translate's, the last one is the one towards which the invocation should be done, and because it is the last statement, of the previous runAt, the delta log to send to reach the second runAt is, simply "e". that is the delta between (1) and (2)

Now suppose that the remote node want to return back a stream of results. the second translate of runAt, instead of sending the complete log with each result, will send the differential log to the last continuation that my node has stored. That is the one of the first translate.

```Haskell
do
  r <- logged this
  runAt node1 $ logged stream $ proocessChunk r

  stream process= (do abduce; process) <|> stream process
```

this generate threads that executes repeately a process and return back the results.


so that the data that the remote node return back would be  e/chunkresult1, e/chunkresult2... 

The bandwidth optimization is similar to a fast RPC call, since practically only the parameters and the result travel back and forth

The same happens whe we stream from the first node to the second

```Haskell
do
  logged this
  setContinuation
  r <- logged $ stream that
  runAt node1 $ logged $ do
            liftIO $ print r

```

Here we send repeatedly "that" values trought the socket
the frist time we have to address the closure/continuation 0 in the remote node but the program can annotate that the continuation of the first  has been created in the remote node, so subsiguient envoys make use of it and send just `that` values.

Serialization and recovery
--------------------------

Note that for the reduction of (1) and (2) , runAt is a subcomputation, so as I said before(*), simply by adding the result to the previous log before executing the subcomputation should be enough and it should be not neccessary to store the subcomputation log. But we have another problem.

Let's call hard continuation to the one for wich we have reached and we have it captured in a data structure, so we can invoke it at will. A soft continuation is a combination of a hard continuation and a log which is replayed starting from that continuation. When a node receive  request, it receives soft continuations and convert it into hard continuations, so the distributed program execution proceeed that way.

Now we need to manage the memory used by such continuations. Ideally it should be stored outside of main memory, so that after a timeout they would be discarded from main memory, but if at a later time the program could restore it before his invocation. Since a hard cont can be generated by the previous cont and a log and the previous cont can be generated recursively up until continuation 0, which is the beginning of the program, then we can store and recover any hard continuation by simply storing soft continuations logs and references to previous soft continuations. Althoug a hard continuation can not be serialized, it can be regeneraed if necessaary from continuation 0 which is ever in memory. To regenerated a hard continuation is a matter of recursively proceed back until we find a continuation which is alive in memory.

run cont above can be refined to allow continuations to be restored on demand:

```Haskell
init proc= do
    fork $  do
       (hash,log) <- wait for logs in some port
       mcont <- lookup hash continuations -- alive hard continuations
       case mcont of
        Just cont -> do
            setLog log
            run cont
        Nothing -> do
            (cont,deltalog) <- recover hash
            setLog deltalog
            run cont

recover hash= do
    (hash',deltalog) <- load hash
    mcont <- lookup hash' continuations
    case mcont of
        Just cont' -> do
            return (cont',deltalog)
        Nothing -> do
            (cont',deltalog') <- recover hash'
            return (cont',deltalog' <> deltalog)
```
NOTE: There are however other additional ways to avoid abusing main memory. Since the hash depend on his positions on  the code, there are at most one continuation for each `setContinuation` in the code. For some multiuser programs, thiz is too retrictive so it is better to have an additional parameter for setContinuation `sessionid` so that different threads corresponding with different tasks would have different continuations stored. Then, the management by means of timeouts and serializtions to disk becomes necessary.

"load" read the log register stored in disk for each continuation hash. 

Now look at the code of the two runAt. 

```Haskell
do
  logged this
  runAt node1 $ do 
         logged that
         other
  runAt node1 $ logged otherMore
```


A requirement is that we should give life to all intermediate continuations when we restore one of them. if we invoque the second, to force the execution of the internals of the first, we should execute this log:

this/e/that/other/e

while this log is being replayed, it is necessary that all the housekeeping of continuations inside translate is executed, to make sure that their continutions are restored. So even in replay mode, the continuation stuff should be executed.

The first one has a total log of:  this/e,  the second is this/other/e. So the register of the first stored in disk should be:

{previoshash=0, deltalog= this/e(that,other)}

And in the second:

(previoushash=1,deltalog=e)

So that I can extract BOTH the deep log to be executed to restore both continuations this/e/that/other/e  and the shallow log of (2)  this/other/e.

The logs used for the restore goes trough all "e" elements while the logs for invocation only uses the results. That's why it is necessary a detailed storage of the logs when intermediate continuations are involved.

Web requests
------------

Soft continuations are identifiers plus a path. This is perfect for making URL's. If the program that watch the socket could interpret an URL as such. Additionally, any place in the program could be reached by means of an URL.

```Haskell
init proc= do
    fork $  do
       (hash,log) <- wait for logs in some port or URL with format: http://host:port/hash/logged/values
       ....


-- show the URL of any place in the program:
showtURL= do
  Node host port _ <- getMyNode
  currentHash <- getState
  (cont,deltalog) <- lockup currentHash continuations
  liftIO $ print $ http://"<> host <> "/" <> port <>"/" <> deltalog

```

