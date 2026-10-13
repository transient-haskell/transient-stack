-- Restart after an applicative: the job after the applicative saves its closure; when the program is
-- restarted with the "jobs" and "exec" options, it must continue from the job reading both values from
-- the log, without executing the terms again.
--
--   first run:   apprestart -p start/127.0.0.1/9000/add/127.0.0.1/9001/n/add/127.0.0.1/9002/n/go
--   second run:  apprestart -p start/127.0.0.1/9000/add/127.0.0.1/9001/n/add/127.0.0.1/9002/n/jobs/exec
--   (same directory, the nodes 9001 and 9002 run apprestart -p start/127.0.0.1/<port>)
--
-- APPWAIT_SWAP=1 reverses the delays (the first term finishes last).
module Main where

import Transient.Base
import Transient.Move
import Transient.Move.Job (runJobs, job)
import Transient.Move.Utils (initNode, inputNodes)
import Control.Applicative
import Control.Monad (void)
import Control.Concurrent (threadDelay)
import System.Environment (lookupEnv)

main :: IO ()
main = void $ keep $ initNode $ inputNodes <|> do
  runJobs
  local $ option "go" "run the test"
  [_, n1, n2] <- local getNodes
  swap <- localIO $ maybe False (== "1") <$> lookupEnv "APPWAIT_SWAP"
  let (d1, d2) = if swap then (500000, 100000) else (100000, 500000)

  r <- (,) <$> runAt n1 (localIO $ do threadDelay d1; putStrLn "TERM1 executed"; return (1 :: Int))
           <*> runAt n2 (localIO $ do threadDelay d2; putStrLn "TERM2 executed"; return (2 :: Int))
  localIO $ putStrLn $ "APPLICATIVE RESOLVED " <> show r

  job
  localIO $ putStrLn $ "AFTER JOB " <> show r
