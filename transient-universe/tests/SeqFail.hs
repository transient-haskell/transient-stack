-- Sequential remote calls: node1, node2, node1 again.
-- The third call fails in node1.
--
--   seqfail -p start/127.0.0.1/8001
--   seqfail -p start/127.0.0.1/8002
--   seqfail -p start/127.0.0.1/8000/add/127.0.0.1/8001/n/add/127.0.0.1/8002/n/go
module Main where

import Transient.Base
import Transient.Move
import Transient.Move.Utils (initNode, inputNodes)
import Control.Applicative
import Control.Monad (void)

main :: IO ()
main = void $ keep $ initNode $ inputNodes <|> do
  local $ option "go" "run the test"
  [_, node1, node2] <- local getNodes

  a <- runAt node1 $ localIO $ return (1 :: Int)
  b <- runAt node2 $ localIO $ return (2 :: Int)
  runAt node1 $ localIO $ putStrLn $ "RESULT " <> show (a, b)
