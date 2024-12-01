{-# LANGUAGE ScopedTypeVariables #-}
-----------------------------------------------------------------------------
--
-- Module      :  Base
-- Copyright   :
-- License     :  MIT
--
-- Maintainer  :  agocorona@gmail.com
-- Stability   :
-- Portability :
--
-- | Transient provides high level concurrency allowing you to do concurrent
-- processing without requiring any knowledge of threads or synchronization.
-- From the programmer's perspective, the programming model is single threaded.
-- Concurrent tasks are created and composed seamlessly resulting in highly
-- modular and composable concurrent programs.  Transient has diverse
-- applications from simple concurrent applications to massively parallel and
-- distributed map-reduce problems.  If you are considering Apache Spark or
-- Cloud Haskell then transient might be a simpler yet better solution for you
-- (see
-- <https://github.com/transient-haskell/transient-universe transient-universe>).
-- Transient makes it easy to write composable event driven reactive UI
-- applications. For example, <https://hackage.haskell.org/package/axiom Axiom>
-- is a transient based unified client and server side framework that provides
-- a better programming model and composability compared to frameworks like
-- ReactJS.
--
-- = Overview
--
-- The 'TransientIO' monad allows you to:
--
-- * Split a problem into concurrent task sets
-- * Compose concurrent task sets using non-determinism
-- * Collect and combine results of concurrent tasks
--
-- You can think of 'TransientIO' as a concurrent list transformer monad with
-- many other features added on top e.g. backtracking, logging and recovery to
-- move computations across machines for distributed processing.
--
-- == Non-determinism
--
-- In its non-concurrent form, the 'TransientIO' monad behaves exactly like a
-- <http://hackage.haskell.org/package/list-transformer list transformer monad>.
-- It is like a list whose elements are generated using IO effects. It composes
-- in the same way as a list monad. Let's see an example:
--
-- @
-- import Control.Concurrent (threadDelay)
-- import Control.Monad.IO.Class (liftIO)
-- import System.Random (randomIO)
-- import Transient.Base (keep, threads, waitEvents)
--
-- main = keep $ threads 0 $ do
--     x <- waitEvents (randomIO :: IO Int)
--     liftIO $ threadDelay 1000000
--     liftIO $ putStrLn $ show x
-- @
--
-- 'keep' runs the 'TransientIO' monad. The 'threads' primitive limits the
-- number of threads to force non-concurrent operation.  The 'waitEvents'
-- primitive generates values (list elements) in a loop using the 'randomIO' IO
-- action.  The above code behaves like a list monad as if we are drawing
-- elements from a list generated by 'waitEvents'.  The sequence of actions
-- following 'waitEvents' is executed for each element of the list. We see a
-- random value printed on the screen every second. As you can see this
-- behavior is identical to a list transformer monad.
--
-- == Concurrency
--
-- 'TransientIO' monad is a concurrent list transformer i.e. each element of
-- the generated list can be processed concurrently.  In the previous example
-- if we change the number of threads to 10 we can see concurrency in action:
--
-- @
-- ...
-- main = keep $ threads 10 $ do
-- ...
-- @
--
-- Now each element of the list is processed concurrently in a separate thread,
-- up to 10 threads are used. Therefore we see 10 results printed every second
-- instead of 1 in the previous version.
--
-- In the above examples the list elements are generated using a synchronous IO
-- action.  These elements can also be asynchronous events, for example an
-- interactive user input.  In transient, the elements of the list are known as
-- tasks.  The tasks terminology is general and intuitive in the context of
-- transient as tasks can be triggered by asynchronous events and multiple of
-- them can run simultaneously in an unordered fashion.
--
-- == Composing Tasks
--
-- The type @TransientIO a@ represents a /task set/ with each task in
-- the set returning a value of type @a@.  A task set could be /finite/ or
-- /infinite/; multiple tasks could run simultaneously.  The absence of a task,
-- a void task set or failure is denoted by a special value 'empty' in an
-- 'Alternative' composition, or the 'stop' primitive in a monadic composition.
-- In the transient programming model the programmer thinks in terms of tasks
-- and composes tasks. Whether the tasks run synchronously or concurrently does
-- not matter; concurrency is hidden from the programmer for the most part. In
-- the previous example the code written for a single threaded list transformer
-- works concurrently as well.
--
-- We have already seen that the 'Monad' instance provides a way to compose the
-- tasks in a sequential, non-deterministic and concurrent manner.  When a void
-- task set is encountered, the monad stops processing any further computations
-- as we have nothing to do.  The following example does not generate any
-- output after "stop here":
--
-- @
-- main = keep $ threads 0 $ do
--     x <- waitEvents (randomIO :: IO Int)
--     liftIO $ threadDelay 1000000
--     liftIO $ putStrLn $ "stop here"
--     stop
--     liftIO $ putStrLn $ show x
-- @
--
-- When a task creation primitive creates a task concurrently in a new thread
-- (e.g.  'waitEvents'), it returns a void task set in the current thread
-- making it stop further processing. However, processing resumes from the same
-- point onwards with the same state in the new task threads as and when they
-- are created; as if the current thread along with its state has branched into
-- multiple threads, one for each new task. In the following example you can
-- see that the thread id changes after the 'waitEvents' call:
--
-- @
-- main = keep $ threads 1 $ do
--     mainThread <- liftIO myThreadId
--     liftIO $ putStrLn $ "Main thread: " ++ show mainThread
--     x <- waitEvents (randomIO :: IO Int)
--
--     liftIO $ threadDelay 1000000
--     evThread <- liftIO myThreadId
--     liftIO $ putStrLn $ "Event thread: " ++ show evThread
-- @
--
-- Note that if we use @threads 0@ then the new task thread is the same as the
-- main thread because 'waitEvents' falls back to synchronous non-concurrent
-- mode, and therefore returns a non void task set.
--
-- In an 'Alternative' composition, when a computation results in 'empty'
-- the next alternative is tried. When a task creation primitive creates a
-- concurrent task, it returns 'empty' allowing tasks to run concurrently when
-- composed with the '<|>' combinator. The following example combines two
-- single concurrent tasks generated by 'async':
--
-- @
-- main = keep $ do
--     x <- event 1 \<|\> event 2
--     liftIO $ putStrLn $ show x
--     where event n = async (return n :: IO Int)
-- @
--
-- Note that availability of threads can impact the behavior of an application.
-- An infinite task set generator (e.g. 'waitEvents' or 'sample') running
-- synchronously (due to lack of threads) can block all other computations in
-- an 'Alternative' composition.  The following example does not trigger the
-- 'async' task unless we increase the number of threads to make 'waitEvents'
-- asynchronous:
--
-- @
-- main = keep $ threads 0 $ do
--     x <- waitEvents (randomIO :: IO Int) \<|\> async (return 0 :: IO Int)
--     liftIO $ threadDelay 1000000
--     liftIO $ putStrLn $ show x
-- @
--
-- == Parallel Map Reduce
--
-- The following example uses 'choose' to send the items in a list to parallel
-- tasks for squaring and then folds the results of those tasks using 'collect'.
--
-- @
-- import Control.Monad.IO.Class (liftIO)
-- import Data.List (sum)
-- import Transient.Base (keep)
-- import Transient.Indeterminism (choose, collect)
--
-- main = keep $ do
--     collect 100 squares >>= liftIO . putStrLn . show . sum
--     where
--         squares = do
--             x <- choose [1..100]
--             return (x * x)
-- @
--
-- == State Isolation
--
-- State is inherited but never shared.  A transient application is written as
-- a composition of task sets.  New concurrent tasks can be triggered from
-- inside a task.  A new task inherits the state of the monad at the point
-- where it got started. However, the state of a task is always completely
-- isolated from other tasks irrespective of whether it is started in a new
-- thread or not.  The state is referentially transparent i.e. any changes to
-- the state creates a new copy of the state.  Therefore a programmer does not
-- have to worry about synchronization or unintended side effects.
--
-- The monad starts with an empty state. At any point you can add ('setData'),
-- retrieve ('getSData') or delete ('delData') a data item to or from the
-- current state.  Creation of a task /branches/ the computation, inheriting
-- the previous state, and collapsing (e.g. 'collect') discards the state of
-- the tasks being collapsed. If you want to use the state in the results you
-- will have to pass it as part of the results of the tasks.
--
-- = Reactive Applications
--
-- A popular model to handle asynchronous events in imperative languages is the
-- callback model.  The control flow of the program is driven by events and
-- callbacks; callbacks are event handlers that are hooked into the event
-- generation code and are invoked every time an event happens. This model
-- makes the overall control flow hard to understand resulting into a "callback
-- hell" because the logic is distributed across various isolated callback
-- handlers, and many different event threads work on the same global state.
--
-- Transient provides a better programming model for reactive applications.  In
-- contrast to the callback model, transient transparently moves the relevant
-- state to the respective event threads and composes the results to arrive at
-- the new state. The programmer is not aware of the threads, there is no
-- shared state to worry about, and a seamless sequential flow enabling easy
-- reasoning and composable application components.
-- <https://hackage.haskell.org/package/axiom Axiom> is a client and server
-- side web UI and reactive application framework built using the transient
-- programming model.
--
-- = Further Reading
--
-- * <https://github.com/transient-haskell/transient/wiki/Transient-tutorial Tutorial>
-- * <https://github.com/transient-haskell/transient-examples Examples>
--
-----------------------------------------------------------------------------

module Transient.Base(
-- * The Monad
TransIO, TransientIO

-- * Task Composition Operators
, (**>), (<**), (<***)

-- * Running the monad
,keep, keep',keepCollect, stop, exit

-- * Asynchronous console IO
,option,option1, input,input'

-- * Task Creation
, StreamData(..)
,parallel, async, waitEvents, sample, spawn, react, abduce, fork,sync

-- * State management
,setData, getSData, getData, delData, modifyData, modifyData', try, setState, getState, delState, newRState,getRState,setRState, modifyState
,labelState, findState, removeState

-- * Thread management
, threads, anyThreads, addThreads, freeThreads, hookedThreads,oneThread, killChilds

-- * backtracking
,undo,onUndo,retry,back,onBack,forward,backPoint,onBackPoint,finish,onFinish,onFinish',localBack

-- * Exceptions

,localExceptionHandlers, onException, onException', cutExceptions, continue, catcht, throwt,exceptionPoint, onExceptionPoint

-- * Utilities
,genId, tr, ttr
)

where


import    Transient.Internals
import    Transient.Console
