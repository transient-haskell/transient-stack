-- runAt and job together, with a node killed in the middle and restarted with its jobs.
-- AJ_CASE:
--   jobterm   the two terms of an applicative have a job inside the remote body; n2 dies during its wait
--   nested    runAt n1 (runAt n2 body): the inner node n2 dies during its wait
--   task      jobTask (applicative of two remote terms without job): it is closed only when the task is completed
--   caller    job; applicative of two slow remote terms; the caller dies during the applicative
--             (the job of the caller stays inside the applicative, so the call is repeated and the result arrives twice)
--   both      job; runAt n1 (job inside); the caller and n1 die together during the wait, restart in either order
--             (restarting n0 first works; restarting n1 first runs the body and delivers the result twice: the job of each node resumes on its own)
--   seqterm   the first term is a sequence of two remote calls, no job
--   seqjob    job; localIO; runAt n1 (body with a job); the caller dies and restarts while n1 stays up
--             (n1 answers over a new connection: the reader of the incoming connection marks it closed at EOF)
--   injob     a job inside the first term of the applicative (the job is executed)
-- The result must arrive once at the caller: "RESULT <value>".
--
-- A job is finished when the call to another node has been sent without error (the later job is in that node, see
-- 'finishJob' in Transient.Move.Internals). So the remote bodies that must survive a fall have a job (@body@), and a
-- remote body without a job (@plain@) is executed at most once when its caller falls.
--
--   ajob -p start/127.0.0.1/<port>/saveonexit                       (a node that is killed)
--   ajob -p start/127.0.0.1/<port>/jobs/exec                        (restart)
module Main where

import Transient.Base
import Transient.Move
import Transient.Move.Job (job, jobTask, runJobs)
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
    "seqterm" -> (,) <$> (do a <- runAt n1 (plain 1 500000); b <- runAt n1 (plain 3 500000); return (a + b))
                     <*> runAt n2 (plain 2 slow)
    "both"    -> do job
                    localIO $ putStrLn "CALLER AFTER JOB"
                    a <- runAt n1 (body 1 slow)
                    return (a, 0)
    "seqjob"  -> do job
                    localIO $ putStrLn "CALLER AFTER JOB"
                    a <- runAt n1 (body 1 slow)
                    return (a, 0)
    "task"    -> jobTask $ do
                    localIO $ putStrLn "CALLER AFTER JOB"
                    (,) <$> runAt n1 (plain 1 slow) <*> runAt n2 (plain 2 slow)
    "caller"  -> do job
                    localIO $ putStrLn "CALLER AFTER JOB"
                    (,) <$> runAt n1 (plain 1 500000) <*> runAt n2 (body 2 slow)
    _         -> (,) <$> (do job; localIO $ putStrLn "JOB IN TERM"; runAt n1 (plain 1 500000))
                      <*> runAt n2 (body 2 slow)
  localIO $ putStrLn $ "RESULT " <> show r
  r1 <- runAt n1 $ localIO $ do putStrLn $ "AFTER AT N1 " <> show r; return r
  localIO $ putStrLn $ "BACK " <> show r1
