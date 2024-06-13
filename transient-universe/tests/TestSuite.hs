{-# LANGUAGE CPP, ScopedTypeVariables #-}
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
import           Transient.Move.Internals
import           Transient.Move.Utils
import           Transient.Move.Services
-- import           Transient.MapReduce
import           Data.List
import qualified Data.Map as M
import           System.Exit
import           Control.Monad.State
import           Control.Exception
import           Control.Concurrent.MVar

import           Control.Concurrent(threadDelay )


#define SHOULDRUNIN(x)    (local $ do p <-getMyNode;assert ( p == (x)) (liftIO $ print p))


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
       Nothing -> print "NO RESULT, NO THREADS RUNNING" >> exitFailure
       Just Nothing  -> print  "SUCCESS" >> exitSuccess 
       Just (Just e) -> putStr "FAIL: "  >> print e >> exitFailure

 

portnumber= 8081

liftA1 tcomp ccomp= local $ tcomp $ runCloud ccomp

test=  initNodeServ service  "localhost" portnumber $ do

    -- ( thereIsArgPath' >> interactive >>= testIt)  <|> 
    (batchTest >>= testIt >> exitIt )



thereIsArgPath'= local $ Transient $ liftIO $ do
  ph <- thereIsArgPath
  if null ph then return Nothing else return $ Just ph

interactive= do
    liftA1 fork  inputNodes
    local $ sync $ ( option "f" "fire")
    local $ do ns <- getNodes
               return $ tail ns

    
exitIt= onAll $ exit (Nothing  :: Maybe SomeException)

batchTest= do
          localIO $ print "batchtest"
          node0 <- local getMyNode
          local $ guard (nodePort node0== portnumber)       -- only executes locally in node "portnumber"
          localIO $ print "REQEST"
          requestInstance service 3



testIt nodes = do
          let node1:node2:node3:_ = nodes
          node0 <- local getMyNode
          -- onAll $ liftIO $ print (node1)
      --     onAll $ ttr ("node1",node1,"node2",node2)

          localIO $ putStrLn "------checking  empty in remote node when the remote call back to the caller #46 --------"
          
          -- runAt node1 $ runAt node2 $ runAt node1 $ return "hello"
          -- empty

          r <- runAt node1 $ do
                   runAt node2 $  (runAt node1 $ SHOULDRUNIN(node1) >>  return "hello" ) 
                   
          localIO $ putStrLn r

          empty
          

          -- localIO $ putStrLn "------checking Alternative distributed--------"


          -- r <-  (runAt node0 (SHOULDRUNIN( node0) >> return "hello" )) <|>
          --        (runAt node1 (SHOULDRUNIN( node1) >> return "world" )) -- <|>
          --       -- (runAt node2 (SHOULDRUNIN( node2) >> return "world2" ))
          -- -- 
          
          -- -- assert(sort r== ["hello", "world"]) $ localIO $  print r

          -- -- r <- runAt node1 $ local $ return "world "
          -- localIO $ print r
          -- empty

          
          -- localIO $ putStrLn "--------------checking Applicative distributed--------"
          -- r <- loggedc $(runAt node0 (SHOULDRUNIN( node0) >> return "hello "))
          --           <>  (runAt node1 (SHOULDRUNIN( node1) >> return "world " ))
          --           -- <>  (runAt node2 (SHOULDRUNIN( node2) >> return "world2" ))
       
          -- assert(r== "hello world ") $ localIO $ print r

          localIO $ putStrLn "----------------checking monadic, distributed-------------"
          r <- runAt node0 (SHOULDRUNIN(node0)
                  >> runAt node1 (SHOULDRUNIN(node1) >>  (return "HELLO" )))
                      --  >> runAt node2 (SHOULDRUNIN(node2) >>  (return "HELLO" ))))

          assert(r== "HELLO") $ localIO $ print r
 
          -- -- localIO $ putStrLn "----------------checking map-reduce -------------"

          -- r <- reduce  (+)  . mapKeyB (\w -> (w, 1 :: Int))  $ getText  words "hello world hello"
          -- localIO $  print r
          -- assert (sort (M.toList r) == sort [("hello",2::Int),("world",1)]) $ return r
          
          return  (Nothing  :: Maybe SomeException) 

          
 


#else
main= return ()
#endif
