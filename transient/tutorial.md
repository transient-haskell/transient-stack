    ![](http://upload.wikimedia.org/wikipedia/commons/thumb/9/9f/Orca_pod_southern_residents.jpg/300px-Orca_pod_southern_residents.jpg)

Introduction
------------
This is a quick guide for programmers who want to use Transient. For a description of the internals for haskellers, see the [README](https://github.com/agocorona/transient/blob/master/README.md)

As an alternative tutorial read the[Transient execution model](https://github.com/transient-haskell/transient/wiki/Transient-execution-model) which is like a how-to-get-things-done with Transient libraries.

Transient provides the heavy-lifting effects necessary for solving the problem at hand. Even a beginning Haskell programmer can concentrate on the problem. Without dealing with the Haskell language proper.

For example the Haskell operator `<|>` is used to to manage optional values (`Maybe` types). In transient you can also use it to express parallel or distributed computations. You can use it also to compose widgets in a Web application. Or, in a console application, you can use this operator to compose programs that use console IO.

<small>*Note: This does no mean that the nature of `<|>` has been changed. It only means that an appropriate behaviour has been added to the operator when there are multiple threads, nodes etc.*</small>

Transient is general purpose. That means that front-end web programmers may feel weird that it includes the server side in the same program. The server-side web programmers would be puzzled by the presence of console input primitives and distributed computing. the DC people that are message oriented may be uncomfortable with the availability of distributed map-reduce. The console programmers may be surprised by the fact that multiple threads can get input from the same console input. All of them may find strange that a primitive may return not one, but zero or many result.

But the applications of tomorrow and today need all these components. Just get the components that you need. If you would create a new Facebook, you will need all of them. But for an ordinary application you would need many of them. All these weird effects are necessary for reducing code complexity and creating the most compact and high level code ever. A requirements-specification language that actually run.

All effects can be combined freely: multi-threading, distributed computing, event handling, early termination, state management, Web interfaces, console IO, backtracking. Other effects can be created.

Finalizations are for closing resources and for returning values when processes involving multiple threads have been finished. logging of the execution state to files and recovery of execution state from the log has been implemented. 

Since Transient is not a domain specific language, it does not encapsulate effects to restrict the programmer to a single domain. It is general-purpose. However you can restrict it to generate your own EDSL using common Haskell techniques.

Transient does not emphasize the purity of Haskell. It tries to fulfill the promise of Haskell as the finest imperative language. Ninety percent of computer engineering is about programming effects (except number crunching). Transient is for these kinds of problems (and for number crunching too).

Consider this program, written in Haskell:  (if you [have stack installed](https://haskell-lang.org/get-started), you can paste it to a file and execute it in the command line)


```haskell
#!/usr/bin/env stack
-- stack --install-ghc --resolver lts-6.23 runghc  --package transient 
import Control.Monad (forM_)

main = do
    putStrLn "What is your name?"
    name <- getLine
    forM_ [1..10 :: Int] $ \ n -> do
        print name
        print n
```

This program prints your name ten times. It uses the IO monad. That means that the do block runs IO computations. Haskell has no loop keywords so `forM` is a normal routine. It takes ten integers in succession and calls an expression (an action, since it performs IO) with each one of the values.

Neither `[1..10]` is a language construction. It is a list of one to ten Integers.

Let's look at how this program should look like using the Transient monad:


```haskell
#!/usr/bin/env stack
-- stack --install-ghc --resolver lts-6.23 runghc   --package transient 
import Control.Monad (forM_)
import Control.Monad.IO.Class (liftIO)
import Transient.Base

main = keep $ do
    name <- input (const True) "What is your name? " :: TransIO String
    forM_ [1..10 :: Int] $ \ n -> liftIO $ do
        print name
        print n
```

Almost exactly the same. Since the do block now run the Transient monad, I use `keep` to convert it to IO, which is what main expects:

```haskell
keep :: TransIO a -> IO a
```

`input` is a Transient primitive for console IO. It uses a validation expression (`const True`), meaning that it accepts any string. You will read more about it later.

Since `print` and all the rest of the computations run in the IO monad, I must use `liftIO` to lift them to the Transient monad.

I had no advantage using `TransIO` here. It is a chain of liftings and un-liftings between TransIO and IO to do things that IO could do alone. 

What if I wanted to run the loop in ten parallel threads?

```haskell
#!/usr/bin/env stack
-- stack --install-ghc --resolver lts-6.23 runghc   --package transient 
import Control.Monad.IO.Class (liftIO)
import Transient.Base
import Transient.Indeterminism

main = keep $ do
    name <- input (const True) "What is your name? " :: TransIO String
    n <- choose' [1..10 ::Int] 
    liftIO $ do
        print name
        print n
```

Now this is another story: this time `choose'` is a Transient primitive. It stops the current thread and launches a new thread for each of the elements in the list. Since the main thread dies, the computation could finish before the launched threads complete. This is the reason for the name "transient": because it manages transient threads. This is why it is called `keep`. It prevents the program from exiting when the main thread dies. 

This premature death of the main thread is one of the unique characteristics of transient. Usually a program "hang by a thread", the main thread, which is initiated at the beginning of the program and controls everything. It may schedule other threads and execute the backbone of the computation. In transient, the backbone is executed by many threads that are created and die along the computation.

`exit` escapes the `keep` block:

``` haskell
main= do
   r <- keep $ do
           ...
           ...   
           -- in some thread:  
           exit "hello"
   print r 
```
That will print "hello" and finish.  This solution is not definitive since is not type safe, but it is simple.

Asynchronous primitives
-----------------------
Asynchronicity is at the heart of Transient. It was explicitly done to allow full composability in presence of asynchronous  or blocking IO. That means that you don't have to break your program in pieces, just because it receives asynchronous inputs like events, network requests, hardware interrupts or console input or because you have blocking IO calls.

How is `choose` defined?  It uses `async`.  To get an idea of what `async` does, look at this program:

```haskell
#!/usr/bin/env stack
-- stack --install-ghc --resolver lts-6.23 runghc   --package transient 
import Control.Monad.IO.Class (liftIO)
import Transient.Base
import Control.Concurrent

main = keep $ do
    th <- liftIO myThreadId
    liftIO $ print th
    r <- async $ do
        threadDelay 1000000
        return "hello"
    th' <- liftIO  myThreadId
    liftIO $ print th'
    liftIO $ print r
```

`async` stops the initial thread and spawns another that runs what is after it. This includes his parameter (an IO computation) and continues with the rest of the computation. The great advantage of `async` is that it is composable:

```haskell
#!/usr/bin/env stack
-- stack --install-ghc --resolver lts-6.23 runghc   --package transient 
import Control.Monad.IO.Class (liftIO)
import Control.Applicative
import Transient.Base
import Control.Concurrent

main = keep $ do                                                 -- thread 1
    r <- (,) <$> async (do threadDelay 1000000; return "hello")  -- thread 2
             <*> async (return "world")                          -- thread 3
    liftIO $ print r                                             -- thread 2
```

prints `("hello","world")` .

The operators `<$>` and `<*>` are standard in Haskell. THey are loosely called "applicative" operators. 
the `(,)` compose two operands and generate a 2-tuple. To give a simpler example:

``` haskell
(+) <$> return 2 <*> return 2                              === return 4
```
since `return 2` is `2` within a monad constructor,  it can not be summed to itself with `(+)` directly, and this is the purpose of applicative operators: to allow it. 

This is an example of how transient can express concurrency in a composable way.

In this applicative expression, both `async` operations run in parallel, within different threads. When 2 finishes, it inspect the result of 3. If it has no result yet, the inspecting thread stores its result and dies. When 3 finishes, it sees the result of 2. Then, it completes the expression and prints the result. The computation brought to `async` runs in the IO monad:

```haskell
async :: IO a -> TransIO a
```

what if, in the above composition, one of the `async` statements were suppressed?

```haskell
#!/usr/bin/env stack
-- stack --install-ghc --resolver lts-6.23 runghc   --package transient 
import Control.Monad.IO.Class (liftIO)
import Control.Applicative
import Transient.Base
import Control.Concurrent

main = keep $ do                                                    -- thread 1
    r <- (,) <$> async (do threadDelay 1000000; return "hello")     -- thread 2
             <*> liftIO (return "world")                            -- thread 1
    liftIO $ print r                                                -- thread 2
```

It produces the same result, but this time, the original thread (1) is the one that runs the IO computation of the second term. Since 1 find that the other operation has not finished, it dies in peace. When 2 finishes, it completes the applicative and print the result.

Let's see what the difference with this other expression is:

```haskell
#!/usr/bin/env stack
-- stack --install-ghc --resolver lts-6.23 runghc   --package transient 
import Control.Monad.IO.Class (liftIO)
import Transient.Base
import Control.Concurrent
import Control.Applicative ((<|>))

main = keep $ do
    th <- liftIO myThreadId                                   -- thread 89
    r <- async (do threadDelay 1000000; return "hello")       -- thread 90
         <|> async (return "world")                           -- thread 91
    th' <- liftIO myThreadId                                  -- thread 90 and 91
    liftIO $ print (th, th', r)                               -- thread 90 and 91
```

Output:

    (ThreadId 89,ThreadId 91,"world")
    (ThreadId 89,ThreadId 90,"hello")
 
Notice that there are two responses instead of one. I included the thread IDs to show what happens here: The alternative expressions trigger two parallel independent threads: 90 and 91.  The first that finishes is the one of "world" since it has no delay.

But if we suppress the second async (and put `liftIO`, which has the same type):

```haskell
#!/usr/bin/env stack
-- stack --install-ghc --resolver lts-6.23 runghc   --package transient 
import Control.Monad.IO.Class (liftIO)
import Transient.Base
import Control.Concurrent
import Control.Applicative ((<|>))

main = keep $ do
   th <- liftIO myThreadId                              -- thread 91
   r <- async (do threadDelay 1000000; return "hello")  -- thread 92
        <|> liftIO(return "world")                      -- thread 91 
   th' <- liftIO myThreadId                             -- thread 91 and 92
   liftIO $ print (th, th', r)                          -- thread 91 and 92
```

The output is slightly different:

    (ThreadId 91,ThreadId 91,"world")
    (ThreadId 91,ThreadId 92,"hello")

Now the thread that prints "world" is the original thread (91) that initiated the computation.

Thus, the operator `<|>` (called Alternative operator) can express parallelism with `async`. 

Note that, unlike other libraries, there is no main thread exectuting an "await" primitive. As seen in the example with applicative (<*>) any thread can continue the backbone of the computation or all of them, as seen in the examples with the alternative operator `<|>`. 

Some recapitulation: Presenting a synchronous interface to something inherently asynchronous is a great abstraction in computing. This is what the OS does with files: When a program reads a file, one pretends that the program waits for the output of the file system. But really, the program was stopped. It is the OS (or the GHC runtime) that stops your thread and resumes it when the data is available. That is what `async` does, but since it has no ownership of thread management, it restarts it as another thread. The OS, or the GHC runtime does a monadic friendly composition for IO operations, but it does not allow the same for applicative and alternative operations. As seen from a single thread, IO operations block, so they can't compose well. This implies that your program can't compose, and at the same time perform parallelism and concurrency. This is the problem that `async` et al solves; It allows composing expressions that manage thread parallelism and concurrency.

Usually, when doing concurrency by means of forkIO or with some higher level packages like [`async`](https://hackage.haskell.org/package/async), a controlling thread waits for other spawned threads, so the resulting component is inherently single-threaded. Transient is inherently multi-threaded and can generate multi-threaded components that are composable.

If you know how to manage folds, now you can imagine how to define `choose` with `foldl` `async` and `<|>`

Note that in the alternative operator `<|>` by definition, if the first term does not fail, the second never runs. `async` forces the failure of the current executing thread so it gives the opportunity to run the second. This allows `<|>` to compose an arbitrary number of `async` computations.

Failure in the alternative computation is expressed with `empty`. 

`stop` is a synonym. It interrupts the current execution sequence. This effect is called "early termination"

```haskell
#!/usr/bin/env stack
-- stack --install-ghc --resolver lts-6.23 runghc   --package transient 
import Control.Monad.IO.Class (liftIO)
main = keep $ do
     liftIO $ print "hello"
     stop
     liftIO $ print "world"
```

never prints "world"

```haskell
#!/usr/bin/env stack
-- stack --install-ghc --resolver lts-6.23 runghc   --package transient 
import Control.Monad.IO.Class (liftIO)
import Transient.Base

main = keep $
    do liftIO $ print "hello"
       stop
       liftIO $ print "world"
    <|> (liftIO $ print "another world")
```

prints 

    "hello"
    "another world"


`async` is a form of asynchronous execution. But there are more asynchronous primitives. `waitEvents` performs async repeatedly:

```haskell
#!/usr/bin/env stack
-- stack --install-ghc --resolver lts-6.23 runghc   --package transient 
import Control.Monad.IO.Class (liftIO)
import Control.Concurrent(treadDelay)
import Transient.Base

main = keep $ do
    r <- waitEvents $ do
             threadDelay 1000000
             return "hi"
    liftIO $ print r
```
prints "hi" once each second. 

imagine how `waitEvents` could be used to spawn blocking IO calls that wait for input coming through a communication channel.

The general form of parallelism is `parallel`. All the asynchronous primitives use `parallel`. 

Let's see for example how an implementation of `choose` is implemented in terms of `parallel`:

```haskell
import Transient.Base

choose  ::  [a] -> TransIO a
choose [] = empty
choose xs = do
    evs <- liftIO $ newIORef xs
    r <- parallel $ do
        es <- atomicModifyIORef' evs $ \es -> let !tes = tail es in (tes,es)
        case es of
            [x] -> return $ SLast x
            x:_ -> return $ SMore x
    return $ toData r
  where
    toData r = case r of
        SMore x -> x
        SLast x -> x
```

`parallel` creates threads that continue the monadic sequence, like `waitEvents`. But it also tells the computation if the current result is the last, or if there are more. It also may signal errors or the "done" condition. In the above example, only "more" and "last" are used. The types are:

```haskell
parallel :: IO (StreamData b) -> TransientIO (StreamData b)

data StreamData a = SMore a | SLast a | SDone | SError String deriving (Typeable, Show,Read)
```

`SLast` `SDone` and `SError` prevent `parallel` from spawning the IO computation again. 

In the other side, a `SMore` result forces the re-execution of the IO computation. Parallel re-execute the IO computation either in a new thread or when a previous thread finishes his work. That depend on the limit of threads that you have assigned to the branch (see thread management). 

Now you may understand the definition of `choose` above. 

On the other hand, `waitEvents` spawns the IO computation endlessly:

```haskell
waitEvents :: IO b -> TransIO b
waitEvents io = do
    SMore r <- parallel (SMore <$> io)
    return r
```

Since asynchronicity in transient is not based on a mutable data structure that must be passed on to finally wait for the result (a promise), transient is endlessly composable. Promises-based components can not be combined to create bigger units.

To summarize: when called, a transient component can return zero or more responses in different threads that continue the execution after the call. But also can reuse a single thread for many responses. This can be controlled with thread primitives.



Thread control
--------------

`choose` spawns a thread for each entry. That may be not optimal in case of light work, like in the above examples. It may be good to use `choose` to process a list of values with moderate parallelism, without spawning a thread for each result . To limit the number of threads, use `threads`:

```haskell
#!/usr/bin/env stack
-- stack --install-ghc --resolver lts-6.23 runghc   --package transient 
import Control.Monad.IO.Class (liftIO)
import Control.Concurrent(threadDelay)
import Transient.Base
import Transient.Indeterminism
main = keep $ do
    name <- input (const True) "What is your name?" :: TransIO String
    n <- threads 2 $ choose [1..10 ::Int] 
    liftIO $ do
        threadDelay 1000000
        print name
        print n
```

You can see how the number of threads change the way the results are printed: With no thread limit, all threads spawn at the same time. After a second, all the results are presented simultaneously. With `threads 1` you'll have one result each second and so on.

A different thread control primitive is `oneThread`: If a new thread is spawned, it kills all the living threads that were spawned previously by the current computation and all their children. It has a reasonable use with `parallel` and `waitEvents` rather than with `choose`, since the latter produces bursts of threads that would try to kill between themselves, while the former ones produce them in sequence.

Factoring out events and behaviours
-----------------------------------

One of the good thing about transient is that it deals with asynchronicity using the simple and intuitive model of normal, synchronous programs. The complexity that is saved for the programmer is illustrated by this paragraph. If you know nothing about Functional Reactive Programming (FRP), please skip this paragraph. If you know and you are interested about the relation of transient with concepts of FRP, here it is the place to read:


What this (complete, executable) program do?

```haskell
#!/usr/bin/env stack
-- stack --install-ghc  runghc  --package transient 

import Transient.Base
import Transient.Indeterminism
import Control.Concurrent
import Control.Monad.IO.Class (liftIO)

fast  =  do 
     r<- choose [1..]    
     liftIO $ threadDelay 1000000
     return r

slow= do 
     r<- choose $ mconcat $ repeat ["cat","dog"]   
     liftIO $ threadDelay 5000000
     return r

main = keep' $ do
    r <-  threads 1 $ (,) <$> fast <*>  slow
    liftIO $ print r


```
```
$ ./prog.hs
(4,"cat")
(5,"cat")
(6,"cat")
(7,"cat")
(8,"cat")
(9,"cat")
(9,"dog")
(10,"dog")
(11,"dog")
(12,"dog")
(13,"dog")
(14,"dog")
(14,"cat")
(15,"cat")
(16,"cat")
(17,"cat")
(18,"cat")
(19,"cat")
(19,"dog")
(20,"dog")
(21,"dog")
(22,"dog")
.......
```

The program prints an infinite stream of 2-tuples, since there are two `choose` expressions within an applicative expression that construct such tuples. The task is done with two threads: the main one, already running in the monad and the new one of `threads 1`. Then, there is a single thread for each  asynchronous `choose` sentence. Since the first term give results every second but the other does it every five seconds, the whole expression does not produce any duple until both terms have results. this is after five seconds. Then, the first element continues producing results once every second. Conceptually the fastest term perform a sample of the slower one, which return the value of his last event. This is not all, but it is enough to clarify what I want to say next:

In (discrete) Functional Reactive Programming, the elements that store and compute event values and arrival times are called `behaviours`. For performance reasons, it is a common optimisation to store and handle only the last value.  The Applicative operators of Transient behaves much like these kind of `behaviours`, since they store the last event value, but the program as a whole is not forced to change the execution model to another specialised for functional reactive programming. Transient does not use special data types to deal with events or behaviours.

*The complication associated with the management of events and behaviours have been eliminated!*

looking with more detail, note that the first two results appear simultaneously: Therefore when `cat`is returned by the thread in the second term, it reads '4' in the  first term and return `(4,"cat")`. Simultaneously, '5' arrives to the first term and read also `cat` from the second, so it return `(5, "cat")`. The same duplicity appears when both streams of events arrive simultaneously every five seconds. So not only the faster term samples the slowest one, but also the slowest term samples the fastest one.


Console Input/Output
--------------------

To allow composability and multi-threading in console applications, console input must be non-blocking. This is a characteristic of the transient input primitives. You saw `input`, which waits for one string. `option` is another input primitive:

```haskell
#!/usr/bin/env stack
-- stack --install-ghc --resolver lts-6.23 runghc   --package transient 
import Control.Monad.IO.Class (liftIO)
import Transient.Base
main = keep $ do
    r <- option "op" "choose this option"
    liftIO $ print r
```

which outputs

    Enter  "ps"     to: show threads
    Enter  "log"    to: inspect the log of a thread
    Enter  "end"    to: exit
    Enter "op"  to: choose this option"
    >op

    option: "op"
    "op"

The first three lines are default options, introduced by `keep` to end the keep block. The fifth is the input, the seventh tells that "op" has been detected and the last is the result.

`option` can be composed:

```haskell
#!/usr/bin/env stack
-- stack --install-ghc --resolver lts-6.23 runghc   --package transient 
import Control.Monad.IO.Class (liftIO)
import Transient.Base
import Control.Applicative ((<|>))

main = keep $ do
    r <- option "op1"  "op1" <|>  option "op2" "op2"
    liftIO $ print r
```
you can enter either of the two options. If you don't enter either of them, the computation does not continue.

`option`uses `waitEvents` and it is feeded by a background thread spawned by `keep`.

options can create menus and sub-menus. This code:

```haskell
#!/usr/bin/env stack
-- stack --install-ghc --resolver lts-6.23 runghc   --package transient 
import Control.Monad.IO.Class (liftIO)
import Transient.Base
import Control.Applicative ((<|>))

main = keep $ do
    option "ops" "see the two options"
    r <- option "op1" "op1" <|> option "op2" "op2"
    liftIO $ print r
```
shows the two options only if you enter "ops":

    Enter  "end"    to: exit
    Enter  "ops"    to: see the two options
    >ops
    "ops" chosen
    Enter  "op1"    to: op1
    Enter  "op2"    to: op2
    >op1
    "op1" chosen
    "op1"
    >op2
    "op2" chosen
    "op2"
    >ops
    "ops" chosen
    Enter  "op1"    to: op1
    Enter  "op2"    to: op2

But also note that whenever you enter "ops" the two options are displayed again. 

Note that all the options are active simultaneously. If you have complex trees and you want to make active a single branch, use `oneThread` associated with the alternative expression. It disables (kills) the options that don't correspond with the current branch that is being executed. Remember that `option` and other repetitive asynchronous primitives like `waitEvents`, never die, so each time you press `ops` two new `option` process are created that superpose with the older ones. That is the reason `oneThread` is necessary when options are in cascade.

```haskell
oneThread $ option "ops" "see the  options"
oneThread $ option1 <|> option2 <|> option3....
```

What happens if in the previous example I add  `<|> return ""`  to the first option?

```haskell
#!/usr/bin/env stack
-- stack --install-ghc --resolver lts-6.23 runghc   --package transient 
import Control.Monad.IO.Class (liftIO)
import Transient.Base
import Control.Applicative ((<|>))

main = keep $ do
    option "ops" "see the two options again" <|> return ""
    r <- option "op1" "op1" <|> option "op2" "op2"
    liftIO $ print r
```

Yes, the three options are displayed at the first shot, since `return ""` makes the computation progress beyond the first option:

    Press end to exit
    Enter  "ops"    to: see the two options again
    Enter  "op1"    to: op1
    Enter  "op2"    to: op2
    >op1
    "op1" chosen
    "op1"
    >op2
    "op2" chosen
    "op2"
    >ops
    "ops" chosen
    Enter  "op1"    to: op1
    Enter  "op2"    to: op2

option does not only return strings. It can return anything that has Read/Show instances:

```haskell
option :: (Typeable b, Show b, Read b, Eq b) => b -> String -> TransientIO b
```

This is a Haskell "boutade":

```haskell
#!/usr/bin/env stack
-- stack --install-ghc --resolver lts-6.23 runghc   --package transient 
import Control.Monad.IO.Class (liftIO)
import Transient.Base
import Control.Applicative 

main= keep $ do
   r<- foldl  (<|>) empty [option (i :: Int) ("return this number")| i<- [1..5 :: Int]]
   liftIO $ print r
```

It displays five integer options to choose from.

when `input` is invoked, it ask for an expression until it validates, but once it is validated, it does not ask again.

```haskell
input :: (Typeable a, Read a) => (a -> Bool) -> String -> TransIO a
```
As any transient primitive, it is not blocking. While `input` is running the  `option`s are active and watching, so you can interrupt the current branch by activating an `option`.

You can enter two or more inputs for `option` and `input` in the same line using the character slash as separator:

    this/is/an/example

In future versions, space will also behave as separator and double quotes are used to  scape spaces and slashes

Command-line input
-------------------

The initialization primitives also read the command line and takes the -p option as the path that contains the first inputs for the program. This is a real example:

   > ./distributedApps.hs -p start/localhost/8080/add/localhost/2000/y/add/localhost/2001/y

it start the example program, initializes the server in the port 8080. Then it connects with two nodes at ports 2000 and 20001 respectively. [Video](https://www.livecoding.tv/agocorona/videos/M5axK-testing-webcloud-computing-library-2)

This program uses `option` and input to read the command line. Since these primitives work in parallel with the rest of the functionalities of the program, I can also add more servers at run-time too.

Programmer defined State
------------------------
You can define your own data types, store them  using `setData` (or the synonym `setState`) and read them later using `getSData` (or `getState`). 

Session state is handled like the state in a state monad (so state is **pure**), but you can store and retrieve as many kinds of data as you like. The session data management uses the type of the data to discriminate among them. But the semantic is the same. This means that if you add or update some session data, the change is available for the next sentences in the execution, but not in the previous ones. state in transient is pure. *There is no global state at all*.

```haskell
#!/usr/bin/env stack
-- stack --install-ghc --resolver lts-6.23 runghc   --package transient 
import Control.Monad.IO.Class (liftIO)
import Transient.Base
import Data.Typeable

data Person = Person{name :: String, age :: Int} deriving Typeable

main= keep $ do
     setData $ Person "Alberto"  55
     processPerson

processPerson= do
     Person name age <- getSData
     liftIO $ print (name, age)
```

I like how `getSData` return the data, apparently out of thin air! It uses the type of the result to locate the data in the global state of the Transient monad. For this reason it needs to be `Typeable`.

getSData :: Typeable a => TransIO a

What happens if there is no such data? The computation simply stops. If `doSomething` finds no Person data it stops the current branch.

This may be good specially when there are alternative computations:

```haskell
processPerson <|> processOther
```

This runs processOther if there is no Person data.

If the type system can't deduce the type of the data that you want to recover, you can annotate the type:

```haskell
getSData :: TransIO Person
```

Sometimes you need to be sure that there is data available. 

The line below returns `p` if there is not data stored for the type of `p`:

```haskell
getSData <|>  return p
```
This other does the same than above, but sets the session data for that type:

```haskell
getSData <|> (setData p >> return p)
```
This one produces an error if the data is not available:

```haskell
getSData <|> error "Person data not avilable"  :: TransIO Person
```
This one produces a message, but continues execution if an alternative branch is available:

```haskell
getSData <|> (liftIO (putStrLn "Person data not avilable") >> stop) :: TransIO Person
```

Finally, if we are insecure, this is the strongly typed, manly state primitive [`get`](https://hackage.haskell.org/package/mtl-2.2.1/docs/Control-Monad-State-Lazy.html) defined in terms of `getSData`. This is for an `Int` state, but it can be used for any kind of data:


```haskel
 -- defined one time
 get :: TransIO Int
 get= getSData <|> return 0  -- 0 equivalent to the seed value in the state monad, 
                             -- when runStateT is called.
 
```
You can define one different for each of your data types: `getMyNiceRegister` `getMyNewNewtype`  etc.

State data does not pass trough node boundaries unless you use normal variables, or `copyData`:

```haskell

do
    dat <- local $ getSData <|> myUserDataDefault
    r <- runAt node do
              use dat
          ...
    ....

```

```haskell
do 
    copyData $ myUserDataDefault
    r <- runAt node $ do
          dat <- getSData
    continuelocally r
    .....
```

This assures that the remote code has the user data. In the first case, it is a normal variable. In the second one, it is copied in the remote node as an state variable. 

De-inverting callbacks
----------------------

With the `react` primitive:


```haskell
    do
       ....
       x <- react  addCallback  (return ())
       continue x
       more continue
       etc
```

Will set the continuation of react as handler, using  the `addCallback`  provided by the library (substitute it by your real primitive name). `x` is the parameter passed to the callback and becomes what `react`return to the continuation.

The second parameter `return ()`  is just in case addCallback need some return value. That happens with HTML DOM events, which need  `true` of `false` to either stop propagating the event or not.

This is real code used by transient-universe to process incoming messages to the browser from the server. It uses the [GHCJS callback framework](https://github.com/ghcjs/ghcjs-base/blob/master/GHCJS/Foreign/Callback.hs) and the websocket API for javascript, which, as always, is callback-based:

```haskell
wsRead :: Loggable a => WebSocket  -> TransIO  a
wsRead ws= do
  dat <- react (hsonmessage ws) (return ())
  case JM.getData dat of
    JM.StringData str  ->  return (read' $ JS.unpack str)                
    ...

hsonmessage ::WebSocket -> (MessageEvent ->IO()) -> IO ()
hsonmessage ws hscb= do
  cb <- makeCallback MessageEvent hscb
  js_onmessage ws cb

foreign import javascript safe
    "$1.onmessage =$2;"
   js_onmessage :: WebSocket  -> JSVal  -> IO ()
```

Backtracking
------------
Using backtracking for undoing actions was one of the first effects that I programmed in Transient, and I gave not much attention since then. I did not realize how good and general it is until you need it. 

Imagine that you do make a reservation, open a file, update a database or whatever you need to do before doing another action, but this action either fails or it is not finally performed. Imagine that there is not one but n actions of this kind that you must undo, since step n+1 is aborted by whatever reason internal or external to the program. Then is when the powerful mechanism of transient backtracking can be used.

Backtracking in Transient is within monadic code.  The example below illustrate a typical problem: a product is reserved, then a second database is updated, and then, the payment is performed. But the payment fail. Then it executes `undo`. This initiates backtracking. This execute the `onUndo` sections of the previous sentences in reverse order. first, the database update is undone, and second, the product is un-reserved.

```haskell
#!/usr/bin/env stack
-- stack --install-ghc --resolver lts-6.23 runghc   --package transient 
import Control.Monad.IO.Class (liftIO)
import Transient.Base
import Transient.Backtrack

main= keep $ do
       productNavigation
       reserve
       updateDB
       payment


       liftIO $ print "done!"

productNavigation = liftIO $ putStrLn "product navigation"

reserve= liftIO (putStrLn "product reserved,added to cart")
                 `onUndo` liftIO (putStrLn "product un-reserved")

updateDB=  liftIO  (putStrLn "update other database necesary for the reservation")
                 `onUndo` liftIO (putStrLn "database update undone")

payment = do
           liftIO $ putStrLn "Payment failed"
           undo


```

The execution of further undoing actions can be stopped in any undoing action if it calls `backCut`. This would stop backtracking and would finish execution.  `retry` would stop backtracking and would resume execution forward from that backtracking point on.

This has application not only for undoing IO actions it can be considered as a generalized, more functional and composable form of exception management. 

In the last version `undo`, `onUndo`, `retry` and `undoCut` have a generalized form which receive and additional parameter of a programmer-defined type: these generalizations are called `onBack`, `back`, `forward`, `backCut` respectively.  

By managing different parameter types it is possible to manage different kinds of backtracking and the `onBack` method can be informed about the  reason of the backtracking action.

in the last version, undo actions use the () type:

```haskell
x `onUndo` y= x `onBack` () y
undo= back ()
retry = forward ()
```

Exception handling
------------------------------------
In a heavily multithreaded programs, exceptions are of little help since often the exceptions must be communicated between threads and typically in long running programs, for example in servers, the exception code makes programs hardly readable. This is because the exception mechanism makes the code imperative and non-composable.

`onException` uses the backtracking mechanism describe above, but yet uses the same exception definitions of `Control.Exception`.  If an IO computation produce an exception, it triggers the backtracking mechanism described above, so any handler that match the exception type will be executed in reverse order. There is also `throwt` that triggers an exception in the transient monad. The basic syntax is: 

```haskell
onException $ \(e :: IOError) -> handler e
rest of
the code
that is, the continuation
```

In the example above, an exception of the type IOError in ANY THREAD of the continuation will execucute the handler.

This pseudocode is used in Transient. restart a node in case it does not respond:

```haskell
  do
     onException $ \ (e :: ConnectionError) -> do restart_the_node; continue
     connect node
     ...
```

`continue` abort the execution of further exception handlers and resume the execution, so it tries to connect again.

As always happens with backtracking, `onException` handlers can not escape the main execution flow. Once all exception handlers have been executed, if there is no `continue` in any of them, the thread stop. This is a guarantee that avoid exception hell. 

Another nice feature is that it works with multi-threading. It means that the continuation can spawn threads and all of them will backtrack.  Also a handler can spawn threads by calling other transient primitives. 

The state is not rolled back when backtracking is done, so you have the state as was when the exception was raised:


``` Haskell
#!/usr/bin/env stack
-- stack --install-ghc --resolver lts-6.23 runghc  --package transient 

{-# LANGUAGE ScopedTypeVariables #-}
import Transient.Base
import Control.Applicative
import Control.Monad.IO.Class

import Control.Exception hiding (onException)

main= keep' $ do
    setState "hello"
    oldState <- getState
    onException $ \(e:: ErrorCall) -> do
                          liftIO $ print e
                          newState <- getState <|> return "no state!"
                          liftIO $ putStrLn newState
                          liftIO $ putStrLn oldState
                          exit()
    
    setState "world"
    throwt  $ ErrorCall "triggered by throwt" 
     -- try the following instead of throwt, and see the difference: 
     -- error "triggered by a IO error (throw)"
    return ()
```

This program would print  "world" and then "hello". If you want the previous state, put it in a variable and use it inside the handler, like `oldState`. The exception preserves the state of the computation when the exception was triggered. This allows performing sophisticated backtracking also with exceptions, like the case described in the previous paragraph.


Note that this is not the  `onException` from Control.Exception. It is a transient primitive.


to exit the execution flow  and execute an alternative branch `catcht` has the semantics of `catch` but it works in the Transient monad. So it works with multi-threading and other transient effects. 

`throwt` trigger an exception in the transient monad.

```haskell
throwt :: Exception e => TransIO a
```
If the exception is triggered outside of the Transient monad, for example in pure code (like `head []`) or in the IO monad the handler is called but the state is not preserved. See [this discussion](https://gitter.im/Transient-Transient-Universe-HPlay/Lobby?at=5c8d8ada52c7a91455a80954) for details.


Finalizations
=============

There is an special type of backtracking  triggered with `finish` (for lack of better name) that is used for finalization purposes.  `onFinish` will subscribe a programmer-defined computation that will be called when there are no more thread activity under it. It may be used to close resources after a process. Finalizations are called automatically when all the exceptions and backtrackings have been already executed and all the threads under it consumed.

finalizations use the backtracking mechanism described above, but they are only triggered when there are no more threads running. Previously finalizations were an special kind of exceptions, but in the new version they are a completely new mechanism. To understand the reason for the introduction on finalizations as a different mechanism it is necessary to recap some design assumptions of Transient in a long paragraph that you may obviate if you don´t want to know the details:

______BEGIN RECAP

In Transient, multithreading has no master-slave relationship. That also happens in the distributed computing model of transient too. That means that there are no master thread which launch other threads for auxiliary work and then they get back to him. In fact the thread which continues after an operation may not be the one which launched it. In concurrent primitives like `collect` or expressions thata are combinations of the <*> operator, the thread which continues is the last one which finalized his work the latest. This is unlike any other library know by me in any langauge.

Moreover, there are primitives like `parallel` or `choose`, which may launch a number of threads which will continue the execution in parallel. This one-to-many spawning is also unseen in computing as far as I know.

This is as it is because it is very useful: This allows to express concurrence (the first) without resorting to uncomposable forks and joins. The second allows streaming and server-side code with many clients while maintaining composability, which is a superior kind of modularity. Also avoids explicit loops in the code, which are a source of problems.

However, this add some problems to be solved. Since no thread is the master thread, all the threads inherit the exception stack.

-- What is the exception stack?
-- Good question:

Transient also has a unique system of exceptions and backtracking in which exception handlers are like train stations where the train (each individual thread) is "repaired" from his malfunction and is resumed to go forward from that station on, or, in the other side, if it is necessary to go further back to the previous station (previous exception handler in the stack), until the first one, which is included in the code of `keep` which prints an error in the console.

Therefore, an exception in any thread will trigger the exception mechanism. So I can not manage resources with exceptions. Why? because if I close a resource in an exception handler, it could be closed many times, and this may not be good for some resources.

Also, if I close the resource when some thread finishes, There may be other threads that still are trying to access it. This was a problem with the previous solution which was ok for a single threaded process, but not for the general case.

What is the solution? Finalizations. but Well-done finalizations. A finalization should be called once, when the last thread which has passed trough it have finished, including the execution of all their exceptions and backtrackings.

finalizations are also backtracking stacks. Each one of them are for a type of value. Exception stacks are for SomeException. Finalization stacks are for Finish reason where reason is a string which describes the cause of the finalization. While the exception handler only triggers when the "subtype" of the exception match with the argument expected, the finalization handlers only triggers if the thread has zero siblings. This means that it is the last one.

If the thread has more siblings then the handler will not be called and obviously, the other finalizations that are above it will not be needed to be checked. If the thread is the last, then it is executed and further finalizations in the stack are checked recursively.

_____END RECAP

This is an example of a program using a finalization.The code spawn three threads by choose. I labeled them using `labelState` so that they could be identified better with `showThreads` which print the thread stack. At the end of the execution of the three threads the finish message is printed. The `\r`  parameter of the lambda has the identifier of the last thread which ran the code and the cause of his finalization:

```haskell
imports..

main=   keep' $ do
    onFinish $ \r ->  liftIO $ print ("finish",r)
    i <-  choose[1..3]
    labelState $ fromString $ "thread from "++ show i
    th <- liftIO $ myThreadId
    topState >>= showThreads
    liftIO $ print ("end",th)

root@38f71a9e8242:/projects/transient-stack/transient/tests# runghc  -w -i../src -i../../transient/src Test.hs
("end",ThreadId 87)
---------Threads-----------
top("end",ThreadId 88)
 83("end",ThreadId 86)

  work 84
    work 85
      work,thread from 3 86
        work,thread from 1 87 <--
        work,thread from 2 88
---------Threads-----------
top 83
  work 84
    work 85
      work,thread from 3 86
        work,thread from 1 87 dead
        work,thread from 2 88 <--
---------Threads-----------
top 83
  work 84
    work 85
      work,thread from 3 86 <--
        work,thread from 1 87 dead
        work,thread from 2 88 dead
("finish","(ThreadId 86,\"async thread ended\")")
```
NOTE: `onFinish` reset the flag that indicates if free threads are created or not, so threads are not created free. Finalizations do not work if the state spawn free threads. They are threads which use `freeThreads` which are not accounted in the thread stack and therefore the finalization can not check if his state has running child threads or not. however, you can use finalizations within a free thread since `onFinish` reset the flag.

In the same way I've created a binary onFinish which will return a result when all the threads of the first operand terminates so it can return a result. 

This is an applicability schema:

```haskell
main=   keep' $ do
    container <-  create some mutable container to gather results
    results <- (SomeProcessWith container >> empty) `onFinish'` \_ -> return container
```

What is the output of:

```Haskell
includes ...

main=   keep' $ do
    r <- return "hello" `onFinish'` const (return "world")
    liftIO $ putStrLn r
```
???

Let's run it:
```
tests# runghc  -w -i../src -i../../transient/src Test.hs
hello
world
```

Another addition is `tmask` which protect from asyncronous exceptions. They could trigger after opening the resource, but before the installation of the finalization so that they can kill the thread before closing. To avoid this, the pattern is:

```haskell
do
    resource <-  tmask $ do
                res <- openResource
                onFinish $ \_ -> closeResource res
                return res

    codeThatUsesResource resource
```

   ....
This is equivalent to `bracket openResource closeResource $ codeThatUsesResource` but instead of working for a single thread, it works for multithreading and any other effect. (Or it should work)

We could isolate this pattern as a primitive `openClose`, which open a resource, use it in a process and close it automatically when the process has finished:

```haskell
openClose :: (TransIO a) (a -> TransIO ()) -> TransIO a
openClose open close= tmask $ do
                res <- open
                onFinish $ \_ -> close res
                return res
```

Scary note: The "open" of openClose above is a transient computation, therefore it can return a stream of resources, which will be closed when processed. See the next paragraph:

Multi-threaded non-determinism
-----------------------------
`choose` was mentioned earlier. It is a basic multi-threaded non-deterministic primitive. Any combination of `async` and `<|>` can perform multi-threaded non-determinism. You can see some examples above, in the introduction.

Any example of non-determinism that works for the list monad can run in the Transient monad. (For newcomers: Think in non-determinism and 'the list monad' as a kind of routine that return many results instead of a single one)

```haskell
#!/usr/bin/env stack
-- stack --install-ghc --resolver lts-6.23 runghc   --package transient 
import Control.Monad.IO.Class (liftIO)
import Transient.Base
import Transient.Indeterminism
import Control.Concurrent

main=  keep $ do
      x <- choose  [1,2,3 :: Int]
      y <- choose  [4,5,6 :: Int]
      th <- liftIO myThreadId
      liftIO $ print (x,y,th)
```

This prints all the combinations of `x` and `y` and the thread that produced the output.

NOTE: be careful with  `choose` since it executes each result within a different thread. A very long list would generate an excessive number of threads that make the computation inefficient. To avoid this, see the thread control primitives below. 

Each result is printed in a different line, unlike the case of the list monad.

If you want the results all together in a list, `collect` does it:

```haskell
collect :: Int -> TransIO a -> TransIO [a]
```

It gathers the number of results indicated by the first parameter. Then, it finishes with the rest of the active threads. If the number is 0, it waits until there are no active threads.

The transient monad is multi-threaded and can perform IO, unlike the list monad. Therefore, non-determinism can be used to perform complex divide-and-conquer computations by slightly modifying single-threaded programs.

A more detailed description of the non-deterministic effects of transient is [here](https://www.schoolofhaskell.com/user/agocorona/beautiful-parallel-non-determinism-transient-effects-iii?show=tutorials#) where you can see how a multi-threaded file search can be performed by slightly modifying a single-threaded program, so that the transient program has *less* lines of code. 

Event variables: publish/subscribe
---------------------------------
A transient computation can return an arbitrary number of results. from zero to many. So it is a natural way to pipeline events with `>>=` and other operators. 

But sometimes we want to transport events non locally, to other parts of the computation where other threads are waiting to process them.

There is a general mechanism to let a thread to subscribe to different events.

Look at this:

```haskell
#!/usr/bin/env stack
-- stack --install-ghc --resolver lts-6.23 runghc   --package transient 
import Control.Monad.IO.Class(liftIO)
import Control.Applicative
import Transient.Base
import Transient.EVars

main= keep $ do
  var <- newEVar
  comp1 var <|>  comp2 var
  liftIO $ putStrLn "world"

comp1 var= do
   r <- readEVar var
   liftIO $ putStrLn r

comp2 var= writeEVar var "hello" >> empty

```

Would print:

```
   hello
   world
```
What happens If i remove `empty` (== `stop`) from `comp2`?

`EVars` are event vars. They allows the communication of two different branches of a transient computation. When an EVar is updated anywhere with `writeEVar`, all the branches that are reading that EVar -with `readEVar`- are executed. 

`newEVar` will create a new EVar. All the EVar continuations are executed in parallel, unless the parallelism is limited with a `threads N` prefix. 

For example, with: 

```haskell
threads 1 $ readEVar ... 
```
In this case, if there are events queued,the processing of the events will be sequential.

`cleanEVar` deletes all the subscriptors (readEVar's)  for this EVar. So they will not be invoked  by `writeEVar` anymore.

EVars use unbounded  channels provided by [Control.Concurrent.STM.TChan](https://hackage.haskell.org/package/stm-2.4.4.1/docs/Control-Concurrent-STM-TChan.html)

To eliminate the magic on that, essentially `readEVar`  is:

```haskell
readEVar (EVar chan) = waitEvents . atomically $  readTChan chan
```
There are a variety of channel libraries in Haskell for different needs. All of them than be used with transient using `parallel` primitives. 

This example summarizes very well many of what you have read upto now: [concurrency example with worker threads](https://github.com/transient-haskell/transient/wiki/Concurrency-example-with-worker-threads)

Logging and recovery
--------------------
Logging is a very important effect. Here I mean not simply trace for debugging, but logging the intermediate results of computations so that a computation can be re-executed to recover the execution state. It allows the reproduction of bugs in another machine without the need of reproducing the environment. It allows also the re-execution after accidental or intended shutdown. In combination with continuations, it allows for transferring execution of programs among computers with different architectures.

The logging implementation is very efficient since it drop intermediate results. Once a routine is completed, his log is simply a single entry: the result, no matter the number of intermediate results it may have (It may have been running in many nodes too).

The basic primitive is `logged`:

```haskell
logged :: TransIO a -> TransIO a 
```

It perform both tasks: logging and recovery. It transparently store in the state the result of the parameter, and recover the value if the value is already in the state. It also does whatever necessary for shortening the log when intermediate computations are finished. Also it manages the complexities associated with asynchronous and multi-threaded programs.

checkpoint, suspend and restore
-------------------------------
The last versions of Transient include these new primitives. If the execution is being logged, `suspend` will save the logs and finalize, `checkpoint` will save and continue, and `restore` will re-execute a program from the log written by `suspend`  and `checkpoint`.  

Since the monad is multi-threaded many threads may have been logged within a single checkpoint. `restore` will continue execution of them from this point on. 

The logs are deleted when re-executed. Make a copy if you want to keep them for debugging.


```haskell
#!/usr/bin/env stack
-- stack --install-ghc --resolver lts-6.23 runghc   --package transient 
import Control.Monad.IO.Class(liftIO)
import Transient.Base
import Transient.Indeterminism
import Transient.Logged
import Control.Monad.IO.Class

main= keep $ restore  $ do
     r <- logged $ choose [1..10 :: Int]
     logged $ liftIO $ print ("hello",r)
     suspend ()
     logged $ liftIO $ print ("world",r)
     checkpoint
     logged $ liftIO $ print ("world22222",r)
```

If executed three times, this program will first print hello <number> as many times as they can until the first thread reach `suspend`, which will kill the threads and exit. 

The second time, it will print "world" <number> and "world22222" <number> and will stop, but it will not exit.

The third time that it is executed, it only present "world22222" <number> messages.

In each step the previous logs are deleted and the program execute from the last checkpoints on.


`logged` also can be used in cloud computing as you could see below:


Remote execution : The Cloud monad
----------------------------------
Some technical detail: transient cloud computing currently is implemented in the "transient-universe" package. it uses heavily all the above transient primitives for thread scheduling, HTTP and socket message parsing, event propagation, closure serialization, closure management and exception handling. It has no major dependency but Transient, so having cloud computing working is the best test of all the above primitives.

The basic primitives of Transient cloud computing are `wormhole`  and `teleport`.  The first opens a connection with a remote node. The second uses this opened connection to translate the computation back and forth between the local and remote nodes. Each time that `teleport` is called, the computation changes from a node to the other.

For example, to run something in a remote node, there is derived primitive `runAt` defined as:

```haskell
runAt :: Loggable a => Node -> Cloud a -> Cloud a
runAt node something= 
      wormhole node $ atRemote something

atRemote something= do
           teleport
           r <- something
           teleport
           return r
```

In that example  `teleport` is invoked two times; one translates the computation to the remote node, the other translates the result to the initial node again. The result is what we intended: the execution of `something` in the remote node and get the result back. 

When the computation moves from a node to another, all the previous variables remain in scope. It is not necessary to pass the variables explicitly. `teleport` has no parameters. it transport the closure information and re-create it in the destination node. It is not in the scope of this to detail the mechanism. Just think about `teleport` as a translation of the execution state from one program in one machine to the same program in another one.

subsequent teleports do not re create closures from scratch, but build upon the previous ones. They communication only transport what is new. Also, closures are reused to send different results at different times.

The two primitives `wormhole` and `teleport` allow using a single connection to migrate execution. It can migrate back and forth at different places without breaking composability reusing a single connection. This means that code that uses these two primitives is fully composable.  

But there is more: Since a transient routine can return many results at different times, it is possible to perform streaming in both directions. More on that later.

`Cloud` is a monad on top of `TransIO` that I added just to force the programmer to log the results of the computations.
`local` does this logging. 

```haskell
local :: Loggable a => TransIO a -> Cloud a

-- the something of the previous example:
something= local <any TransIO expression>
```

The name evokes the fact that once the computation is logged, `teleport` recovers the value of this computation in the remote node. More on this later. 

There are values that are not serializable, the Cloud monad can run it in the remote node too:

```haskell
onAll :: TransIO a -> Cloud a
```

A computation with `onAll` is executed in both nodes, the local and the remote one, when the computation pass trough `teleport`. 

Note that `onAll` does not trigger a cloud operation in all the nodes as its name may suggest (To do so see `clustered` or `mclustered`). it simply means that the data is not logged. 

`v <- onAll foo` means that if there is a remote call, the value will be obtained executing `foo` in each node since the remote call do not transport `v`.   while `v <- local foo`  means that if there is a remote call, `v` will be executed in the local node and will be transported and copied in the remote node.

`onAll` is not a good name, but I didn't find a better one in relation with `local` 

`localIO` or `lliftIO` execute an IO computation and log it in the Cloud monad:

```haskell
localIO, lliftIO :: Loggable a => IO a -> Cloud a
```

The nice and unique thing about these primitives is that they produce composable components, as always in transient. It means that `runAt` can be combined with monadic, applicative and alternative combinators. `runAt` (also called `callTo`) [is in fact a composable primitive of transient](https://www.schoolofhaskell.com/user/agocorona/moving-haskell-processes-between-nodes-transient-effects-iv#forwarding-events-across-the-network).

For examaple, monadic composition can be used to orchestrate a process using different nodes:

```haskell
do
   x <- runAt node1 calc
   y <- runAt node2 calc2
```

In the first example, there may be further teleport sentences, so the computation goes back and forth as many times as you like. Also, the body of a `wormhole` can invoke further wormholes to other nodes. So a process executing on the cloud can get as complex and use as many nodes as you may need. That means that `calc` and `calc2` in the above example could invoke computations in other nodes and so on. Nice. Isn't?

Used with `runAt`, the applicative, monadic and alternative operators permit parallel and concurrent executions among different nodes. They can be combined to create complex cloud operations:

```haskell
    r <- runAt (node1) (return "hello ") <> runAt (nodes2) (return "world")
    lliftIO $ putStrLn r
```
This program returns "hello" from the first node and "world" from the second one. Then it composes both using the monoid instance, that in the case of strings is the composition of the strings, and prints

     > hello world

This program returns two results:

```haskell
helloWorld= do
   runAt node1 (return "hello ") <>  (runAt node2 (return "world1") <|> runAt node3 (return "world2")
   lliftIO $ putStrLn r
```
With return two results:

    > hello world1
    > hello world2

In whatever order. 

It can be used to implement resilience: we can stack alternative computations and get the first response:

```haskell
resilientWorld= collect 1 $ runCloud helloWorld
```
It takes the first response whatever node it comes from, and discards the second.

To make also the first call resilient, simply add another alternative node that returns "hello".

```haskell
runCloud :: Cloud a -> TransIO a
```

Is the opposite type of `local` . Actually, a Cloud computation is a transient one, with a thin layer that makes the type system force either logging each action with `local`, or being aware that the action will be executed in the other node with `onAll`.


A process watches for remote request using `listen`:

```haskell
listen ::  Node ->  Cloud ()
```
The `Node` data has information about the host and the port. `listen` open the port and wait for requests. It spawns a thread asynchronously for each request, using `parallel`. 

Unlike Cloud Haskell and other distributed frameworks that use static closures, Transient distributed programs don't need to be identical in all nodes, neither do the nodes have to share the same CPU architecture or compiler version. The condition is that they have the same Cloud primitives (`wormhole`, `local` etc) and are in the same order.

Connecting
==========

The above snippets of code won't work if we don't connect to the nodes in the first place. There are different ways to do that. 

For debugging purposes, we can simulate two or more nodes in the same program:

``` haskell
#!/usr/bin/env stack
-- stack --install-ghc --resolver lts-6.23 runghc   --package transient --package transient-universe
import Control.Monad.IO.Class (liftIO)
import Control.Applicative
import Transient.Base
import Transient.Move
import Transient.Move.Utils

main= do
     let numNodes = 2
     keep . runCloud $ do
        runTestNodes [2000 .. 2000 + numNodes - 1]
        nodes <- local getNodes
        result <- (,) <$> (runAt (nodes !! 0) $ local getMyNode) <*>  (runAt (nodes !! 1) $ local getMyNode) 
        localIO $ print result
```
will print:

    (("localhost",2001,[]),("localhost",2000,[]))

`runTestNodes` uses a fold of <|> with `listen` sentences If you know how  foldl works, you can deduce that, for two nodes:


``` haskell
runTestNodes ports= do
    nodes <- onAll $  mapM (\p -> liftIO $ createNode "localhost" p) ports
    foldl (<|>) empty (map listen nodes) <|> return()
```

in this case, the second line is the same than:

``` haskell
  listen (nodes !! 0) <|> listen (nodes !! 1) <|> return ()
```

Since there are only two nodes.

That means that `runTestNodes` create three threads: two are `listen`'ing and a third is the original thread, according with what we talked about parallel composition. That last one runs the `runAt` sentences. These sentences wake up the `listen`'ing threads, and they run the calculations "remotely". They return the results and run the continuations. All is run in the same program, but the communications, serialization, deserialization and socket operations take place as if they were distributed. In the last version, local nodes do not need serialization neither communications.

The way to connect with real remote nodes is either manually, if you know the hostnames and the ports of the remote nodes, or you can ask for them with `connect`.

```haskell
connect ::  Node ->  Node -> Cloud ()
```

The first node is the local one, and the second is the remote. The local node information is necessary, since `connect` also start the `listen`'ing of the local node.

Simple, but is not as simple as it seems, since `connect` return the list of nodes connected to the remote node, that is, all the known nodes in the cloud, and the local node stores this response, with `addNodes` in the state of the computation. 

After `connect` is executed the list of nodes is received. To get the list of nodes, use `getNodes`. It includes at least the local node and the remote node that we connected to.

```haskell
main= keep . runCloud $ do
    connect  (createNode "myhost.organization.com" 8000)  
             (createNode "cloudMaster.organization.com" 8000)
    
    nodes <- onAll getNodes
    
    r <- runAt (nodes !! 0) (return "hello ") <> runAt (nodes !! 1) (return "world")
    lliftIO $ putStrLn r
```
This program returns "hello" from the local node and "world" from the remote one. Then both compose using the monoid instance, that in the case of strings is the composition of the strings, and  print

     > hello world

`connect` is more useful for creating programs that run in flexible clouds, where the nodes are not known in advance. 

Clustered operations
--------------------
a cluster is the list of nodes that a node may know.

`connect'` mix two clusters: the cluster one where the node is (that may be itself only) and the cluster where the other  node is. So `connect'` is the way to make grow a cluster of nodes.

Currently, once a node detect a failed connection, it deletes the node from his list of nodes. 

If we ask for the nodes, run the same operation in all of them and sum up the results then we have `mclustered`:

```haskell
mclustered :: (Monoid a, Loggable a)  => Cloud a -> Cloud a
mclustered proc=  do
     nodes <-  onAll getNodes
     foldr (<>) mempty $ map (\node -> runAt node proc) nodes  
```

it is like the composition that generates "hello world" above but with an arbitrary number of nodes.

All the executions in the different nodes are performed in parallel.

An alternative to returning all the results together is to get them as soon as they arrive without waiting for the rest. using the alternative `<|>` operator:

```
clustered :: Loggable a  => Cloud a -> Cloud a
clustered proc= do
     nodes <-  onAll getNodes
     foldr (<|>) empty $ map (\node -> runAt node proc) nodes 
```
`clustered` uses the `<|>` operator. In Transient, this returns the result coming from each node in a different thread, that run the rest of the computation in parallel.

Clustered primitives can be used for many kinds of distributed computing, without knowing the real topology of the cloud.


Remote streaming
----------------

Looking at the above definition of  `runAt`, it can run a remote Cloud program and return the result back. But a Cloud program include Transient computations, that produce results in different threads, right? 

If you  looked at the parallelism section you would know that `waitEvents` `choose` etc can produce many results. What if the remote process returns many results? They are forwarded by `teleport` one by one to the other node and continue execution in the new node, in a different thread.

If you run this program in different nodes, this program forwards what you enter in the remote console to the display of the local console:

```Haskell
runAt remoteNode ( local $ waitEvents getLine) >>= lliftIO . print
```

This is equivalent to:

``` haskell
wormhole remoteNode $ do
    teleport
    r <- local $ waitEvents getLine
    teleport
    localIO $ print r
```
`localIO` runs an IO computation in the local node.

```haskell
localIO = local . liftIO
```

What if I want the other way around, to forward from my *local* console to a remote console?

```haskell
wormhole remoteNode $ do
   r <- waitEvents getLine
   teleport
   lliftIO $ print r
```

Since this time `waitEvents...` is before `teleport`, it is executed locally, and the results are streamed to the remote node, where they are printed. A second `teleport` is not necessary since this time we don't need anything back.

Streaming Contention
-------------------

This ability to stream back and forth can be used by the receiver to control the sender.

```haskell
wormhole remotenode $ do
         op <-  startOrCancel
         teleport          -- translates the computation to remote node
         r <- local $ case op of
                   "start"  ->  killChilds >> waitEvents someSource
                   "cancel" ->  killChilds >> stop

         teleport          -- back to the original node again
         lliftIO $ print r


startOrCancel :: Cloud String
startOrCancel= local  $   (option "start"  "start")
                      <|> (option "cancel" "start")
                             
```

This program starts and stops a remote stream; When start is pressed,  `waitEvents someSource` is initiated. This forwards results to the calling node through the second teleport, and they are printed.

An asynchronous primitive `waitEvents` spawns sibling threads. When canceled, `killChilds` kills them.

Note that `killChilds` is also necessary in the start thread. Since each new "start" event execute `teleport` and spawns a different `waitEvents`, so the streaming would duplicate if we do not stop the previous one.

(There are more civilized ways to stop transient computations trough the use of Event vars)

This same mechanism can be used to reduce or augment the frequency of the streaming. Transient is push based, so it need a way to send feedback to the sender and this is the way to do it. Instead of starting and stopping, a node can send messages upstream to reduce or augment the number of threads or increase the delay between messages.

Mailboxes
---------
Threads in a node can communicate through EVars. But there is a well-known EVar initialized by `listen`, that can be used for communication among all the threads spawned by it.

```haskell


putMailbox :: Typeable a =>   a -> TransIO ()
putMailbox' :: Typeable a =>  Int -> a -> TransIO ()

getMailbox :: Typeable a =>  TransIO a
getMailbox' :: Typeable a => Int -> TransIO a

```

The mailbox primitives can be used when there are different groups of data to be interchanged. The semantics are the one of EVars (since it use EVars in the background). This means, that the `get*` primitives run immediately, once the `set*` primitives run and the type of data/mailbox identifier matches.

Writing to a mailbox is a local operation. How to write in the mailbox of another node? With runAt:

```haskell
putRemoteMailBox node mbox value= runAt node $ local putMailBox mbox value >> empty
```

In a certain way this allow an "actor model" of programming using Transient. But getMailBox is much more flexible since it can be at any place in a computation and can be composed, while in conventional actor models they are not composable. They are event handlers.

Services
--------

Up to now we have been talking about distributed programs that share the same codebase. Services are programs that communicate among them, but have completely different codebases. For example a program, maybe distributed among many machines, can communicate with a database, also distributed. The good thing about transient communications is that they are composable and seamless. and also reactive: Any side can send to the other and trigger the execution of code without special constructions. Ideally the communication among programs with different codebases would retain these properties. It would be good that the program could communicate with the database, but also that the database could send data to the program at any moment. For example, when a register is modified by another node. 

Services allows this kind of reactivity among completely different programs. That would reduce drastically the code necessary for many kind of interactive applications. Another goal is to keep strong composability at the application level, using the same haskell combinators.

```haskell
do
   reg <- newRegister
   reg' <- callService database reg
   liftIO $ "register changed, coming from database: ", reg'

```

look at this: each time that `newRegister` return a register `callService` is the primitive that invokes the database service and reactively return back  0, 1 or many, a stream of results to the calling program. If the database service return the new registers that match the query entered by other nodes, both ways of the communication are done with a single call, as we intended.

An special service is the monitor service. It is a service of services: It is in charge of installing and executing code in the computer when another program request it. This is a description of the monitor service:

```
monitorService= [("service","monitor")
                ,("executable", "monitorService")
                ,("package","https://github.com/transient-haskell/transient-universe")]
 ```
Any other distributed program or service has a similar description. A service can have the "docker" field too. If the executable is not found in the path, the monitor try to compile, install and execute it or execute the docker image.

Let's see how a program request a service:

```
 [node1, node2] <- requestInstance "PIN1" service 2
```

the PIN is an one-of key, which is optional. Then is the service description and then the number of nodes requested. If the monitor is not running in the machine, `requestInstance` will spawn it. A monitor may be connected with the monitors of other machines. The monitor is started with:

```
$ monitorService.exe  -p start/localhost/3000
Enter  "ps"     to: show threads
Enter  "log"    to: inspect the log of a thread
Enter  "end"    to: exit
Enter  "start"  to: re/start node
Executing: "start/localhost/3000"

option: "start"
hostname of this node (must be reachable) ("localhost"): "localhost"
port to listen? (3000) 3000
Enter  "auth"   to: add authorizations for users and services
Enter  "add"    to: add a new monitor node
```

The last option allows the connection with monitors of other nodes. The monitor try to spread the instances among all machines that are connected by talking with the other monitors and asking for permissions. Then the instances are executed and returned to the calling program.

Once the program has the node instances it can call them with distributed primitives like `runAt` if they run the same program. if they run a different program, they use `callService'`.

```haskell
do
   database <- requestInstance "" databaseService 1
   reg <- newRegister
   reg' <- callService' database reg
   liftIO $ "register changed, coming from database: ", reg'
```

`callService'` invoke a node that implement the service directly while `callService`  (no quote) look for this service in the list of nodes, call the monitor if does not find it and wait until it is available. Then it uses `callService'` to invoke it.

Distributed Computing: Map-Reduce
---------------------------------

An example of distributed map-reduce  is at  [DistribDataSets.hs](https://github.com/transient-haskell/transient-examples/blob/master/DistrbDataSets.hs) and can be executed directly from source if docker is installed.


For best use of cloud resources, not only the program must be distributed, but also the data. The processing is done in each node with each portion of data. To allow this, a kind of structure for distributed data is necessary. The data can be seen in the Cloud monad as a single entity.

In transient the DDS (Distributed Data Sets) are data partitioned among the nodes, similar to the RDS (Resilient Data Sets) used in [spark](http://spark.apache.org/docs/latest/programming-guide.html#rdd-operations). Map-reduce primitives in transient are very similar in philosophy to the ones of spark, which is a Java VM framework for distributed computing.

However, while spark is a framework, transient is a pure library. Its primitives are first class in the language, and map-reduce is a particular operation in transient, but it is not hard-coded in a rigid framework.

On the other side, Map-reduce with Distributed Data Sets in in the infancy in transient. Although it implement boxed and unboxed vector operations. 

Transformations of the data are done in memory. They can swapped to disk and can be cached, but the interface for the latter is not yet ready.

Like in the case of spark, reduce is the operation that runs everything, while map is declarative. Let's see an example:

```haskell
   runCloud $ initNode $ inputNodes <|> do
        r <- reduce  (+) . mapKeyB (\w -> (w, 1 :: Int))  $ getText  words text
        lliftIO $ putStrLn r
```

This program gets a text and distributes it to all the nodes connected . It then returns a list of words and the number of times that the word appear in the text, in a map, to the `localnode`. look here for a description of `initNode` and `inputNodes`

For example, if text is `"hello world hello"`, the program prints:

> fromList [("hello",2),("world",1)]

`getText` convert a text into a DDS:

```haskell
getText  :: (Loggable a, Distributable vector a) => (String -> [a]) -> String -> DDS (vector a)
```
`Distributable vector a` is a class constraint that restrict `vector` to either [Data.Vector](https://hackage.haskell.org/package/vector/docs/Data-Vector.html) or [Data.Vector.Unboxed](https://hackage.haskell.org/package/vector-0.11.0.0/docs/Data-Vector-Unboxed.html).

The first parameter is the parser, that convert the text into a list of elements that we want to manage. In the case of the example, I used `words` that split the text in a list of words.

There are similar primitives to get content form URls, or files and convert them into Distributed Data Sets: `getUrl` and  `getFile` respectively. 

All these `get*` primitives assume that each node can access to the content, the file and the URL respectively. for files, all the nodes must have mounted the file in the same path (That is also the way spark works).

``` haskell
mapKeyB :: (Loggable a, Loggable b,  Loggable k,Ord k)
     => (a -> (k,b))
     -> DDS  (Data.Vector.Vector a)
     -> DDS (M.Map k(Data.Vector.Vector b))
```

mapKeyB works with unboxed vectors. Variable length data like text need unboxed vectors. A boxed vector manage pointers, while unboxed vectors store the data of each element directly.

A vector in Haskell is also called array in other languages. It is a blob of memory with several elements of the same type. Unlike lists, that are linked by means of pointers, vectors occupy contiguous memory. They can be processed by a single core in the L2 cache with few page faults.

```haskell
mapKeyU :: (Loggable a, DVU.Unbox a, Loggable b, DVU.Unbox b,  Loggable k,Ord k)
     => (a -> (k,b))
     -> DDS  (Data.Vector.Unboxed.Vector a)
     -> DDS (M.Map k(Data.Vector.Unboxed.Vector b))
```

`mapKeyU` is the boxed version, for `Unbox`-able data types like numbers.  Both are pure, declarative operations that transform DDSs according to different keys. They also transform the values according to a indexed map operation. The result in each node is a set of vectors associated with different keys in structure called Map. You can query for the key and obtain the corresponding vector very fast.

``` haskell
reduce ::  (Hashable k,Ord k, Distributable vector a, Loggable k,Loggable a)
             => (a -> a -> a) -> DDS (M.Map k (vector a)) ->Cloud (M.Map k a)
```

`reduce` is the primitive that runs the expression and produce a normal result in the calling node, within the `Cloud` monad.  It accept a result of `mapKeyX` . It uses the first parameter to, well, reduce each vector to a single value, by repeatedly applying the operation. In the case of the example, by summing all the values of the vector.

There are still many things to do. Optimizations, test with really  big data, more primitives, implement resilience, caching, [DataFrames](http://spark.apache.org/docs/latest/sql-programming-guide.html), and some standard data analysis and machine learning algorithms.

But data analysis and machine learning in the style of spark is not the only application. Since map-reduce can be used to implement NoSQL queries in distributed systems more in the line for Hadoop. A DDS or a DataFrame can be the database of a distributed system in a web application, since transient also may run in a web browser, and can also provide a web interface.

Additionally a web node can present the data analysis results of map-reduce requests. I want to create an standard web notebook for the execution of interactive map-reduce queries.

However, the execution of map-reduce with a full [shuffle](http://spark.apache.org/docs/latest/programming-guide.html#shuffle-operations) stage is a complex choreography. It tests almost all the transient primitives and I'm quite satisfied with the results. Since map and reduce primitives are first class, that is, they're simple haskell primitives in a monadic computation, it is easy to port algorithms. Like algorithms made for single haskell nodes for other monads in other packages.

**For a real example** of multinode map-reduce, use the [distributedApps.hs](https://github.com/transient-haskell/transient-examples/blob/masters/distributedApps.hs) example.

It can be executed directly from source using a docker image. Otherwise, if you have installed ghc and ghcjs you can compile the program with the two compilers:

     ghcjs -o static/out  distributedApps.hs
     ghc distributedApps.hs

(Yes, transient can be used for web applications)

Run three instances, for example:

     ./distributedApps  -p start/localhost/8080 &
     ./distributedApps  -p start/localhost/8081/add/localhost/8080/y &
     ./distributedApps  -p start/localhost/8082/add/localhost/8080/y &

access to any of the three instances with a web browser and select the map-reduce option.

[Here you can see how](https://github.com/transient-haskell/transient/wiki/Running-example(s)) to run it in the cloud9 environment.

Transient in the Web Browser
----------------------------
transient nodes running in a Web browser are fully functional, and they can run the same primitives thanks to the completeness of the GHCJS compiler.

How is the application setup to run in in a Web Browser? You have to compile it too with the GHCJS compiler with the option `-o ./static/out` . The static folder must be in the same folder where the program is executed.

By default `listen port`, when invoked with the HTTP protocol, tries to find the javascript sources in the folder "./static.out.jsexe"  . If they are there, the browser loads them and runs a new transient node. This node may connect with the server using normal transient connection primitives like `connect`, `wormhole` etc.

One way to initialize a server node that accepts browser nodes and allows transient server/client distributed primitives is  

```haskell
  simpleWebApp port app :: IO ()
```


`app` is the  `Cloud` expression with `wormholes`, `teleports` etc.


An even simpler way to use simpleWebApp is `initNode`

```haskell
initNode app
```
`initNode` ask the user to start, then ask for the hostname and the port using `option` and `input`. More on that below.

simpleWebApp relies on cloud primitives:

```haskel

simpleWebApp :: Integer -> Cloud () -> IO ()
simpleWebApp port app = do
   node <- createNode "localhost" port
   keep $ initWebApp node app


initWebApp :: Node -> Cloud () -> TransIO ()
initWebApp node app=  do
    conn <- defConnection
    setData  conn{myNode = node}
    serverNode  <-   getWebServerNode  :: TransIO Node

    mynode <- if isBrowserInstance
                    then liftIO $ createWebNode
                    else return serverNode

    runCloud $ do
        listen mynode <|> return()
        wormhole serverNode app 
        return ()
    
```
getWebServerNode use JavaScript tricks to obtain the server node. Then it detects if it is running as server or as browser (since both the server and each node run the same code). Then, in the Cloud monad, listen is called, the the browser node connect with the server trough a `wormhole` and the user application is executed in this context.

`simpleWebApp` is executed by the server and the clients, but in the server, all the DOM primites are equated to `stop` so the server stop executing as soon as it detect DOM code.

`onBrowser` prohibits the server to execute the code after it. Since this `simpleWebApp` is executed both in the server and the client, this precludes the server to continue. However the server will execute teleportations. 

since there is a wormhole between client and server, then `teleport` can be used to move computations back and forth:

within a wormhole `atRemote` if invoked from the server or browser, run the computation in the other node:

```haskell
atRemote proc= do
     teleport
     r <- proc
     teleport
     return r
```

`atRemote` can be used either from the browser to call the server or the other way around. It is possible to create applications controlled by the server:

```haskell
do
  teleport -- now we are on the server
  ....
  r <- atRemote  displayAndInputSomething   -- do something in the browser
  doOtherThings r   --- we follow in the server. The server is the master
  ....
  teleport  -- now we are in the client
  ....  -- here the browser is master and executes the logic
``` 

The computation start in the browser, that act initially as master, but `teleport` can change this at any moment.

Recommended for node initialization:
-----------------------------------
`initNode` is even a simpler way to initialize any node, either a pure transent node with or without web application. And is the recommended way to do it:

```haskell
initNode :: Cloud () -> TransIO ()
initNode app= do
   node <- getNodeParams
   initWebApp node  app
  where
  getNodeParams :: TransIO Node
  getNodeParams =
      if isBrowserInstance then  liftIO createWebNode else do
          oneThread $ option "start" "re/start node"
          host <- input (const True) "hostname of this node (must be reachable): "
          port <- input (const True) "port to listen? "
          liftIO $ createNode host port
```

It asks for the hostname and the port in the command line. Then it initializes the node and the possible web clients if the program is compiled to Javascript.

Look at this program:

```haskell
  main= keep $ initNode $ onBrowser webapp <|> onServer inputNodes
```

`onBrowser` and `onServer`  tell the program to continue executing the code exclusively in browser and server instance respectively, but the other node can execute teleportations.

`inputNodes` allows the connection of other server nodes.

```haskell
inputNodes= do
   onServer $ do
          local $ option "add"  "add a new node at any moment"
          host <- local $ do
                    r <- input (const True) "Host to connect to: (none): "
                    if r ==  "" then stop else return r

          port <-  local $ input (const True) "port?"

          connectit <- local $ input (\x -> x=="y" || x== "n") "connect to get his list of nodes?"
          nnode <- localIO $ createNode host port
          if connectit== "y" then connect'  nnode
                             else local $ addNodes [nnode]
   empty
```

It asks for nodes and optionally `connect'` then.


Fot the above main program. the parameters can be given interactively or in the command line:

     myProgram -p start/myserver/2001/add/otherserver/2000/y

it initializes the node as myserver:2001 and connects with otherserver:2000  

Web Programming: Axiom
----------------------------

Transient computations can create reactive widgets in the browser using HPlayground. the package is called [ghcjs-hplay](http://github.com/agocorona/ghcjs-hplay). The Web functionality of transient will be called **Axiom**, like the cruise starship of Wall-e. Axiom is made to let you navigate the universe of nodes in the cloud trough your browser while you are comfortably seated in your [hoverchair](https://www.youtube.com/watch?v=uOL2W9JQmo8).

Axiom is based on HPlayground, a client side framwork that run using the Haste compiler and ran purely client based applications. [See this online IDE/Demo](http://tryplayg.herokuapp.com/) for some examples and to try hplayground. Now with transient, it can run full Haskell client and server applications using GHCJS in the client. It will be ported to Haste too, since Haste produces shorter code that is convenient for some applications.

See [This issue](https://github.com/agocorona/ghcjs-hplay/issues/9) for how to transform a client side Hplayground application to a full stack Axiom (formerly called ghcjs-hplay) application.

A widget can have browser and Server code, and being fully composable at the same time. A full-stack "widget" may be a complete application. It can utilize distributed computing and map-reduce. And it will will be ever composable. 

This is a simple example of a web application that asks for your name, sends it to the server, where it is displayed and a message is returned to the browser:

```haskell
main= simpleWebApp 8080 app

app= do
   local . render $ rawHtml $  p "In this example you enter your name and the server will salute you"
   name <- local . render $ inputString (Just "enter your name") `fire` OnKeyUp
             <++ br                                        -- new line

   r <- atRemote $ lliftIO $ print (name ++ " calling") >> return ("Hi " ++ name)

   local . render . rawHtml $ do
                      p " returned"
                      h2 r
```
The program works as follows: `simpleWebApp` initialize the server node as well as any browser node that connects to it. It includes a `listen`invocation that, in the server, watch both for requests from other nodes (as usual), but also watch for HTTP requests from Web browsers and also watch for websocket requests. Transient has his own web server, made using `parallel` primitives and parsing, implemented also within the transient monad. 

Once an HTTP request arrives from a browser, the node send the HTML+Javascript produced by the GHCJS compiler. This code configures a transient node in the browser, that issue a webSocket connection. This connection will `trasport back and forth all the communications between server and browsers. 

All of this happens within the `simpleWebApp` primitive. 

The user program has a message first, that is displayed in a paragraph in the browser.

Then, there is an input box. It sends the content to the server each time you release one key. Each time you change the input, the server prints your name in the server console. The server returns a new message to the browser, which is printed with H2 formatting.

It is a Cloud computation in the Cloud monad as always, but this time something is rendered in the browser. `render` is the primitive that display HTML DOM elements. When a `render` statement is executed, it first deletes all content generated by this statement and all the subsequent ones, and then it redraw this branch. So an event produced by a Dynamic HTML event or by communications or whatever will redraw the sub-branch where the event happens, but it does not modify the rest of the rendering. 

In this case, the `atRemote` return a new result, so `render` delete the previous one and display it.

As ever, the good news is that this snippet, that runs code in the browser and the server, can be combined with any other. To see this and other two examples together,  look at the [webapp example](https://github.com/agocorona/transient-universe/blob/master/examples/webapp.hs).

`atRemote` is the one defined above in the paragraph about cloud computing. The communication browser-server uses the cloud primitives. This time webSockets are used instead of sockets. As a consequence, only the browser can initiate the communication, but once this is done with `simpleWebApp`, the server or the browser can control the execution. All depends on which nodes has the control, and this is established with `teleport`. See the previous section.

Initially the control is for the browser as in the case of the above program. But this schema:

``` haskell
   teleport     -- transfer control to the server
   -- control is now in the server
   r <- atRemote  $ something        -- something is executed in the browser
   -- back running in the server again  
```

Is the schema for having programs controlled by the server, instead of the browser.

Since  atRemote is like a sandwich of teleports with some Transient computation to do in the middle, that can return zero, one or more than one result. In the latter case we have remote streaming. this can be used to do implicit websocket streaming.

This snippet stream the Fibonacci numbers from the server to the browser:

``` haskell
demo= do
   name <- local . render $ do
       rawHtml $ do
          hr
          p "this snippet captures the essence of this demonstration"
          p $ span "it's a blend of server and browser code in a composable piece"

          div ! id (fs "fibs") $ i "Fibonacci numbers should appear here"

   local . render $ wlink () (p " stream fibonacci numbers")

   -- stream fibonacci

   r <-  atRemote $ do
               let fibs= 0 : 1 : zipWith (+) fibs (tail fibs) :: [Int]  -- fibonacci numb. definition
               r <- local  . threads 1 . choose $ take 10 fibs
               lliftIO $ print r
               lliftIO $ threadDelay 1000000
               return r

   local . render . at (fs "#fibs") Append $ rawHtml $  (h2 r)

fs= fromString
```


HTML rendering
==============
In this code, the `atRemote` computation has a non-deterministic primitive, `choose` that produces the ten first Fibonacci numbers. As you saw under the paragraph "thread control", the `threads 1` and the `threadDelay 1000000` modifies the `choose` block to return a number each second.

Since this code is after the first teleport, that gives control to the server, and before the second one (they are implicit in `atRemote`)  it executes in the server and the result is streamed to the browser. This is done in the last line. 

This time the last `render` has the `at` primitive. `at` insert the rendering in the location/s specified by the first parameter, that is an "xpath" selector (like the jQuery selectors). In this case the identifier is "#fibs"  that refer to the element with "fibs" identifier, that was created above.   

`Append` tells `at`  to append each next result to the previous one.

``` haskell
data UpdateMethod= Append | Prepend | Insert deriving Show
```

Observe that the `rawHtml` block accept a sublanguage for HTML-DOM creation in the browser that is almost identical to a well known DSL for producing HTML rendering in the server: [blaze-html](https://jaspervdj.be/blaze/tutorial.html). This EDSL is implemented in the package [ghcjs-perch](https://github.com/geraldus/ghcjs-perch). Really it is a superset, since besides rendering, it also has DOM manipulation capabilities. 


Browser Events
==============
Elements like `inputString` and `wlink`are "active". This means that they may return values when an event happens inside the element. They are in the `Widget` monad. This is the TransIO monad with slight variations for handling the <*> operator. The main purpose of the Widget monad is to make the programmer aware that widgets should be rendered explicitly with `render`:

render :: Widget a -> TransIO a

```
wlink :: (Show a, Typeable a) => a -> Perch -> Widget a

inputString  :: Maybe String -> Widget String

```
`wlink` renders an HTML link and return the value of the first parameter. `inputString` is an input field that may accept an string as initial value and return the string edited.

They return a result when  an event is triggered. the kind of event can be defined by the user with `fire`. In the examples above you can see some examples of the use of `fire`.

The events available are the standard ones:

``` haskell
data BrowserEvent= OnLoad | OnUnload | OnChange | OnFocus | OnMouseMove | OnMouseOver |
 OnMouseOut | OnClick | OnDblClick | OnMouseDown | OnMouseUp | OnBlur |
 OnKeyPress | OnKeyUp | OnKeyDown deriving Show
```

The programmer can add new events (for example, touch events) by creating instances of IsEvent:

``` haskell
class IsEvent a where
   eventName :: a -> JSString
   buildHandler :: Elem -> a  ->(EventData -> IO()) -> IO()
```

But this is beyond the scope of this introduction.

Events can be added to arbitrary raw HTML code with `pass`:

```haskell
    evdata <-  render $ p "hello"  `pass`  OnDblClick
    nextStatement evdata
```
pass will return the event data when the event occurs within the "hello" paragraph.

These are the signatures:
```haskell
pass :: IsEvent event => Perch -> event -> Widget EventData
data EventData= EventData{ evName :: JSString, evData :: Dynamic} deriving (Show,Typeable) 
```

`EvData` is defined as Dynamic to allow programmer-defined events. Again, this is not in the scope of this introduction.

Input elements
==============
An example using the main input elements running contained in the file [widgets.hs](https://github.com/transient-haskell/transient-examples/blob/master/widgets.hs)

```haskell
main= simpleWebApp 8081 $ onBrowser $ local $   buttons  <|> linksample
    where
    linksample= do
          r <-  render $ br ++> br ++> wlink "Hi!" (toElem "This link say Hi!")`fire` OnClick
          render $ rawHtml . b  $ " returns "++ r

    buttons :: TransIO ()
    buttons= do
           render . rawHtml $ p "Different input elements:"
           radio <|> checkButton  <|> select

    checkButton :: TransIO ()
    checkButton=do
           rs <- render $  br ++> br ++>  getCheckBoxes(
                           ((setCheckBox False "Red"    <++ b "red")   `fire` OnClick)
                        <> ((setCheckBox False "Green"  <++ b "green") `fire` OnClick)
                        <> ((setCheckBox False "blue"   <++ b "blue")  `fire` OnClick))
           render $ rawHtml $ fromString " returns: " <> b (show rs)

    radio :: TransIO ()
    radio= do
           r <- render $ getRadio [fromString v ++> setRadioActive v
                         | v <- ["red","green","blue"]]

           render $ rawHtml $ fromString " returns: " <> b ( show r )

    select :: TransIO ()
    select= do
           r <- render $ br ++> br ++> getSelect
                          (   setOption "red"   (fromString "red")
                          <|> setOption "green" (fromString "green")
                          <|> setOption "blue"  (fromString "blue"))
                  `fire` OnClick

           render $ rawHtml $ fromString " returns: " <> b ( show r )
 
```
With slight differences, you can see it [running here](http://tryplayg.herokuapp.com/try/widgets.hs/edit) using the HPlay version for the Haste Haskell-to-Javascript compiler. The main difference is that the running example is a pure client side application, while this example is a full stack application. Also,  `getRadio` has been simplified and does not use lambda expressions. See [This issue](https://github.com/agocorona/ghcjs-hplay/issues/9) for how to transform a client side Hplayground application to a full stack ghcjs-hplay application.

Wait.. What all these operators means?  You should know about the standard Haskell operators `$` `<|>`, `<>`.  But `++>` and `**>` are new.  

`++>` simply add perch rendering to active elements in the Widget monad, for example, links and input boxes. it should be read as "add this HTML to the next element". 

``` haskell
(++>) :: Perch -> Widget a -> Widget a
(<++) :: Widget a -> Perch -> Widget a
```

`**>` append a Widget element to another and return the latter.  `<**`  does the same but return the first one.

There is also `<<<` that encloses an active element within a "container" perch tag:

```haskell
(<<<) :: (Perch -> Perch) -> Widget a  -> Widget a
```
``` haskell
   r <- render $ div <<< (inputString ..... <|> wlink ...)
   dosomething r
```

Encloses both active elements within a div. The operator is transparent in relation with the result returned `r`. This way to mix rendering and computation assures the possibility to create complex widgets with complex behaviours that are fully self contained and can be inserted anywhere using the standard haskell operators. Each one of these components can be a full stack application.

Events and rendering
====================
The good news is that transient rendering in the browser does not need something like the virtual DOM, since it only refresh the zone of the screen being modified locally by each event. 

Other client-side frameworks use the React mechanism: Since they bubbles up all events to the top, the events loose locality. They do not treat the event locally, so they need to  re-execute everithing and use a virtual DOM to determine the zones of the page that need an update. They also lack a notion of sequence. In Transient, rendering and results of the computation flows from one widget to another in clear and composable ways that are defined by the programmer.

The dependencies are defined directly by your monadic code. It is supposed that, if you connect widgets in a do sequence, it means that events at step N affect the display of the widgets at the next steps. The next widget receive the results of the previous steps and recompute their rendering. If that is not your desire, you can avoid such dependency easily using  the operations `<>` `<|>` or `<*>`  to connect them, instead of do (the sintactic sugar of >>= and >>). In whose case, they will be independent and no refreshing will occur when the adjacent widgets have events. 

For example:
```haskell
lr= local . render

do  x <- lr w1 ; lr $ w2 x
```

suppose that w1 is a text input box that is triggered once a key is entered (`OnKeyDown`) In the above case, each event in w1 would return a new x which will be the content of the text box. Therefore, w2  will be executed with the new value of `x` as his parameter. Suppose that w2 display the value of x with some formatting. This new rendering that will be refreshed. This means that the previous rendering of w2 will be deleted and the new one will be displayed.

But w1, where the event has happened, will not be refreshed (except the input entered).

The same happens if after w2 there is an w3 and so on.

in the cases below both widgets are independent; No refresh of one happens if the other has an event.

```haskell
lr $ w1 <|> w2       -- w1 and w2 are independent, w1 and w2 compose in the Widget monad

lr w1 <|> lr w2      -- w1 and w2 are independent, compose in the Cloud monad

lr $ w1 <> w2        -- results of w1 and w2 are appended

(,) <$> w1 <*> w2    -- generates a 2-tuple with the values of w1 and w2 widgets when an event in w1 or w2 happens
```


The examples below shows more complicated combinations. You can see that updates are only performed when necessary

```haskell
do x <- lr $ w1 <|> w2 ; lr $ w3 x       -- w3 will be updated if either w1 or w2 have events

do   x <- lr w1
     if x==a then empty else lr $ w2 x  -- w2 will be changed only if the result of w1 is different from w2

```

As you know, `empty` stop the execution of the monad

Aha ok.. I did not mention something more. `Perch` can do off-the-flow modifications to any DOM element.
This is important when we need small modifications in a widget somewhere else instead of a complete redraw.

if you have this somewhere

```haskell
rawHtml  div ! id "elemid"  $ do
                           p "content"
                           .....
```

You can modify it from whatever other widget with this:

```haskell
rawHtml $  forElem "#elemid" $ this ! atr "attribute" "newvalue"
```

That will change the attribute of the  element/s  that match the selector  "#elemid".  Just like JQuery

This code can add child elements to it:

```haskell
rawHtml $  forElem "#elemid" $ this $ do
                                   p "new paragrah".
                                   p "Another new paragraph"
```

So you can have pretty independent widgets arranged in hierrarchies:

```haskell
          w1 <|> w2...

          where w1= w3 <|> w4...
                    w2= w5 <|> w6...
```
while they can interact off-band by modifying content or attributes mutually from/to any level without refreshing everything.

It is possible also to put the rendering of a widget `at` some location:

```haskell
local $ render $ at "#elemid"  Append $  do   -- widget rendering is appended 
```
This is another way, more powerful, of modifying DOM elements located at any place on the page by inserting Widgets, not only Perch code.

Templates:
==========

A new addition of ghcjs-hplay support templates. Up to now the rendering was generated dinamically in the web browser using `Perch`. Now there is a mechanism for adding static HTML code that enable the edition of that rendering. This works as follows: 

You need to do a page with a lot of static content but it ha some interactive code and you don´t want to program perch cod to create it all, you prefer to create it with an editor. No problem. You program just the interactive widgets with no static content. Then add `editW` to the widget:

```haskell
main= initNode $ editW $ widgets
```

This launch the widget under the browser in a editor context, in which you can enrich the page with your static content. Don´t delete the code created by the widget. Then you save the page.  Then this content will be presented to the user when he access that URL. Now you can create wathever static content with this mechanism.


The Transient monads
====================
The three monadd: `TransIO`, `Cloud` and `Widget` are basically the same. The only purpose of having three monads is to force the programmer to call `render` to display widgets and to force it to log all actions if he need to invoque remote primitives.

Widget monad --> `render/norender` -->  TransIO monad --> `local/onAll`  -->  Cloud monad


Widget monad <-- `   Widget      ` <--  TransIO monad <-- ` runCloud  `  <--  Cloud monad


The only difference is how Applicative is executed in the Widget monad, which has a separate definition.

There is a fourth monad: `Perch`, used for rendering DOM elements. 

`rawHtml` accept any expression in the Perch monad. Thee are also operators like `++>` and `<++`  in order to prepend and append short DOM expressions to widgets.


