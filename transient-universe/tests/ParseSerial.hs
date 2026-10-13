{-# LANGUAGE OverloadedStrings #-}
-- The applicative in Serial mode (parsing): a parser made with <*> over a string, over a stream whose chunks cut
-- the numbers in the middle, and over a stream whose chunks arrive from other threads. No server, no log:
-- the applicative must keep the values in order and run each term once.
--
--   parseserial                  the synchronous cases: "PASS <case>" or "FAIL <case>" for each one
--   parseserial async-new        chunks that arrive from another thread, with the applicative of today
--   parseserial async-old        the same with a copy of the applicative before the log (control)
--   parseserial async-bytes      the same, byte by byte, four terms
--
-- The asynchronous cases give NO RESULT with both applicatives: in Serial mode, when the first term is pending the
-- applicative does not run the second one (the rule of xparallel), so a parser can not be fed from another thread.
-- The HTTP and console parsers read their input with blocking reads, which are synchronous terms.
module Main where

import Transient.Base
import Transient.Internals
import Transient.Parse
import Control.Applicative
import Control.Monad
import Control.Concurrent
import Control.Monad.IO.Class (liftIO)
import Data.IORef
import System.IO.Unsafe (unsafePerformIO)
import System.Environment (getArgs)
import Control.Monad.State (gets, modify)
import qualified Data.ByteString.Lazy.Char8 as BS

-- the applicative of TransIO as it was before the log (a copy), to compare
apOld :: TransIO (a -> b) -> TransIO a -> TransIO b
apOld mf mx = do
    isapp <- gets isApplicative
    modify $ \s -> s{isApplicative= True}
    r1 <- liftIO $ newIORef Nothing
    r2 <- liftIO $ newIORef Nothing
    let restoreflag= modify $ \s -> s{isApplicative= isapp}
    r <- (fparallel r1 r2 <|> xparallel r1 r2) <|> (restoreflag >> empty)
    restoreflag
    return r
  where
  fparallel r1 r2= do
      f <- mf
      liftIO $ writeIORef r1 (Just f)
      mr <- liftIO (readIORef r2)
      case mr of
            Nothing -> empty
            Just x  -> return $ f x
  xparallel r1 r2 = do
      mr <- liftIO (readIORef r1)
      case mr of
            Nothing -> do
              p <- gets execMode
              if p== Serial then empty else do
                       x <- mx
                       liftIO (writeIORef r2 $ Just x)
                       mr <- liftIO (readIORef r1)
                       case mr of
                         Nothing -> empty
                         Just f  -> return $ f x
            Just f -> do
              x <- mx
              liftIO $ writeIORef r2 (Just x)
              return $ f x

numbersOld :: TransIO (Int, Int, Int)
numbersOld = ((,,) `fmap` int) `apOld` (tChar ',' >> int) `apOld` (tChar ',' >> int)

numbers :: TransIO (Int, Int, Int)
numbers = (,,) <$> int <*> (tChar ',' >> int) <*> (tChar ',' >> int)

nested :: TransIO (Int, (Int, Int))                  -- the applicative nested on the right
nested = (,) <$> int <*> ((,) <$> (tChar ',' >> int) <*> (tChar ',' >> int))

four :: TransIO [Int]
four = (\a b c d -> [a, b, c, d]) <$> int <*> (tChar ',' >> int) <*> (tChar ',' >> int) <*> (tChar ',' >> int)

-- the chunks are taken one by one by a blocking action
chunksSync :: [BS.ByteString] -> IO (TransIO (StreamData BS.ByteString))
chunksSync cs = do
  r <- newIORef cs
  return $ liftIO $ atomicModifyIORef r $ \l -> case l of
                                                   []     -> ([], SDone)
                                                   (x:xs) -> (xs, SMore x)

-- the chunks arrive from another thread, after a delay
chunksAsync :: Int -> [BS.ByteString] -> IO (TransIO (StreamData BS.ByteString))
chunksAsync us cs = do
  r <- newIORef cs
  return $ async $ do threadDelay us
                      atomicModifyIORef r $ \l -> case l of
                                                    []     -> ([], SDone)
                                                    (x:xs) -> (xs, SMore x)

{-# NOINLINE got #-}
got :: IORef Bool
got = unsafePerformIO (newIORef False)

check :: (Eq a, Show a) => String -> a -> TransIO a -> TransIO ()
check name expected p = do
  r <- p
  liftIO $ writeIORef got True
  liftIO $ putStrLn $ (if r == expected then "PASS " else "FAIL ") ++ name ++ (if r == expected then "" else ": got " ++ show r)

main :: IO ()
main = do
  args <- getArgs
  _ <- keep' $ case args of
    ["async-new"] -> do s <- liftIO $ chunksAsync 20000 ["1", "2,3", "4,5", "6"]
                        check "stream, asynchronous chunks" (12, 34, 56) $ do setParseStream s; numbers
    ["async-old"] -> do s <- liftIO $ chunksAsync 20000 ["1", "2,3", "4,5", "6"]
                        check "OLD applicative, asynchronous chunks" (12, 34, 56) $ do setParseStream s; numbersOld
    ["async-bytes"] -> do s <- liftIO $ chunksAsync 5000 (map BS.singleton "1,22,333,4444")
                          check "stream, asynchronous, byte by byte, four terms" [1, 22, 333, 4444] $ do setParseStream s; four
    _ -> do
      check "string, three terms"  (12, 34, 56)            $ withParseString "12,34,56" numbers
      check "string, nested right" (12, (34, 56))          $ withParseString "12,34,56" nested
      check "string, four terms"   [1, 22, 333, 4444]      $ withParseString "1,22,333,4444" four
      check "string, two parsers in sequence" ((1, 2, 3), (4, 5, 6)) $
            withParseString "1,2,3 4,5,6" $ do a <- numbers; tChar ' '; b <- numbers; return (a, b)
      s1 <- liftIO $ chunksSync ["1", "2,3", "4,5", "6"]                 -- cuts "12" and "34" and "56"
      check "stream, chunks cut the numbers" (12, 34, 56) $ do setParseStream s1; numbers
      s2 <- liftIO $ chunksSync (map BS.singleton "12,34,56")             -- one byte per chunk
      check "stream, one byte per chunk" (12, 34, 56) $ do setParseStream s2; numbers
      liftIO $ putStrLn "PARSE TESTS END"
  ok <- readIORef got
  when (not ok) $ putStrLn $ "NO RESULT (" ++ unwords args ++ ")"
