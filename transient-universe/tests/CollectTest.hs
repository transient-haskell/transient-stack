-- collectc with minput and jobs: two calls to the endpoint "test" are collected. Restart-proof.
--   collecttest -p start/127.0.0.1/9900/saveonexit
--   curl http://127.0.0.1:9900/test/a ; curl http://127.0.0.1:9900/test/b
--   (restart in the same directory with  -p start/127.0.0.1/9900/jobs/exec  to resume the jobs)
module Main where

import Transient.Base
import Transient.Move
import Transient.Move.Web
import Transient.Move.Job (collectc, runJobs)
import Transient.Move.Utils (initNode)
import Control.Applicative
import Control.Monad (void)

main :: IO ()
main = void $ keep $ initNode $ do
  runJobs
  r <- collectc 2 0 $ minput "test" ("enter string" :: String) :: Cloud [String]
  -- the console is not synchronised: this line gets mixed up with the traces of other threads. The scripts read the files.
  localIO $ appendFile "collected.txt" (show r <> "\n")
  localIO $ putStrLn $ "COLLECTED " <> show r
  localIO $ appendFile "reached-results.txt" "1\n"
  minput "results" ("see results" :: String) :: Cloud ()
  -- this runs only when the endpoint "results" is invoked: the scripts use it to check that the endpoint exists and works
  localIO $ appendFile "results-called.txt" "1\n"
