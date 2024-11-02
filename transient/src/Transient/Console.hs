{-# LANGUAGE ScopedTypeVariables,CPP, GeneralizedNewtypeDeriving,DeriveGeneric #-}





module Transient.Console(keep, keep',keepCollect,option, option1, input, input', input1, inputf, inputNav,Navigation(..), inputfm, inputParse, processLine,delConsoleAction,rprompt,rcb,thereIsArgPath) where

import Control.Applicative
import Control.Concurrent
import Control.Exception hiding (onException,try)
import Control.Monad
import Control.Monad.IO.Class
import qualified Data.ByteString.Char8 as BS
import qualified Data.ByteString.Lazy.Char8 as BSL
import Data.ByteString.Builder

import Data.IORef
import Data.List
import Data.Maybe
import Data.Typeable
import System.Environment
import System.IO
import Transient.Internals
import Transient.Parse
import Transient.Loggable
import System.IO.Error
import System.IO.Unsafe
import Data.String
import qualified Data.Vector as V
import qualified Data.Map as M

import qualified Data.TCache.DefaultPersistence as TC
import qualified Data.TCache.Defs  as TC
import Data.TCache  hiding (onNothing)

-- import Data.Aeson
-- import GHC.Generics
import Control.Monad.State
import System.Directory
import Unsafe.Coerce
import qualified Data.Vector as V



-- * Non-blocking keyboard input for multiple threads

-- | listen stdin and triggers a new task every time the input data
-- matches the first parameter.  The value contained by the task is the matched
-- value i.e. the first argument itself. The second parameter is a message for
-- the user. The label is displayed in the console when the option match.
--
-- console operations works in multithreaded programs. If two threads invoque two different console operations, both threads stop and the
-- corresponding menu options appears in the console. If two threads invoque the same menu option, both stop at the option
-- and collapse. no two options with the same key are presented, but one.
-- 
-- As always, options can be composed with alternative operators and others

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
optionf remove ret message = do
  let sret = if typeOf ret == typeOf "" then unsafeCoerce ret else show ret
  let msg = "Enter  " ++ "\x1b[1;31m" ++ sret ++ "\x1b[0m" ++ "\t\tto: " ++ message ++ "\n"
  inputf remove sret msg Nothing (== sret)
  liftIO $ putStr "\noption: " >> putStrLn sret
  -- abduce
  return ret

-- a new option/input has been added. should be applied to the line if none has parsed the last fragment
newInput= unsafePerformIO $ newIORef False
-- | General asynchronous console input.
--
-- inputf <remove> <input listener after sucessful or not> <listener identifier> <prompt>
--      <Maybe default value> <validation proc>
-- when ident== "input", if there is a default value and the input do not match, the default value is returned and the input is processed by the active  options . if there is no default value (Nothing) the input string is deleted and prompts for a new input. There is at most one single active input. The next active input in an alternative composition disables the previous.
inputf ::  (Loggable a, Typeable a) => Bool -> String -> String -> Maybe a -> (a -> Bool) -> TransIO a
inputf remove ident message mv cond = do
   er <- inputfm remove ident message mv cond 
   case er of
    Right r -> return r
    _ ->  empty 


-- | general asynchronous console input with control key events. It returns ANSI escape controls as: Left <control code>
-- when ident== "input", if there is a default value and the input do not match, the default value is returned and the input is processed by the active  options. if there is no default value (Nothing) the input string is deleted and prompts for a new input. There is at most one single active statement with ident== "input". The next active input in an alternative composition disables the previous.
--
-- No se puede hacer nada sin amor, excepto destruir. Y Cristo es el amor. "Sin mi no podéis hacer nada" Jn 15:5
inputfm :: (Loggable a, Typeable a) => Bool -> String -> String -> Maybe a -> (a -> Bool) -> TransIO (Either String a)
inputfm remove ident message mv cond = do
  liftIO $ do putStr message; hFlush stdout
  when (isJust mv) $ do
     liftIO $ writeIORef rdefault $ BSL.unpack $ toLazyByteString $ serialize (fromJust mv)
  -- let ide = BS.pack ident
  -- removeState ide
  -- labelState ide
  liftIO $ writeIORef newInput True
  str <- react (addConsoleAction ident message) (return ())
  case str of
    '\ESC':_ -> do
        liftIO $ do
          writeIORef rdefault ""
          writeIORef rconsumed $ Just ""
        
        return $ Left str -- control character. Señor, si tus planes no son los míos, destruyelos
    otherwise -> do
      cont <- getCont 
      let removeIt= do 
            liftIO $ delConsoleAction ident
            liftIO $ atomicModifyIORef (labelth cont) $ \(_,label) -> ((Dead,label),())
            return()

      when (remove && ident /= "input") removeIt


      c <- liftIO $ readIORef rconsumed
      let 
        returnm (Just x) = do
          liftIO $ writeIORef rdefault ""
          when (ident == "input")  removeIt
          return $ Right x
        returnm _ = empty

      if isJust c || str== " " -- lo ha consumido otro  
                  -- o la linea esta vacia
        then do
          liftIO $do
             writeIORef rconsumed $ Just $ dropspaces str
             writeIORef rdefault ""
          returnm mv
        else do
          -- let res = read2 str
          -- use seriañize/deserialize instead of Read/Show.  El que ama a Dios, guarda su palabra. Conviertete y conoce la paz y el amor de Dios.
          res <- withParseString (BSL.pack str) $ 
                  (Just <$> ((,) <$> deserialize <*> giveParseString)) <|> return Nothing
          case res of
            Nothing -> 
              -- if (ident=="input")  -- retry. "Venid a Mi los cansados y abatidos y yo os aliviaré, porque mi yugo es llevadero y mi cargal ligera"
              --   then do liftIO $ writeIORef rconsumed $ Nothing ; inputfm remove ident message mv cond
                -- else do 
                  
                    case mv of
                      Nothing -> do
                         when (ident == "input") $ do
                            liftIO $ do 
                              putStrLn $ "Must be of type " ++ show (typeOf (fromJust mv))
                              putStr message; hFlush stdout
                            liftIO $ writeIORef rconsumed  $ Just ""
                            
                         empty

                      otherwise ->  do
                         liftIO $ putChar '\n'; returnm mv

            Just (x, rest) ->
              if cond x
                then do
                  when (ident == "input")  removeIt

                  liftIO $ do
                    writeIORef rdefault ""
                    writeIORef rconsumed $ Just $ dropspaces $ BSL.unpack rest
                    echo <- readIORef recho
                    when echo $ do putStr ": "; BSL.putStrLn $ toLazyByteString $ serialize x

                    when remove $ do 
                        -- remove the react task this also remove the remaining option1 composed with this one
                        -- Alabado sea Jesucristo
                        par <- readIORef $ parent cont
                        when (isJust par) $ do liftIO $ free (threadId cont) $ fromJust par; return()
                        return()

                  -- print x
                  -- hFlush stdout
                  return $ Right x
                else do
                  if (ident == "input") 
                    then
                      liftIO $ do
                         echo <- readIORef recho
                         when echo $ do putStr " : "; BSL.putStrLn $ toLazyByteString $ serialize x
                         putStrLn $"value of type " ++ show(typeOf $ fromJust mv) ++ " failed validation"
                         

                         putStr message; 
                         hFlush stdout
                         writeIORef rconsumed  $ Just ""
                         return $ Left ""
                    else do
                      liftIO $ when (isJust mv) $  putStrLn ""
                      returnm mv
  
separators = "/:\t\n; "
dropspaces s = dropWhile (\x -> elem x separators) s


-- | Waits on stdin and return a value when a console input matches the
-- predicate specified in the first argument.  The second parameter is a string
-- to be displayed on the console before waiting.
-- if the input do not match, the input string is deleted and prompts for a new input. There is at most one single active input. The next active input in an alternative composition disables the previous.
input :: (Typeable a, Loggable a) => (a -> Bool) -> String -> TransIO a
input = input' Nothing

-- | `input` with a default value
--    if the input do not match, the input string is deleted and prompts for a new input. There is at most one single active input. The next active input in an alternative composition disables the previous.
input' :: (Typeable a, Loggable a) => Maybe a -> (a -> Bool) -> String -> TransIO a
input' mv cond prompt = inputf True "input" prompt mv cond

-- | `input` with a default value which waits once for a value. if it is not valid, the default value is returned. There is at most one single active input. The next active input in an alternative composition disables the previous.
input1  mv cond prompt = inputf True "input1" prompt mv cond

newtype NavBack= NavBack Bool

newtype NavResps  =  NavResps  (M.Map String String) deriving (Read,Show, Typeable) --(Generic,ToJSON,FromJSON,Typeable)

instance TC.Indexable NavResps where
  key _= "NavResps"
  defPath= const "conf/"

instance TC.Serializable NavResps  where
    serialize  = BSL.pack . show
    deserialize= read . BSL.unpack

rNavResps= getDBRef "NavResps"

data Navigation= Navigation deriving (Read,Show,Typeable)

-- | input with navigation back so previous inputs can be reedited. they can be navigated back and forth using cursor keys.
-- see https://matrix.to/#/!kThWcanpHQZJuFHvcB:gitter.im/$6qbK3PeVGumDnNbbmnP82Gs-g-5xalwPLM3Ayl2BJOw?via=gitter.im&via=matrix.org&via=matrix.freyachat.eu
inputNav :: (Typeable a, Loggable a) =>
     Maybe a -> (a -> Bool) -> String -> TransIO a
inputNav mv cond prompt= do

  def <- default' prompt `onBack` \Navigation ->  do
          NavBack doit <- getState <|> return (NavBack False)
          -- tr  $ ("doit",doit)
          if(doit == False)  
            then do
              setState $ NavBack True
              backtrack 
            else do 
              forward Navigation
              default' prompt


  inputit def
  where
  default' prompt= do
              NavResps resps <- liftIO $ atomically (readDBRef rNavResps) `onNothing` return (NavResps M.empty) 
              if M.null resps then return mv else do
                let s = M.lookup prompt resps
                if isJust s 
                  then do
                    r<- withParseString  (BSL.pack $ fromJust s) deserialize
                    return $ Just r
                  else return mv

  inputit def= do
     r <- inputfm True "input"  prompt def cond
     case r of
      Left "\ESC[A" -> do liftIO $ putChar '\n';setState $ NavBack False; back Navigation
      Left ('\ESC':_) -> empty
      Right r -> do
        let str = BSL.unpack $ toLazyByteString $ serialize r  

        -- modifyState' (\(NavResps map) -> (NavResps $ M.insert prompt str map )) $ NavResps (M.singleton prompt str)
        liftIO $ withResource (NavResps M.empty) $ \nr -> case nr of
                      Nothing -> NavResps $ M.singleton prompt str
                      Just (NavResps map) -> NavResps $ M.insert prompt str map
        return r

rcb = unsafePerformIO $ newIORef [] :: IORef [(String, String, String -> IO ())]

addConsoleAction :: String -> String -> (String -> IO ()) -> IO ()
addConsoleAction name message cb = atomicModifyIORef rcb $ \cbs ->
  ((name, message, cb) : filter ((/=) name . fst) cbs, ())
  where
    fst (x, _, _) = x

-- To deactivate a option*, input* with that key
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

rprompt = unsafePerformIO $ newIORef " > "

inputLoop =
  do
    prompt <- readIORef rprompt
    when (not $ null prompt) $ do putStr prompt; hFlush stdout
    line' <- getLineNoBuffering
    let line =if null line' then " " else line' -- to trigger react with something

    processLine  line

    inputLoop
    `catch` \(SomeException _) -> inputLoop -- myThreadId >>= killThread


{-# NOINLINE rdefault #-}
rdefault= unsafePerformIO $ newIORef ""

getLineNoBuffering= do
  hSetBuffering stdin NoBuffering
  hSetBuffering stdout NoBuffering
  hSetEcho stdin False
  content <- liftIO $ readIORef rdefault
  liftIO $ putStr content
  line <- newIORef $ V.fromList content
  index <- newIORef $ length content

  
  let loop= do
        c <- getChar
        case c of
          '\n'    -> do
                putChar '\n'
                hSetBuffering stdin LineBuffering
                hSetBuffering stdout LineBuffering
                hSetEcho stdin True

                readIORef line >>= return . V.toList
          '\ESC'  -> do
                c1 <- getChar
                c2 <- getChar
                if (c1== '[') 
                  then case c2 of
                    'A' -> do 
                              hSetBuffering stdin LineBuffering
                              hSetBuffering stdout LineBuffering 
                              hSetEcho stdin True
                              return "\ESC[A"
                    'D' -> do 
                              i <- readIORef index
                              when(i>0)$ putChar '\b'
                              writeIORef index $ if i> 0 then i - 1 else i
                              loop 
                    'C' -> do 
                              i <-readIORef index
                              l <- readIORef line
                              when (i < V.length l) $ 
                                putStr "\ESC[1C";modifyIORef index (+1); 
                            
                              -- return "\ESC[C"
                              loop
                    'B' -> do -- return "\ESC[B"
                              putChar '\n'
                              hSetBuffering stdin LineBuffering
                              hSetBuffering stdout LineBuffering
                              hSetEcho stdin True

                              readIORef line >>= return . V.toList
                  else return $ "\ESC["++ [c2]
                

          '\DEL' -> do 
                  putChar '\b'
                  putStr "\ESC[0K"
                  l <- readIORef line
                  i <- readIORef index

                  let len = V.length l
                  when (len==0) $  putStr "\ESC[1C"
                  let slice2= if i <= len then V.slice (i) (len -i) l   else V.empty
                  putStr $ V.toList slice2
                  when (len > i) $ putStr $ "\ESC[" ++ show (len - i) ++"D" 
                  when (i > 0) $ writeIORef index (i - 1)
                  
                  writeIORef line $  (if i > 0 then V.slice 0 (i-1) l else V.empty)  <>  slice2
                  
                  loop
          otherwise -> do
              v <- readIORef line
              let l = V.length v
              i <- readIORef index 
              writeIORef index (i+1)
              if i >= l then  writeIORef line $ V.snoc v c else 
                writeIORef line $
                  let idx = V.fromList[i+1..l]
                      vhole = V.snoc v ' '
                      lenv = V.length v
                      v'= if (lenv > 0) then V.update_ vhole idx $ V.slice i (lenv -i) v else v
                  in  V.unsafeUpd v' [(i,c)]
              when (i < l) $  do putStr "\ESC[4h"

              putChar c
              loop
  loop

{-# NOINLINE rconsumed #-}

-- Remaining line not parsed yet. Nothing -> no parser has consumed any fragment yet. Just -> a parser has consumed a fragment
rconsumed :: IORef (Maybe String)
rconsumed = unsafePerformIO $ newIORef Nothing



-- | execute a set of console commands separated by '/', ':' or space that are consumed by the console input primitives
processLine line' = liftIO $ do
  let line= subst line'
  -- tr ("subst",line)
  
  mbs <- readIORef rcb
  process  mbs line
  writeIORef recho False
  where
    process ::  [(String, String, String -> IO ())] -> String -> IO ()
    process  _ [] = writeIORef rconsumed Nothing >> return ()

    process  [] line = do
      threadDelay 100000
      r <- readIORef newInput
      if r then do
              writeIORef newInput False
              mbs <- readIORef rcb
              process  mbs line
           else do
              let (r, rest) = span (\x -> (not $ elem x "/:; ")) line
              when ( rest /= " " && not (null r)) $ hPutStr stderr  r >> hPutStrLn stderr ": can't read, skip"
              mbs <- readIORef rcb
              writeIORef rconsumed Nothing
              process  mbs $ dropspaces rest

    process  mbs line = do
      let cb = trd $ head mbs
      cb line

      r <- atomicModifyIORef' rconsumed $ \res -> (Nothing, res)
      let restLine = fromMaybe line r
      --si se ha consumido leer la lista de callbacks otra vez
      mbs' <- if isJust r then readIORef rcb else return $ tail mbs
      process  mbs' restLine
      where
        trd (_, _, x) = x



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
            liftIO $ appendFile logFile $ show e ++ "\n" -- `catch` \(e:: IOError) -> exc

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
              let filteryn x = x == "y" || x == "n" || x == "Y" || x  == "N"
              prefix <- input' (Just "") (not . filteryn) "command prefix? (default none) "
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

            <|> do
              option "savepol" "configure synchronization policy with permanent storage"
              maxnum <- input' (Just 1000) (const True) "max number of cached objects? (default 1000)"
              time <- input' (Just 10) (const True) "time between check for objects to be saved? (default 10 sec)"
              liftIO $ clearSyncCacheProc time defaultCheck maxnum
              liftIO $ delConsoleAction "savepol"
              liftIO $ do
                  putStr "syncing each "
                  print time
                  putStr "seconds."
                  putStr " Max objects: "
                  print maxnum
                  putStrLn ""

              empty

            <|> do
    
              option "save" "commit now the current execution state to permanent storage"
              abduce
              liftIO $ syncCache
              liftIO $ putStrLn "saved the execution state"
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
              liftIO $ threadDelay 10000000
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
-- Useful for debugging or for creating background tasks,
-- as well as to embed the Transient monad inside another computation.
-- It returns the list of results produced by all the threads when all the threads have finished
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

-- echo of the input when processing a command line
{-# NOINLINE recho #-}
recho= unsafePerformIO $ newIORef False
execCommandLine :: IO ()
execCommandLine = do
      path <- thereIsArgPath
      --print $ drop (i-1) args
      --putStr "Executing: " >> print  path
      threadDelay 10000
      processLine    path

-- substitute one of more separators by a single '/'
subst   s= subst1 s
            where
            subst2 []=[]
            subst2  (h:t)
                  | h== '\"' = let (s,r)= span (/= '\"') t in h : s ++  h: subst1 (tail r)
                  | elem h separators = subst2 t        -- eliminate repeated spaces/separators
                  | otherwise = h:subst1 t
            subst1 []=[]
            subst1  (h:t)
                  | h== '\"' = let (s,r)= span (/= '\"') t in h : s ++  h: subst1 (tail r)
                  | elem h separators = (whyNot $ recho =: True) `seq` '/':subst2 t
                  | otherwise= h: subst1 t

(=:) ioref val= writeIORef ioref val
whyNot= unsafePerformIO

thereIsArgPath=  do
  args <- getArgs
  let mindex = findIndex (\o -> o == "-p" || o == "--path") args
  if (isNothing mindex) then return [] else do
    let i = fromJust mindex + 1
    return $ if (length args >= i) then   args !! i else []

-- | write a message and parse a complete line from the console. The parser is constructed with 'Transient.Parse' primitives
inputParse :: (Typeable b) => TransIO b -> String -> TransIO b
inputParse parse message = r
  where
    r = do
      liftIO $ putStr (message ++ ": " ) >> hFlush stdout
      str <- react (addConsoleAction message message) (return ())
      liftIO $ delConsoleAction message

      -- let (str',rest)= span (/= '/') str

      -- liftIO $ putStrLn str
      liftIO $ print str
      (r, rest) <- withParseString (BSL.pack str) $ (,) <$> parse <*> giveParseString
      tr ("REST",rest)
      liftIO $ do writeIORef rconsumed $ Just  $ BSL.unpack rest
      return r

 
