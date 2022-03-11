#!/usr/bin/env execthirdlinedocker.sh
--  info: use sed -i 's/\r//g' file if report "/usr/bin/env: ‘execthirdlinedocker.sh\r’: No such file or directory"
-- LIB=/projects/transient-stack/ && ghc  -DDEBUG -threaded  -i${LIB}/transient/src -i${LIB}/transient-universe/src -i${LIB}/transient-universe-tls/src -i${LIB}/axiom/src   $1 && ./`basename $1 .hs` ${2} ${3}

-- mkdir -p ./static && ghcjs --make   -i../transient/src -i../transient-universe/src -i../transient-universe-tls/src  -i../axiom/src   $1 -o static/out && runghc   -i../transient/src -i../transient-universe/src -i../axiom/src   $1 ${2} ${3}
-- 

-- cd /projects/transient && cabal install -f debug --force-reinstalls && cd ../transient-universe && cabal install --force-reinstalls &&  runghc $1 $2 $3 $4

{-# LANGUAGE ScopedTypeVariables, FlexibleInstances #-}
module Main where

import Transient.Base
import Transient.Move.Internals
import Transient.Internals
import Transient.Move.Utils
import Control.Applicative
import Control.Monad.IO.Class
import Control.Monad.State
import qualified Data.Vector as V hiding (empty)
import Control.Concurrent
import Transient.EVars
-- import Transient.Move.Services
import Transient.Mailboxes
import Transient.Indeterminism
import Data.TCache


-- main2= keep $ do 
--      i <- threads 0 $ choose[0..]
--      abduce
--      liftIO $ threadDelay 1000000

--      liftIO $ print (i :: Int)

-- main5= keep' $ initNode $ do
--     result <- local $ heavycomputation
--     teleport
--     str <- local $ return "firstparam"
--     str2 <- local $ return "secondparam"
--     showURL
--     process result str str2
--     teleport
--     where
--     heavycomputation= return "heavycompresult"
--     process result  str str2= local $ return  $ result++ str++str2

-- main3 = keep $ initNode $ hi "hello" <|> hi "world"
--   where
--   hi text= do
--      showURL
--      localIO $ putStrLn text
--      teleport  <** modify (\s -> s{execMode=Remote})
    {- 
main4 = do initTLS; keep $ initNode $ inputNodes <|> hi
  where
  ps= onAll $ do
            conn <- getSData
            sdata <- liftIO $ readIORef $ connData conn
            case sdata of
                Just (HTTPS2Node _) -> liftIO$ print "SSL XXXXXXXXXXXXXXXXXXX"

                Just (TLSNode2Node _) -> liftIO$ print "SSL XXXXXXXXXXXXXXXXXXX"
                _ -> liftIO $ print "NOSSL YYYYYYYYYYYYYYYYYYY"
  hi = do
        ps 
        showURL
        localIO $ putStrLn "hello"
        let x= "hello "
        ps
        teleport
        showURL 
        localIO $ print $ x ++ "world"
        teleport
        
-}

      


  
-- test11= localIO $ print "hello world"
-- test10= do
--     localIO $ putStrLn "hello world"
--     local $ return (42 :: Int)
--     teleport

data HELLO= HELLO deriving (Read,Show)
instance Loggable HELLO

data WORLD= WORLD deriving (Read,Show)
instance Loggable WORLD

data WORLD2= WORLD2 deriving (Read,Show)
instance Loggable WORLD2

save= local $ do
    option "save" "save execution state"
    liftIO $ syncCache

data INTER= INTER deriving (Read,Show)

instance Loggable INTER

main =  keep $  initNode $ save <|> inputNodes <|>  do
    local $ option "go" "go" 
    node <- local $ getNodes >>= return . (!! 1)
    x <- local $ return HELLO
    -- h <- runAt node $ do
    --        r <- localIO $ do print x ; return INTER
    --        localIO $ return WORLD
    h <- wormhole node $ loggedc $ do
          loggedc teleport
          localIO $ print x 
          r <- localIO $ return WORLD
          teleport
          return r
         
    local $ do
      log <-getLog
      tr log
      liftIO $ print h

    -- h <- runAt node $ do
         
    --      localIO $ print x 
    --      localIO $ return WORLD2
    h <- wormhole node $  do
          loggedc teleport
          localIO $ print x 
          r <- localIO $ return WORLD2
          teleport
          return r
    localIO $ print h

--     node <- otherNode

--     wormhole node $ local $  do
--         void $ local $ option "r" "run"
--         i <-  atRemote $ do 
--                 showURL
--                 localIO $ print "hello"
                
--                 i <- local $   threads 0 $ choose[1:: Int ..]
--                 localIO $ threadDelay 1000000
--                 return i
--         localIO $ print i
--    where
--    otherNode= local $ do
--            nodes <-  getNodes
--            guard $ length nodes > 1
--            return $ nodes !! 1
--    atOtherNode doit= do
--      node <- otherNode
--      runAt node  doit

-- test8 =  do
--     --local $ option "r" "r"
--     delData Serial
--     n <- local getMyNode
--     r <- (runAt n (local getMailbox) <> runAt n (local getMailbox) <> runAt n (local getMailbox)) <|> (local $ putMailbox "hello " >> empty) 
--     -- r <- (return [3] <> (async (do print "here";return [5]:: IO [Int]) >> empty)) <|> liftIO (do print "here2"; return [7])
--     localIO $ print (r  :: String)

-- --initNode $ inputNodes <|> test7


-- service= [("service","test suite")
--          ,("executable", "test-transient1")
--          ,("package","https://github.com/agocorona/transient-universe")]


-- test7= do 
--     ins <- requestInstance service 1 
--     localIO $ print ins

-- test6= do
--     -- setData Parallel
--     ((async getLine  >> return ())<> (liftIO $ print "world")) -- <|> liftIO (print "hello") 

-- test5= do
--    -- option "r" "run"
--    v1 <- liftIO $ newEmptyMVar

--    setData Parallel
--    (proc v1 <> proc2 ) <|> 
--             (do  liftIO $ threadDelay 1000000 ; async $ putMVar v1 ("hello" :: String) )
--    -- liftIO $ print (r :: String) 
--    where
--    proc2= liftIO $ print "world"
--    proc v1=do
--       --v <-  liftIO . atomically $ dupTChan v1
--       liftIO $ print "PROC"
      
--       (async $ do (readMVar v1) >>= print)

{-
mainsample= keep $ initNode $ do
  othernode <- localIO $ createNode "somehost" 8000
  r <-  (local $ do
          option 1 "one"                        <|> 
            async (return 2)                    <|>
            choose (repeat 3)                   <|>
            (do react' someCallback ; return 4) <|>
            return 5)
                                                <|>
        (runAt othernode $ local $ do
          option 6 "six"                        <|>
            async (return 7)                    <|>
            choose (repeat 8)                   <|>
            (do react' someCallback ; return 9) <|>
            return 10)

    
  localIO $ print $ case r of
      1 -> "console input"
      2 -> "asynchronous result"
      3 -> "An infinite stream of '3's"
      4 -> "some callback invoked"
      5 -> "synchronous result"
      6 -> "console input in the other node"
      7 -> "asynchronous result from the other node"
      8 -> "A stream of '8's from the other node"
      9 -> "some callback invoked in the other node"
      10 -> "synchronous result from the other node"
  where
    someCallback :: (a -> IO ()) -> IO ()
    someCallback= undefined
    react' x= react x $ return()

-}


-- test3= do
--     v <- newEVar
--     -- option "r" "run"
--     setData Parallel
--     r <- (readEVar v <> readEVar v) <|> (do liftIO $ threadDelay 1000000; writeEVar v "hello" >> empty)
--     liftIO $ print (r :: String)

-- test2=  do
--   option "r" "run"
--   setData Parallel
--   r <- (async (return "1") ) <> (async (return "2")) <|> (do liftIO $ threadDelay 10000000;async (print "3") >> empty)

--   --r <- (getMailbox <> getMailbox) <|> (do liftIO $ threadDelay 10000000; putMailbox (1 :: Int) >> empty)
  
--   liftIO $ print (r :: String)
  
-- test12= do
--     local $ option "r" "run"
--     ns <- local getNodes
--     r  <- runAt (ns !! 1) proc1 <> runAt (ns !! 2) proc2
--     localIO $ print r
--     where
--     proc2= local $ return "hello from 3001"

--     proc1= local $ do
--             n <- getMyNode
--             liftIO $ threadDelay 5000000
--             return "hello from 3000" 
            
            
-- test1= do
--     local $ option "r" "run"
--     n <- local $ do ns <- getNodes; return $ ns !! 1
--     localIO $ return () !> "RRRRRR"
--     r <- (mclustered  (local getMailbox))  <|> do
--                 local $ option "s" "run"
--                 localIO $ return () !> "SSSSSS"
--                 runAt n $ local $ do 
--                     putMailbox $ "hello "
--                     empty

--     localIO $ print (r :: String)
   
-- test= do
--         let content= "hello world hello"
--         local $ option "r" "run"  
--         r <- reduce (+) $ mapKeyB (\w -> (w, 1 :: Int))  $ distribute $ V.fromList $ words content
--    --     localIO $ print  ("MAP RESULT=", dds)
--   --      -- local $ option "red" "reduce"
-- --        localIO $ getNodes >>= \n -> print ("NODES1", n)
--     --    r <- reduce (+) $ DDS $ return dds
--         localIO $ putStr "result:" >> print r

--         localIO $ print "DONE"
        