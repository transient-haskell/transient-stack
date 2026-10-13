-- runAt and job together, with a node killed in the middle and restarted with its jobs.
-- AJ_CASE:
--   jobterm   the two terms of an applicative have a job inside the remote body; n2 dies during its wait
--   nested    runAt n1 (runAt n2 body): the inner node n2 dies during its wait
--   caller    job; applicative of two slow remote terms; the caller dies during the applicative
--   injob     job inside the first term of the applicative (KNOWN TO FAIL: no result, n2 re-executes the job and the body of the first term)
-- The result must arrive once at the caller: "RESULT <value>".
--
--   ajob -p start/127.0.0.1/<port>/saveonexit                       (a node that is killed)
--   ajob -p start/127.0.0.1/<port>/jobs/exec                        (restart)
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
  [_, n1, n2] <- local getNodes
  c <- localIO $ maybe "jobterm" id <$> lookupEnv "AJ_CASE"
  slow <- localIO $ maybe 8000000 read <$> lookupEnv "AJ_SLOW"

  let body :: Int -> Int -> Cloud Int
      body i d = do
        local $ return ()
        job
        localIO $ do putStrLn $ "WORK " <> show i; threadDelay d
        local $ return i
      plain i d = localIO $ do putStrLn $ "TERM " <> show i; threadDelay d; return (i :: Int)

  r <- case c of
    "jobterm" -> (,) <$> runAt n1 (body 1 500000) <*> runAt n2 (body 2 slow)
    "nested"  -> do x <- runAt n1 $ do y <- runAt n2 (body 2 slow)
                                       return (y + 10)
                    return (x, 0)
    "caller"  -> do job
                    localIO $ putStrLn "CALLER AFTER JOB"
                    (,) <$> runAt n1 (plain 1 500000) <*> runAt n2 (plain 2 slow)
    _         -> (,) <$> (do job; localIO $ putStrLn "JOB IN TERM"; runAt n1 (plain 1 500000))
                      <*> runAt n2 (plain 2 slow)
  localIO $ putStrLn $ "RESULT " <> show r
  r1 <- runAt n1 $ localIO $ do putStrLn $ "AFTER AT N1 " <> show r; return r
  localIO $ putStrLn $ "BACK " <> show r1
