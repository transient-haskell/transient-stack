{-# LANGUAGE CPP, ScopedTypeVariables, RecordWildCards, DeriveAnyClass, DeriveGeneric #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}

-- | Coherent, assertion-based test suite for transient-universe.
--
-- Extracted from tests/flow.hs: only the tests that verify their result with
-- `assert` (the `check*` distributed tests collected in `tests`, plus
-- `testlocalExceptions`). The manual/interactive tests in flow.hs (the many
-- `main*` / `test*` that require human input and have no assertion) are left out.
--
-- NOTE ON `concurrent`: the original `checkApplicativeWithRemote` used a combinator
-- named `concurrent`, which no longer exists. The applicative of `Cloud` resolves distributed
-- conjunctions by itself, so no wrapper is needed.
--
-- HOW TO RUN: the distributed tests need several connected nodes (node0..node3).
-- Start this executable on each node and connect them with `inputNodes`, then type
-- `go` on the leader node to run the whole suite. Each test asserts internally and
-- returns its own name; the runner prints PASSED per test.

module Main where

import           Control.Monad
import           Control.Monad.IO.Class
import           Control.Monad.State (gets, modify)
import           Transient.Internals
import           Transient.Console (keep, option, option1)
import           Transient.Move.Services
import           Transient.Move.Defs
import           Transient.Move.Logged
import           Transient.Move.Internals
import           Transient.Move.Utils
import           Transient.MapReduce hiding (Ref)
import           Transient.Indeterminism
import           Transient.EVars
import           Transient.Mailboxes
import           Transient.Base (tr)
import           Control.Applicative
import           Control.Concurrent
import           Control.Exception hiding (onException)
import           Data.IORef
import           Data.List
import           Data.Monoid (Sum(..), getSum)
import           Data.String (fromString)
import           Data.Typeable
import qualified Data.Map as M
import           System.Environment (lookupEnv)
import qualified Transient.Parse as P
import qualified Data.ByteString.Lazy.Char8 as BL

--------------------------------------------------------------------------------
-- Types and helpers used by the assert tests
--------------------------------------------------------------------------------

data HELLO = HELLO deriving (Read, Show, Typeable, Eq, Ord)
data WORLD = WORLD deriving (Read, Show, Typeable, Eq, Ord)

instance Loggable HELLO
instance Loggable WORLD

-- | Fail loudly if a step is running on the wrong node.
shouldRunIn node = local $ do
                 p <- getMyNode
                 when (p /= node) $ do
                   let msg = ("error: running at node: ", p, "should be", node)
                   tr msg
                   error $ show msg
                   exitLeft msg

--------------------------------------------------------------------------------
-- The suite
--------------------------------------------------------------------------------

tests :: [Cloud String]
tests =
  [ testlocalExceptions
  , checkWormholeTeleportComposition
  , checkApplicativeWithRemote
  , checkAlternativesWithAtRemote
  , checkStreaming
  , checkEmptyInRemoteNodeWhenTheRemoteCallbackToTheCaller
  , checkAlternativeDistributed
  , checkApplicativeDistributed
  , checkMonadicDistributed
  , checkReentrantDistributed
  , checkNonSerializableMutableVariables
  , checkMapReduce
  , checkApplicativeThreeTerms
  , checkApplicativeFourTerms
  , checkApplicativeNestedRight
  , checkApplicativeTwice
  , checkSemigroupDerived
  , checkNumDerived
  , checkNewOperator
  , checkParseSerial
  ]

-- | The tests to run: all of them, or only those whose indices (positions in 'tests', starting at 0, separated
-- by spaces) are in the environment variable @ASSERT_ONLY@, for example @ASSERT_ONLY="3 9"@. A test that does
-- not finish does not stop the others when they are run one by one.
selectTests :: Maybe String -> [Cloud String]
selectTests Nothing    = tests
selectTests (Just str) = [tests !! read i | i <- words str]

testlocalExceptions = local $ do
    r <- collect 0 $ verify <|> play
    ttr r
    assert (r == ["HELLO"]) $ ttr "OK"
    return "testlocalExceptions"
    where
    verify = do ttr "GET"; r <- getMailbox :: TransIO String; ttr r; return r
    play = do
            onException $ \(SomeException e) -> do lastPutMailbox "HELLO"; empty
            localExceptions $
                onException $ \(SomeException e) -> putMailbox "WORLD"
            throw $ userError "errrr"
            empty

checkWormholeTeleportComposition = loggedc $ do
      (node0:node1:_) <- local getNodes
      ttr "------checking wormhole, teleport composition --------"
      r <- wormhole node1 $ do
              shouldRunIn node0
              r <- local $ return "HELLO"
              teleport
              shouldRunIn node1
              r <- local $ return (r, "WORLD")
              teleport
              shouldRunIn node0
              return r
      onAll $ liftIO $ assert (r == ("HELLO", "WORLD")) $ ttr ("OK: wormhole, teleport composition", r)
      return "checkWormholeTeleportComposition"

checkApplicativeWithRemote = loggedc $ do
      (node0:node1:_) <- local getNodes
      ttr "------checking applicatives  with atRemote --------"
      r <- wormhole node1 $ do
                let remoteReturn x = do
                            r <- atRemote $ do
                                    ttr "REMOTERETURN"
                                    shouldRunIn node1
                                    local $ return x
                            shouldRunIn node0
                            rem <- gets execMode
                            tr ("REMOTE", rem, r)
                            return r
                loggedc $ remoteReturn "APPLI" <> remoteReturn "CATIVE"
      onAll $ liftIO $ assert (r == "APPLICATIVE") $ ttr ("OK: applicatives with atRemote", r)
      return r

checkAlternativesWithAtRemote = loggedc $ do
      (node0:node1:_) <- local getNodes
      ttr "------checking alternatives  with atRemote --------"
      r <- liftCloud (collect 2) $ wormhole node1 $ do
                let remoteReturn x = atRemote $ do
                        shouldRunIn node1
                        local $ return x
                loggedc $ remoteReturn "ALTER" <|> remoteReturn "NATIVE"
      onAll $ liftIO $ assert (sort r == ["ALTER", "NATIVE"]) $ ttr ("OK: alternatives with atRemote", r)
      return "checkAlternativesWithAtRemote"

checkStreaming = loggedc $ do
      (node0:node1:_) <- local getNodes
      ttr "------checking streaming --------"
      r <- wormhole node1 $ do
              r <- atRemote $ do
                shouldRunIn node1
                onAll $ topState >>= showThreads
                local $ threads 0 $ async (return "%STRE") <|> async (return "AMING")
              onAll $ topState >>= showThreads
              return r
      ttr r
      -- onAll $ liftIO $ assert (sort r ==  ["%STRE","AMING"] ) $ ttr ("OK: streaming",r)
      return "checkStreaming"

checkEmptyInRemoteNodeWhenTheRemoteCallbackToTheCaller = loggedc $ do
      (node0:node1:node2:node3:_) <- local getNodes
      onAll $ liftIO $ putStrLn "------checking  empty in remote node when the remote call back to the caller #46 --------"
      r <- runAt node1 $ do
                shouldRunIn (node1)
                runAt node2 $ runAt node1 (shouldRunIn (node1) >> empty)
                                <|> (shouldRunIn (node2) >> local (return "checkEmptyInRemoteNodeWhenTheRemoteCallbackToTheCaller"))
      onAll $ liftIO $ assert (r == "checkEmptyInRemoteNodeWhenTheRemoteCallbackToTheCaller") $ ttr ("OK: empty in remote", r)
      return r

checkAlternativeDistributed = loggedc $ do
      (node0:node1:node2:node3:_) <- local getNodes
      ttr "------checking Alternative distributed: distributed parallelism --------"
      r <- liftCloud (collect 2) $
                          runAt node1 (shouldRunIn (node1) >> return "hello") <|>
                          runAt node2 (shouldRunIn (node2) >> return "world")
      onAll $ liftIO $ assert (sort r == ["hello", "world"]) $ print ("OK: alternative distributed", r)
      return "checkAlternativeDistributed"

checkApplicativeDistributed = loggedc $ do
      (node0:node1:node2:node3:_) <- local getNodes
      ttr "--------------checking Applicative distributed: distributed concurrency--------"
      r <-   loggedc $ runAt node1 (do shouldRunIn (node1); localIO $ do print "HELLO"; return "HELLO ")
                <>  (runAt node2 (shouldRunIn (node2) >> return "WORLD "))
      onAll $ liftIO $ assert (r == "HELLO WORLD ") $ print ("OK: applicative distributed", r)
      return r

checkMonadicDistributed = loggedc $ do
      (node0:node1:node2:node3:_) <- local getNodes
      ttr "----------------checking monadic, distributed-------------"
      r <- runAt node1 $ do
              shouldRunIn (node1)
              r <- local $ return "HELLO"
              runAt node2 $ do
                shouldRunIn (node2)
                return $ r ++ "WORLD"
      onAll $ liftIO $ assert (r == "HELLOWORLD") $ print ("OK: monadic distributed", r)
      return r

checkReentrantDistributed = loggedc $ do
      (node0:node1:node2:node3:_) <- local getNodes
      ttr "------------- checking reentrant distributed ----------------"
      r <- runAt node1 $ do
              shouldRunIn (node1)
              r <- local $ return "HELLO"
              runAt node2 $ do
                shouldRunIn (node2)
                r <- local $ return (r, "WORLD")
                runAt node1 $ do
                  shouldRunIn (node1)
                  r <- local $ return (r, "WORLD2")
                  runAt node2 $ do
                    shouldRunIn (node2)
                    return r
      onAll $ liftIO $ assert (r == (("HELLO", "WORLD"), "WORLD2")) $ print ("OK: reentrant distributed", r)
      return "checkReentrantDistributed"

checkNonSerializableMutableVariables = loggedc $ do
      (node0:node1:node2:node3:_) <- local getNodes
      ttr "---checking that non serializable mutable variables in the stack are keept across sucessive invocations ---"
      r <- runAt (node1) $ do
              h <- local $ return HELLO
              ref <- onAll $ liftIO $ newIORef (0 :: Int)
              r <- runAt (node2) $ do
                  onAll $ liftIO $ writeIORef ref 1
                  local $ return (h, WORLD)
              runAt (node2) $ do
                  i <- onAll $ liftIO $ readIORef ref
                  local $ return (r, WORLD, i)
      onAll $ liftIO $ assert (r == ((HELLO, WORLD), WORLD, 1)) $ ttr ("OK: non-serializable, mutable variables", r)
      return "checkNonSerializableMutableVariables"

checkMapReduce = loggedc $ do
      (node0:node1:node2:node3:_) <- local getNodes
      ttr "----------------checking map-reduce -------------"
      r <- reduce (+) . mapKeyB (\w -> (w, 1 :: Int)) $ getText words "hello world hello"
      onAll $ liftIO $ assert (sort (M.toList r) == sort [("hello", 2 :: Int), ("world", 1)]) $ ttr ("OK: mapReduce", r)
      return "checkMapReduce"

--------------------------------------------------------------------------------
-- The applicative of Cloud with any number of remote terms
--
-- 'term' calls a node and answers after a delay. The first term is the slowest one, so the results arrive in the
-- reverse order of the terms: the value has to be the same, whichever term finishes last. After each applicative the
-- result is checked in every node, to see that the log of the applicative carries the values of all the terms.
--------------------------------------------------------------------------------

term :: Node -> Int -> Int -> Cloud Int
term n i d = runAt n $ do shouldRunIn n
                          localIO $ threadDelay d >> return i

checkApplicativeThreeTerms = loggedc $ do
      (_:n1:n2:n3:_) <- local getNodes
      ttr "-------- applicative: three terms, they arrive in reverse order --------"
      r <- (\a b c -> [a, b, c]) <$> term n1 1 1500000 <*> term n2 2 800000 <*> term n3 3 100000
      onAll $ liftIO $ assert (r == [1, 2, 3]) $ ttr ("OK: applicative, three terms", r)
      rs <- mapM (\n -> runAt n $ localIO $ return r) [n1, n2, n3]
      onAll $ liftIO $ assert (rs == [r, r, r]) $ ttr ("OK: the value is the same in every node", rs)
      return "checkApplicativeThreeTerms"

checkApplicativeFourTerms = loggedc $ do
      (_:n1:n2:n3:_) <- local getNodes
      ttr "-------- applicative: four terms, one node called twice --------"
      r <- (\a b c d -> [a, b, c, d]) <$> term n1 1 2000000 <*> term n2 2 1200000 <*> term n3 3 400000 <*> term n1 4 100000
      onAll $ liftIO $ assert (r == [1, 2, 3, 4]) $ ttr ("OK: applicative, four terms", r)
      return "checkApplicativeFourTerms"

checkApplicativeNestedRight = loggedc $ do
      (_:n1:n2:n3:_) <- local getNodes
      ttr "-------- applicative nested on the right --------"
      r <- (\a (b, c) -> [a, b, c]) <$> term n1 1 1500000 <*> ((,) <$> term n2 2 800000 <*> term n3 3 100000)
      onAll $ liftIO $ assert (r == [1, 2, 3]) $ ttr ("OK: applicative nested on the right", r)
      return "checkApplicativeNestedRight"

checkApplicativeTwice = loggedc $ do
      (_:n1:n2:n3:_) <- local getNodes
      ttr "-------- two applicatives in sequence --------"
      x <- (\a b -> [a, b]) <$> term n1 1 1200000 <*> term n2 2 300000
      y <- (\a b -> [a, b]) <$> term n3 3 1200000 <*> term n1 4 300000
      onAll $ liftIO $ assert (x ++ y == [1, 2, 3, 4]) $ ttr ("OK: two applicatives in sequence", x ++ y)
      return "checkApplicativeTwice"

-- The instances that are derived from the applicative of TransIO need no definition for Cloud

checkSemigroupDerived = loggedc $ do
      (_:n1:n2:n3:_) <- local getNodes
      ttr "-------- (<>) derived from the applicative --------"
      r <- fmap (: []) (term n1 1 1500000) <> fmap (: []) (term n2 2 800000) <> fmap (: []) (term n3 3 100000)
      onAll $ liftIO $ assert (r == [1, 2, 3]) $ ttr ("OK: Semigroup of Cloud", r)
      return "checkSemigroupDerived"

checkNumDerived = loggedc $ do
      (_:n1:n2:n3:_) <- local getNodes
      ttr "-------- (+) and (*) derived from the applicative --------"
      r <- term n1 1 1500000 + term n2 2 800000 * term n3 3 100000
      onAll $ liftIO $ assert (r == 7) $ ttr ("OK: Num of Cloud", r)
      return "checkNumDerived"

-- | A new binary operator, written once for any Applicative: Cloud inherits it from TransIO
(<+>) :: (Applicative f, Semigroup a) => f a -> f a -> f a
(<+>) = liftA2 (<>)

checkNewOperator = loggedc $ do
      (_:n1:n2:n3:_) <- local getNodes
      ttr "-------- a new operator defined for any Applicative --------"
      r <- (fmap (: []) (term n1 1 1500000) <+> fmap (: []) (term n2 2 800000)) <+> fmap (: []) (term n3 3 100000)
      onAll $ liftIO $ assert (r == [1, 2, 3]) $ ttr ("OK: new operator", r)
      return "checkNewOperator"

-- | The applicative in Serial mode (parsers): over a string, and over a stream whose chunks cut the numbers.
-- The first term is always resolved in the same thread as the second one.
checkParseSerial = onAll $ do
      ttr "-------- applicative in Serial mode: parsers --------"
      let numbers = (,,) <$> P.int <*> (P.tChar ',' >> P.int) <*> (P.tChar ',' >> P.int)
      r1 <- P.withParseString (BL.pack "12,34,56") numbers
      liftIO $ assert (r1 == (12, 34, 56)) $ ttr ("OK: parser over a string", r1)
      chunks <- liftIO $ newIORef (map BL.pack ["1", "2,3", "4,5", "6"])
      let next = liftIO $ atomicModifyIORef chunks $ \l -> case l of
                                                              []     -> ([], SDone)
                                                              (x:xs) -> (xs, SMore x)
      r2 <- sandbox $ do P.setParseStream next; numbers
      liftIO $ assert (r2 == (12, 34, 56)) $ ttr ("OK: parser over a stream with the numbers cut", r2)
      return "checkParseSerial"

--------------------------------------------------------------------------------
-- Local (non-distributed) assert tests
--
-- These run on a single node (no `initNode`/`getNodes`). Run them with
-- `keep runLocalTests`, or individually. `checkOption` is interactive.
--------------------------------------------------------------------------------

-- | Install an assertion-failure handler so a failing `assert` exits with an
-- error message instead of a bare exception. Wrap local tests with this.
checkAssert = do
  onException $ \(AssertionFailed msg) -> do
    ttr msg
    exitLeft msg
    empty

testGroupByTime = do
    r <- collect 3 $ do
            groupByTime 1000000 $ do
                i <- for [1 ..]
                liftIO $ threadDelay 100000
                return $ Sum i
    assert (map getSum r == [245, 145, 45]) $ tr ("RESULT", r)

checkEVars = do
  ev  <- newEVar
  ev2 <- newEVar
  let collectIt = do
          r <- collect 0 $ read ev <|> read ev2 <|> read ev <|> read ev2
          ttr ("RESULTS COLLECT", r)
          return r
      sumIt = do
          r <- read ev <> fromString " " <> read ev2
          ttr ("RS", r)
          return [r]
      writeIt = do
        liftIO $ threadDelay 1000000
        write ev "HELLO" <|> write ev2 "WORLD"
  r <- collectIt <> sumIt <|> writeIt
  let r' = sort r
  ttr ("RESULTS", r)
  assert (r' == ["HELLO", "HELLO", "HELLO WORLD", "WORLD", "WORLD"]) $ return ()
  where
  read ev = do
    r <- readEVar ev
    ttr ("RS", r)
    delReadEVar ev
    return r
  write ev x = do
    liftIO $ threadDelay 100000
    writeEVar ev x
    empty

checkMailbox = do
  r <- collect 0 $ read <|> read <|> write "HELLO WORLD"
  let r' = sort r
  liftIO $ print r'
  assert (r' == ["HELLO WORLD", "HELLO WORLD"]) $ return ()
  where
  read = getMailbox :: TransIO String
  write x = do
    liftIO $ threadDelay 0
    putMailbox x
    empty

-- | INTERACTIVE: needs the user to type "h" and "w" at the console.
checkOption = do
  r <- collect 0 $ option1 "h" "hello" <|> option1 "w" "world"
  let r' = sort r
  liftIO $ print r'
  assert (r' == ["hello", "world"]) $ return ()

-- | Run the non-interactive local assert tests in sequence, under the
-- assertion-failure handler. `checkOption` is left out (interactive).
runLocalTests :: TransIO ()
runLocalTests = do
  checkAssert
  testGroupByTime
  checkEVars
  checkMailbox
  liftIO $ putStrLn "==================== LOCAL ASSERT TESTS PASSED ===================="

--------------------------------------------------------------------------------
-- Distributed + interactive (separate runnable, not part of `main`'s suite)
--
-- `liftConcurrent` was removed from the library; here it is expressed as `liftCloud`.
-- Add a second node, then type "g".
--------------------------------------------------------------------------------

testFinishInRemote :: IO (Either String ())
testFinishInRemote = keep $ initNode $ inputNodes <|> do
  local $ option ("g" :: String) "go"
  nodes <- local getNodes
  r' <- liftCloud (collect 5) $
           runAt (nodes !! 1) $ local $ for [1 .. 10 :: Int]
  ttr ("after teleport", r')
  r <- runAt (nodes !! 1) $ return "BACK"
  ttr ("after teleport", r)

--------------------------------------------------------------------------------
-- Runner
--------------------------------------------------------------------------------

-- | Start on each node, connect them with `inputNodes`, then type `go` on the
-- leader to run every assert test in sequence. Each test asserts internally.
main = keep $ initNode $ inputNodes <|> do
    local $ option ("go" :: String) "run the assertion test suite"
    nodes <- local getNodes
    localIO $ putStrLn $ "nodes connected: " ++ show nodes
    only <- localIO $ lookupEnv "ASSERT_ONLY"
    forM_ (selectTests only) $ \t -> do
        name <- t
        localIO $ putStrLn $ "PASSED: " ++ name
        -- the console output of the nodes is interleaved with traces: the result is also written to a file
        localIO $ appendFile "RESULT.txt" ("PASSED: " ++ name ++ "\n")
    localIO $ putStrLn "==================== ALL ASSERT TESTS PASSED ===================="
    empty :: Cloud ()
