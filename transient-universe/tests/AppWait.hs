{-# LANGUAGE ScopedTypeVariables #-}
-- Test of the mutable "w/" holes of logged inside an applicative (branch exp/applicative-wait).
--
-- The applicative launches one term on each remote node. Afterwards the computation must go on
-- beyond the applicative, in the local node and in both remote nodes.
--
-- Three processes, each in its own directory (TCache state):
--   appwait -p start/localhost/8001
--   appwait -p start/localhost/8002
--   appwait -p start/localhost/8000/add/localhost/8001/n/add/localhost/8002/n/go
--
-- APPWAIT_SWAP=1 in the calling node reverses the delays (the first term finishes last).
module Main where

import Transient.Base
import Transient.Move
import Transient.Move.Utils (initNode, inputNodes)
import Control.Applicative
import Control.Monad.IO.Class
import Control.Monad (void)
import Control.Concurrent (threadDelay)
import System.Environment (lookupEnv)

main :: IO ()
main = void $ keep $ initNode $ inputNodes <|> do
  local $ option "go" "run the test"
  nodes <- local getNodes
  swap  <- localIO $ maybe False (== "1") <$> lookupEnv "APPWAIT_SWAP"
  let (n1, n2) = (nodes !! 1, nodes !! 2)
      (d1, d2) = if swap then (500000, 100000) else (100000, 500000)

  monad <- localIO $ maybe False (== "1") <$> lookupEnv "APPWAIT_MONAD"
  let term1 = runAt n1 (localIO $ do threadDelay d1; putStrLn "TERM1 executed"; return (1 :: Int))
      term2 = runAt n2 (localIO $ do threadDelay d2; putStrLn "TERM2 executed"; return (2 :: Int))

  -- APPWAIT_MONAD=1: same terms in sequence, without applicative (baseline)
  r <- if monad then do { a <- term1; b <- term2; return (a, b) }
                else (,) <$> term1 <*> term2
  let mode = if monad then "SEQUENCE" else "APPLICATIVE"
  localIO $ putStrLn $ mode <> " RESOLVED " <> show r

  r1 <- runAt n1 $ localIO $ do putStrLn $ "AFTER " <> mode <> " AT N1 " <> show r; return r
  localIO $ putStrLn $ "BACK FROM N1 " <> show r1

  r2 <- runAt n2 $ localIO $ do putStrLn $ "AFTER " <> mode <> " AT N2 " <> show r; return r
  localIO $ putStrLn $ "BACK FROM N2 " <> show r2

  localIO $ putStrLn "TEST END"
