{-# LANGUAGE ScopedTypeVariables,CPP #-}


module Transient.Console(keep, keep',keepCollect,option, option1, input, input', inputf, inputParse, processLine,rprompt,rcb) where

import Control.Applicative
import Control.Concurrent
import Control.Exception hiding (onException)
import Control.Monad
import Control.Monad.IO.Class
import qualified Data.ByteString.Char8 as BS
import qualified Data.ByteString.Lazy.Char8 as BSL
import Data.IORef
import Data.List
import Data.Maybe
import Data.Typeable
import System.Environment
import System.IO
import Transient.Internals
import Transient.Parse
import System.IO.Error
import System.IO.Unsafe
import Data.String
import Control.Monad.State
import System.Directory
import Unsafe.Coerce
-- * Non-blocking keyboard input

-- getLineRef= unsafePerformIO $ newTVarIO Nothing

-- | listen stdin and triggers a new task every time the input data
-- matches the first parameter.  The value contained by the task is the matched
-- value i.e. the first argument itself. The second parameter is a message for
-- the user. The label is displayed in the console when the option match.
option ::
  (Typeable b, Show b, Read b, Eq b) =>
  b ->
  String ->
  TransIO b
option = optionf False

-- Implements the same functionality than `option` but only wait for one input
option1 ::
  (Typeable b, Show b, Read b, Eq b) =>
  b ->
  String ->
  TransIO b
option1 = optionf True

optionf ::
  (Typeable b, Show b, Read b, Eq b) =>
  Bool ->
  b ->
  String ->
  TransIO b
optionf flag ret message = do
  let sret = if typeOf ret == typeOf "" then unsafeCoerce ret else show ret
  let msg = "Enter  " ++ sret ++ "\t\tto: " ++ message ++ "\n"
  inputf flag sret msg Nothing (== sret)
  liftIO $ putStr "\noption: " >> putStrLn sret
  -- abduce
  return ret

-- | General asynchronous console input.
--
-- inputf <remove input listener after sucessful or not> <listener identifier> <prompt>
--      <Maybe default value> <validation proc>
inputf :: (Show a, Read a, Typeable a) => Bool -> String -> String -> Maybe a -> (a -> Bool) -> TransIO a
inputf remove ident message mv cond = do
  liftIO $ putStr message >> hFlush stdout
  -- let ide = BS.pack ident
  -- removeState ide
  -- labelState ide

  str <- react (addConsoleAction ident message) (return ())
  -- need to remove previous element in task list

  when remove $ liftIO $ delConsoleAction ident
  c <- liftIO $ readIORef rconsumed
  if isJust c
    then returnm mv
    else do
      let res = read2 str
      case res of
        Nothing -> do liftIO $ when (isJust mv) $ putStrLn ""; returnm mv
        Just (x, rest) ->
          if cond x
            then liftIO $ do
              writeIORef rconsumed $ Just $ dropspaces rest
              when remove $ print x
              -- print x
              -- hFlush stdout
              return x
            else do
              liftIO $ when (isJust mv) $ putStrLn ""
              returnm mv
  where
    returnm (Just x) = return x
    returnm _ = empty

    read2 :: (Typeable a, Read a) => String -> Maybe (a, String)
    read2 s = r
      where
        typ :: Maybe (a, String) -> a
        typ = undefined
        typr = typeOf (typ r)
        r
          | typr == typeOf "" = let (r1, rest) = span (\x -> (not $ elem x separators)) s in Just (unsafeCoerce r1, dropspaces rest)
          | typr == typeOf (BS.pack "") = let (r1, rest) = span (\x -> (not $ elem x separators)) s in Just (unsafeCoerce $ BS.pack r1, dropspaces rest)
          | typr == typeOf (BSL.pack "") = let (r1, rest) = span (\x -> (not $ elem x separators)) s in Just (unsafeCoerce $ BSL.pack r1, dropspaces rest)
          | otherwise = case reads s of
            [(x, rest)] -> Just (x, dropspaces rest)
            _ -> Nothing

dropspaces s = dropWhile (\x -> elem x separators) s

separators = "/:\t\n "

-- | Waits on stdin and return a value when a console input matches the
-- predicate specified in the first argument.  The second parameter is a string
-- to be displayed on the console before waiting.
input :: (Typeable a, Read a, Show a) => (a -> Bool) -> String -> TransIO a
input = input' Nothing

-- | `input` with a default value
input' :: (Typeable a, Read a, Show a) => Maybe a -> (a -> Bool) -> String -> TransIO a
input' mv cond prompt = do
  --liftIO $ putStr prompt >> hFlush stdout
  inputf True "input" prompt mv cond

rcb = unsafePerformIO $ newIORef [] :: IORef [(String, String, String -> IO ())]

addConsoleAction :: String -> String -> (String -> IO ()) -> IO ()
addConsoleAction name message cb = atomicModifyIORef rcb $ \cbs ->
  ((name, message, cb) : filter ((/=) name . fst) cbs, ())
  where
    fst (x, _, _) = x

delConsoleAction :: String -> IO ()
delConsoleAction name = atomicModifyIORef rcb $ \cbs -> (filter ((/=) name . fst) cbs, ())
  where
    fst (x, _, _) = x

reads1 s = x
  where
    x = if typeOf (typeOfr x) == typeOf "" then unsafeCoerce [(s, "")] else readsPrec' 0 s
    typeOfr :: [(a, String)] -> a
    typeOfr = undefined

read1 s = let [(x, "")] = reads1 s in x

rprompt = unsafePerformIO $ newIORef "> "

inputLoop =
  do
    prompt <- readIORef rprompt
    when (not $ null prompt) $ do putStr prompt; hFlush stdout
    line <- getLine
    --threadDelay 1000000

    processLine line

    inputLoop
    `catch` \(SomeException _) -> inputLoop -- myThreadId >>= killThread

{-# NOINLINE rconsumed #-}
rconsumed :: IORef (Maybe String)
rconsumed = unsafePerformIO $ newIORef Nothing


-- | execute a set of console commands separated by '/', ':' or space that are consumed by the console input primitives
processLine line = liftIO $ do
  tr ("LINE",line)
  mbs <- readIORef rcb
  process 5 mbs line
  where
    process :: Int -> [(String, String, String -> IO ())] -> String -> IO ()
    process _ _ [] = writeIORef rconsumed Nothing >> return ()
    process 0 [] line = do
      let (r, rest) = span (\x -> (not $ elem x "/: ")) line
      hPutStr stderr r >> hPutStrLn stderr ": can't read, skip"
      mbs <- readIORef rcb
      writeIORef rconsumed Nothing
      process 5 mbs $ dropspaces rest

    process n [] line = do
      mbs <- readIORef rcb
      process (n -1) mbs line

    process n mbs line = do
      let cb = trd $ head mbs
      cb line

      r <- atomicModifyIORef' rconsumed $ \res -> (Nothing, res)
      let restLine = fromMaybe line r
      --si se ha consumido leer la lista de callbacks otra vez
      mbs' <- if isJust r then readIORef rcb else return $ tail mbs
      process n mbs' restLine
      where
        trd (_, _, x) = x

{-
processLine r = do
    linepro <- readIORef lineprocessmode
    if linepro then do
            mapM' invokeParsers [r]
       else do
            let rs = breakSlash [] r
            mapM' invokeParsers rs

    where
    invokeParsers x= do
       mbs <- readIORef rcb
       mapM_ (\cb -> cb x) $ map (\(_,_,p)-> p) mbs

    mapM' _ []= return ()
    mapM' f (xss@(x:xs)) =do
        f x
        r <- readIORef rconsumed

        if  r
          then do
            writeIORef riterloop 0
            writeIORef rconsumed False
            mapM' f xs

          else do
            threadDelay 1000
            n <- atomicModifyIORef riterloop $ \n -> (n+1,n)
            if n==1
              then do
                when (not $ null x) $ hPutStr  stderr x >> hPutStrLn stderr ": can't read, skip"
                writeIORef riterloop 0
                writeIORef rconsumed False
                mapM' f xs
              else mapM' f xss

    riterloop= unsafePerformIO $ newIORef 0

breakSlash :: [String] -> String -> [String]
breakSlash [] ""= [""]
breakSlash s ""= s
breakSlash res ('\"':s)=
    let (r,rest) = span(/= '\"') s
    in breakSlash (res++[r]) $ tail1 rest

breakSlash res s=
    let (r,rest) = span(\x -> (not $ elem x "/: ")) s
    in breakSlash (res++[r]) $ tail1 rest

tail1 []= []
tail1 x= tail x

-- >>> breakSlash [] "test.hs/0/\"-prof -auto\""
-- ["test.hs","0","-prof -auto"]
--

-}

-- | Wait for the execution of `exit` and return the result or the exhaustion of thread activity
stay rexit =
  takeMVar rexit
    `catch` \(e :: BlockedIndefinitelyOnMVar) -> return Nothing

-- | Runs the transient computation in a child thread and keeps the main thread
-- running until all the user threads exit or some thread `exit`.
--
-- The main thread provides facilities for interpreting keyboard input in a
-- non-blocking but line-oriented manner. The program reads the standard input
-- and feeds it to all the async input consumers (e.g. 'option' and 'input').
-- All async input consumers contend for each line entered on the standard
-- input and try to read it atomically. When a consumer consumes the input
-- it disspears from the buffer, otherwise it is left in the buffer for others
-- to consume. If nobody consumes the input, it is discarded.
--
-- A @/@ in the input line is treated as a newline.
--
-- When using asynchronous input, regular synchronous IO APIs like getLine
-- cannot be used as they will contend for the standard input along with the
-- asynchronous input thread. Instead you can use the asynchronous input APIs
-- provided by transient.
--
-- A built-in interactive command handler also reads the stdin asynchronously.
-- All available options waiting for input are displayed when the
-- program is run.  The following commands are available:
--
-- entering @options y@ show the available options
----
-- The program's command line is scanned for @-p@ or @--path@ command line
-- options.  The arguments to these options are injected into the async input
-- channel as keyboard input to the program. Each line of input is separated by
-- a @/@. For example:
--
-- >  foo  -p  ps/end

keep :: Typeable a => TransIO a -> IO (Maybe a)
keep mx = do
  liftIO $ hSetBuffering stdout LineBuffering
  rexit <- newEmptyMVar
  void $
    forkIO $ do
      --       liftIO $ putMVar rexit  $ Right Nothing
      let logFile = "trans.log"

      void $
        runTransient $ do
          liftIO $ removeFile logFile `catch` \(e :: IOError) -> return ()

          onException $ \(e :: SomeException) -> do
            case fromException e of
              Just BlockedIndefinitelyOnSTM -> return ()
              _ -> do
                liftIO $ do
                  th <- myThreadId
                  putStrLn $ show th ++ ": " ++ show e
                back $ Finish $ show (unsafePerformIO myThreadId, e)
          --showThreads top`
          --liftIO $ appendFile logFile $ show e ++ "\n" -- `catch` \(e:: IOError) -> exc

          onException $ \(e :: IOException) -> do
            when (ioeGetErrorString e == "resource busy") $ do
              liftIO $ do print e; putStrLn "EXITING!!!"; putMVar rexit Nothing
              empty

          onException $ \ThreadKilled -> do
            back $ Finish $ show (unsafePerformIO myThreadId, ThreadKilled)
            empty

          --  onException $ \(Finish _) -> empty

          st <- get
          setData $ Exit rexit

          do
            --  do abduce ; mx -- ; back $ Finish $ show $ (unsafePerformIO myThreadId,"main thread ended")
            --  <|>
            do
              option "options" "show all options"
              mbs <- liftIO $ readIORef rcb
              let filteryn x = x == "y" || x == "n" || x == "Y" || x == "N"
              prefix <- input' (Just "") (not . filteryn) "prefix? " 
              liftIO $ mapM_ (\c -> when (prefix `isPrefixOf` c) $ do putStr c; putStr "|") $ map (\(fst, _, _) -> fst) mbs

              d <- input' (Just "n") filteryn "\nDetails? N/y "
              when (d == "y" || d =="Y") $
                let line (x, y, _) = when (prefix `isPrefixOf` x) $ putStr y -- do putStr x; putStr "\t\t"; putStrLn y
                 in liftIO $ mapM_ line mbs
              liftIO $ putStrLn ""
              empty
            <|> do
              option "ps" "show threads"
              liftIO $ showThreads st
              empty
            <|> do
              option "errs" "show exceptions log"
              c <- liftIO $ readFile logFile `catch` \(e :: IOError) -> return ""
              liftIO . putStrLn $ if null c then "no errors logged" else c
              empty
            {-
            <|> do
                   option "log" "inspect the log of a thread"
                   th <- input (const True)  "thread number>"
                   ml <- liftIO $ getStateFromThread th st
                   liftIO $ print $ fmap (\(Log _ _ log _) -> reverse log) ml
                   empty
                   -}

            <|> do
              option "end" "exit"
              liftIO $ putStrLn "exiting..."
              abduce

              st <- threadState $ fromString "input"
              liftIO $ killThread $ threadId st
              --  killChilds
              liftIO $ putMVar rexit Nothing
              top <- topState
              liftIO $ killChildren $ children top
              liftIO $ killThread $ threadId top
              empty
            <|> do
              abduce
              liftIO $ execCommandLine
              labelState (fromString "input")
              liftIO inputLoop
              empty
            <|> do abduce; mx -- back $ Finish $ show (unsafePerformIO myThreadId,"main thread ended")
            -- tr "EXCEPTBACKG"
            -- -- si el error se produce en un thread que no es el principal, no se recoje.
            -- -- back si lo recoje, pero no hace caso de empty.
            -- exceptBackg cont $ Finish $ show (unsafePerformIO myThreadId,"main thread ended")
            -- return ()
  stay rexit

-- | It is the same as `keep` but with no console interaction, although a command line string of commands with the option -p could be passed as parameter to the program.
keep' :: TransIO a -> IO [a]
keep' mx = keepCollect 0 0 $ do
  do
    abduce
    liftIO $ threadDelay 10000
    fork $ liftIO $ execCommandLine
    empty
  <|> mx

-- | gather all the results returned by all the thread. It waits for a certain number of results and for a certain time (0 as first parameter means "all the results", 0 in the second paramenter means "until all thread finish"). It is the same than `collect'` but it returns in the IO monad.
keepCollect :: Int -> Int -> TransIO a0 -> IO [a0]
keepCollect n time mx = do
  hSetBuffering stdout LineBuffering
  rexit <- newEmptyMVar
  void $
    forkIO $
      do
        void $
          runTransient $ do
            onException $ \(e :: SomeException) -> do
              --  top <- topState
              liftIO $ do
                th <- myThreadId
                putStr $ show th
                putStr ": "
                print e
              -- putStrLn "Threads:"
              -- showThreads top
              -- empty
              back $ Finish $ show (unsafePerformIO myThreadId, e)

            onException $ \(e :: IOException) ->
              when (ioeGetErrorString e == "resource busy") $ do
                liftIO $ do print e; putStrLn "EXITING!!!"; putMVar rexit []
                liftIO $ putMVar rexit []
                empty

            onException $ \ThreadKilled -> do
              back $ Finish $ show (unsafePerformIO myThreadId, ThreadKilled)
              liftIO $ putMVar rexit []
              empty

            r <- collect' n time $  mx
            liftIO $ putMVar rexit r
        `catch` \(e :: BlockedIndefinitelyOnMVar) -> putMVar rexit []

  takeMVar rexit `catch` \(e :: BlockedIndefinitelyOnMVar) -> return []

execCommandLine :: IO ()
execCommandLine = do
  args <- getArgs
  let mindex = findIndex (\o -> o == "-p" || o == "--path") args
  when (isJust mindex) $ do
    let i = fromJust mindex + 1
    when (length args >= i) $ do
      let path = args !! i
      --print $ drop (i-1) args
      --putStr "Executing: " >> print  path
      threadDelay 100000
      processLine path

-- u = undefined

-- | write a message and parse a complete line from the console. The parse is constructed with 'Transient.Parse' primitives
inputParse :: (Typeable b) => TransIO b -> String -> TransIO b
inputParse parse message = r
  where
    r = do
      liftIO $ putStr (message ++ " " ) >> hFlush stdout
      str <- react (addConsoleAction message message) (return ())
      liftIO $ delConsoleAction message

      -- let (str',rest)= span (/= '/') str

      -- liftIO $ putStrLn str
      liftIO $ print str
      (r, rest) <- withParseString (BSL.pack str) $ (,) <$> parse <*> giveParseString
      tr ("REST",rest)
      liftIO $ do writeIORef rconsumed $ Just  $ BSL.unpack rest
      return r

    -- t :: TransIO a -> a
    -- t = u
