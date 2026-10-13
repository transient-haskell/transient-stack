-- The called node restarts while serving a runAt. The body of the runAt has a job (durable checkpoint) and a wait.
-- After the restart, the job is replayed and the node must respond to the caller, which is still waiting:
-- the closure to respond to (ClosToRespond) and the node of the caller must survive the restart.
--
--   runatrestart -p start/127.0.0.1/9601/saveonexit                (called node; killed during the wait)
--   runatrestart -p start/127.0.0.1/9601/jobs/exec                 (called node, restarted)
--   runatrestart -p start/127.0.0.1/9600/add/127.0.0.1/9601/n/go   (caller)
-- RR_DELAY: microseconds of the wait of the called node (default 8000000)
module Main where

import Transient.Base
import Transient.Move
import Transient.Move.Job (job, runJobs)
import Transient.Move.Utils (initNode, inputNodes)
import Control.Applicative
import Control.Monad (void)
import Control.Concurrent (threadDelay)
import System.Environment (lookupEnv)

main :: IO ()
main = void $ keep $ initNode $ inputNodes <|> do
  runJobs
  local $ option "go" "run the test"
  [_, n1] <- local getNodes
  delay <- localIO $ maybe 8000000 read <$> lookupEnv "RR_DELAY"
  r <- runAt n1 $ do
         x <- local $ return ("before" :: String)
         job
         localIO $ do putStrLn "N1 WORKING"; threadDelay delay
         local $ return (x <> " after")
  localIO $ putStrLn $ "RESULT " <> r
