-- | Driver of the cabal test-suite @distributed@: it runs, one by one, the distributed tests of @AssertTests.hs@ in four nodes
-- of the same machine (the leader and three more), as @runassert.sh@ does, and reads the result of each one from the
-- file @RESULT.txt@ that the leader writes (the console of the nodes is full of interleaved traces).
--
-- > cabal test distributed
-- > DISTRIBUTED_ONLY="3 9" cabal test distributed      -- only the tests with those indices
--
-- The exit code is the number of tests that did not pass.
module Main where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, try)
import Control.Monad
import System.Directory
import System.Environment
import System.Exit
import System.FilePath
import System.IO
import System.Process
import System.Timeout (timeout)

-- | the first port of the first test; each test uses ten ports
basePort :: Int
basePort = 21000

-- | seconds that the leader has to finish a test
timeLimit :: Int
timeLimit = 25

main :: IO ()
main = do
  exe   <- findExecutable "assert-tests" >>= maybe (die "assert-tests is not in the path: it is a build tool of this test-suite") return
  total <- countTests exe
  only  <- lookupEnv "DISTRIBUTED_ONLY"
  let indices = maybe [0 .. total - 1] (map read . words) only
  work <- (</> "dist-distributed") <$> getCurrentDirectory
  results <- forM (zip [0 ..] indices) $ \(k, i) -> do
    ok <- runOne exe work i (basePort + k * 10)
    putStrLn $ (if ok then "PASS  " else "FAIL  ") ++ "test " ++ show i
    hFlush stdout
    return ok
  let failed = length (filter not results)
  putStrLn $ show (length results - failed) ++ " of " ++ show (length results) ++ " tests passed"
  when (failed > 0) $ exitWith (ExitFailure failed)

-- | number of tests of @AssertTests.hs@
countTests :: FilePath -> IO Int
countTests exe = do
  base <- getEnvironment
  (_, out, _) <- readCreateProcessWithExitCode (proc exe []) {env = Just (("ASSERT_COUNT", "1") : base)} ""
  return $ read $ last $ lines out

-- | wait for a process up to a number of half seconds. It polls: 'waitForProcess' blocks the non-threaded runtime and
-- 'timeout' could not interrupt it
waitUpTo :: Int -> ProcessHandle -> IO ()
waitUpTo 0 _ = return ()
waitUpTo n ph = do
  r <- getProcessExitCode ph
  case r of
    Just _  -> return ()
    Nothing -> threadDelay 500000 >> waitUpTo (n - 1) ph

-- | a test: three nodes that wait, and the leader that connects to them and runs only the test with that index
runOne :: FilePath -> FilePath -> Int -> Int -> IO Bool
runOne exe work i port = do
  let dir = work </> ("test" ++ show i)
  removePathForcibly dir
  forM_ ["n0", "n1", "n2", "n3"] $ \n -> createDirectoryIfMissing True (dir </> n)
  base <- getEnvironment
  let start n args = do
        out <- openFile (dir </> n </> "out.log") WriteMode
        (Just hin, _, _, ph) <- createProcess (proc exe ["-p", args])
                                  { cwd = Just (dir </> n)
                                  , env = Just (("ASSERT_ONLY", show i) : base)
                                  , std_in = CreatePipe, std_out = UseHandle out, std_err = UseHandle out }
        return (hin, ph)      -- the stdin stays open: a node that reads end of file would finish
  nodes <- forM [1, 2, 3] $ \j -> start ("n" ++ show j) ("start/127.0.0.1/" ++ show (port + j))
  threadDelay 5000000
  let add j = "/add/127.0.0.1/" ++ show (port + j) ++ "/n"
  (lin, lph) <- start "n0" ("start/127.0.0.1/" ++ show port ++ add 1 ++ add 2 ++ add 3 ++ "/go")
  waitUpTo (timeLimit * 2) lph
  forM_ ((lin, lph) : nodes) $ \(h, ph) -> do
    _ <- try (hClose h) :: IO (Either SomeException ())
    terminateProcess ph
  threadDelay 1000000
  let result = dir </> "n0" </> "RESULT.txt"
  exists <- doesFileExist result
  if exists then (not . null) <$> readFile result else return False
