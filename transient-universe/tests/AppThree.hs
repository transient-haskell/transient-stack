-- Applicative of three remote terms, one in each remote node. Then, a call to each node.
--
-- APPWAIT_D="d1,d2,d3" sets the delays in microseconds of the three terms (default 100000,300000,500000):
-- the order of the delays is the order of termination of the terms.
--
--   appthree -p start/127.0.0.1/9001
--   appthree -p start/127.0.0.1/9002
--   appthree -p start/127.0.0.1/9003
--   appthree -p start/127.0.0.1/9000/add/127.0.0.1/9001/n/add/127.0.0.1/9002/n/add/127.0.0.1/9003/n/go
module Main where

import Transient.Base
import Transient.Move
import Transient.Move.Utils (initNode, inputNodes)
import Control.Applicative
import Control.Monad (void)
import Control.Concurrent (threadDelay)
import System.Environment (lookupEnv)

main :: IO ()
main = void $ keep $ initNode $ inputNodes <|> do
  local $ option "go" "run the test"
  [_, n1, n2, n3] <- local getNodes
  [d1, d2, d3] <- localIO $ maybe [100000, 300000, 500000] (\s -> read ("[" <> s <> "]")) <$> lookupEnv "APPWAIT_D"

  let term n d i = runAt n (localIO $ do threadDelay d; putStrLn $ "TERM" <> show i <> " executed"; return (i :: Int))

  r <- (,,) <$> term n1 d1 1 <*> term n2 d2 2 <*> term n3 d3 3
  localIO $ putStrLn $ "APPLICATIVE RESOLVED " <> show r

  r1 <- runAt n1 $ localIO $ do putStrLn $ "AFTER APPLICATIVE AT N1 " <> show r; return r
  localIO $ putStrLn $ "BACK FROM N1 " <> show r1
  r2 <- runAt n2 $ localIO $ do putStrLn $ "AFTER APPLICATIVE AT N2 " <> show r; return r
  localIO $ putStrLn $ "BACK FROM N2 " <> show r2
  r3 <- runAt n3 $ localIO $ do putStrLn $ "AFTER APPLICATIVE AT N3 " <> show r; return r
  localIO $ putStrLn $ "BACK FROM N3 " <> show r3

  localIO $ putStrLn "TEST END"
