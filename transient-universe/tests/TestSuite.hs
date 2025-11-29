{-# LANGUAGE CPP, ScopedTypeVariables #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}
{-# HLINT ignore "Move brackets to avoid $" #-}
{-# HLINT ignore "Redundant bracket" #-}
module Main where

#ifndef ghcjs_HOST_OS

import           Control.Monad
import           Control.Monad.IO.Class
import           Control.Applicative
import           Data.Monoid
import           Transient.Base
import           Transient.Internals
import           Transient.Console
import           Transient.Indeterminism
import           Transient.Loggable

import           Transient.Move.Logged
import           Transient.Move.Internals
import           Transient.Loggable
import           Transient.Move.Utils
import           Transient.Move.Defs
import           Transient.Move.Services
-- import           Transient.MapReduce
import           Data.List
import qualified Data.Map as M
import           System.Exit
import           Control.Monad.State
import           Control.Exception
import           Control.Concurrent.MVar

import           Control.Concurrent(threadDelay )
import           Data.Typeable


#define SHOULDRUNIN(x)    (local $ do p <-getMyNode;tr p;assert ( p == (x)) (liftIO $ print ("running at node: " <> show x)))


-- #define _UPK_(x) {-# UNPACK #-} !(x)

-- SHOULDRUNIN x=  local $ getMyNode >>= \p ->  assert ( p == (x)) (liftIO $ print p)

service= Service $ M.fromList
         [("service","test suite")
         ,("executable", "test-transient1")
         ,("package","https://github.com/agocorona/transient-universe")]




main= do
     mr <- keep test
     endMonitor 

     case mr of
       Left _ -> print "NO RESULT, NO THREADS RUNNING" >> exitFailure
       Right Nothing  -> print  "SUCCESS" >> exitSuccess 
       Right (Just e) -> putStr "FAIL: "  >> print e >> exitFailure

 

portnumber= 8081

liftA1 tcomp ccomp= local $ tcomp $ unCloud ccomp

test=  initNodeServ service  "localhost" portnumber $ do

    -- ( thereIsArgPath' >> interactive >>= testIt)  <|> 
    (batchTest >>= testIt >> exitIt )



thereIsArgPath'= local $ Transient $ liftIO $ do
  ph <- thereIsArgPath
  if null ph then return Nothing else return $ Just ph

interactive= do
    liftA1 fork  inputNodes
    local $ sync $ option "f" "fire"
    local $ do ns <- getNodes
               return $ tail ns

    
exitIt= onAll $ exit (Nothing  :: Maybe SomeException)

batchTest= do
          n <- local getMyNode
          local $ guard (nodePort n== portnumber)       -- only executes locally in node "portnumber"

          requestInstance service 3




testIt nodes = do
          let node1:node2:node3:_ = nodes 
          tr nodes
          node0 <- local getMyNode



          -- localIO $ putStrLn "------checking  empty in remote node when the remote call back to the caller #46 --------"


          -- r <- runAt node1 $ do
          --           local $ getMyNode >>= \n -> tr ("node1",n)
          --           SHOULDRUNIN(node1)
          --           runAt node2 $ (runAt node1 $ SHOULDRUNIN(node1) >> empty)  <|>   (SHOULDRUNIN(node2) >> return "world")
          -- localIO $ print r 

          -- localIO $ putStrLn "------checking Alternative distributed--------"


          -- r <- local $ collect 3 $ unCloud $ 
          --                     runAt node0 (SHOULDRUNIN(node0) >> return "hello" ) <|>
          --                     runAt node1 (SHOULDRUNIN(node1) >> return "world" ) <|>
          --                     runAt node2 (SHOULDRUNIN(node2) >> return "world2")
          
          -- assert(sort r== ["hello", "world", "world2"]) $ localIO $  print r

          

          
          -- localIO $ putStrLn "--------------checking Applicative distributed--------"
          -- r <- loggedc $ (runAt node0 (SHOULDRUNIN( node0) >> return "hello "))
          --           <>  (runAt node1 (SHOULDRUNIN( node1) >> return "world " ))
          --           <>  (runAt node2 (SHOULDRUNIN( node2) >> return "world2" ))
       
          -- assert(r== "hello world world2") $ localIO $ print r


          
          localIO $ putStrLn "----------------checking monadic, distributed-------------"
          r <- runAt node0 (SHOULDRUNIN(node0)
                  >> runAt node1 (SHOULDRUNIN(node1)
                       >> runAt node2 (SHOULDRUNIN(node2) >>  (return "HELLO" ))))

          assert(r== "HELLO") $ localIO $ print r
 
          -- -- localIO $ putStrLn "----------------checking map-reduce -------------"

          -- r <- reduce  (+)  . mapKeyB (\w -> (w, 1 :: Int))  $ getText  words "hello world hello"
          -- localIO $  print r
          -- assert (sort (M.toList r) == sort [("hello",2::Int),("world",1)]) $ return r
          
          return  (Nothing  :: Maybe SomeException) 

          
 


#else
main= return ()
#endif
