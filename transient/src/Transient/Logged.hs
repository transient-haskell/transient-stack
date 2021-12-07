 {-#Language OverloadedStrings, FlexibleContexts #-}
-----------------------------------------------------------------------------
--
-- Module      :  Transient.Logged
-- Copyright   :
-- License     :  MIT
--
-- Maintainer  :  agocorona@gmail.com
-- Stability   :
-- Portability :
--
-- | The 'logged' primitive is used to save the results of the subcomputations
-- of a transient computation (including all its threads) in a log buffer. At
-- any point, a 'suspend' or 'checkpoint' can be used to save the accumulated
-- log on a persistent storage. A 'restore' reads the saved logs and resumes
-- the computation from the saved checkpoint. On resumption, the saved results
-- are used for the computations which have already been performed. The log
-- contains purely application level state, and is therefore independent of the
-- underlying machine architecture. The saved logs can be sent across the wire
-- to another machine and the computation can then be resumed on that machine.
-- We can also save the log to gather diagnostic information.
--
-- The following example illustrates the APIs. In its first run 'suspend' saves
-- the state in a directory named @logs@ and exits, in the second run it
-- resumes from that point and then stops at the 'checkpoint', in the third run
-- it resumes from the checkpoint and then finishes.
--
-- @
-- main= keep $ restore  $ do
--      r <- logged $ choose [1..10 :: Int]
--      logged $ liftIO $ print (\"A",r)
--      suspend ()
--      logged $ liftIO $ print (\"B",r)
--      checkpoint
--      liftIO $ print (\"C",r)
-- @
-----------------------------------------------------------------------------
{-# LANGUAGE  CPP, ExistentialQuantification, FlexibleInstances, ScopedTypeVariables, UndecidableInstances #-}
module Transient.Logged(
Loggable(..), logged, received, param, getLog, exec,wait, emptyLog,

#ifndef ghcjs_HOST_OS
 suspend, checkpoint, rerun, restore,
#endif

Log(..),Recover(..),logs, toPath, toPathLon, getEnd, getLogFromIndex, dropFromIndex,rrecover, (<<),(<<-), LogData(..),LogDataElem(..),  toLazyByteString, byteString, lazyByteString, Raw(..)
) where

import Data.Typeable
import Unsafe.Coerce
import Transient.Internals

import Transient.Indeterminism(choose)
--import Transient.Internals -- (onNothing,reads1,IDynamic(..),Log(..),LE(..),execMode(..),StateIO)
import Transient.Parse
import Control.Applicative
import Control.Monad.State
import System.Directory
import Control.Exception
--import Control.Monad
import qualified Data.ByteString.Lazy.Char8 as BS
import qualified Data.ByteString.Char8 as BSS
import qualified Data.Map as M
import Data.IORef
import System.IO.Unsafe
-- #ifndef ghcjs_HOST_OS
import Data.ByteString.Builder
import System.Random
import Debug.Trace
-- #else
--import Data.JSString hiding (empty)
-- #endif



-- #ifndef ghcjs_HOST_OS
-- pack= BSS.pack

-- #else
{-
newtype Builder= Builder(JSString -> JSString)
instance Monoid Builder where
   mappend (Builder fx) (Builder fy)= Builder $ \next -> fx (fy next)
   mempty= Builder id

instance Semigroup Builder where
    (<>)= mappend

byteString :: JSString -> Builder
byteString ss= Builder $ \s -> ss <> s
lazyByteString = byteString


toLazyByteString :: Builder -> JSString
toLazyByteString (Builder b)=  b  mempty
-}
-- #endif
u= unsafePerformIO
exec=  LD[LX mempty] --byteString "e/"
wait=   byteString "w/"

class (Show a, Read a,Typeable a) => Loggable a where
    serialize :: a -> Builder
    serialize = byteString . BSS.pack . show

    deserializePure :: BS.ByteString -> Maybe(a, BS.ByteString)
    deserializePure s = r
      where
      r= case reads $ BS.unpack s   of -- `traceShow` ("deserialize",typeOf $ typeOf1 r,s) of
           []       -> Nothing  !> "Nothing"
           (r,t): _ -> return (r, BS.pack t)

      typeOf1 :: Maybe(a, BS.ByteString) -> a
      typeOf1= undefined

    deserialize ::  TransIO a
    deserialize = x
       where
       x=  withGetParseString $ \s -> case deserializePure s of
                    Nothing ->   empty
                    Just x -> return x


instance Show Builder where
   show b= show $ toLazyByteString b

instance Read Builder where
   readsPrec n str= -- [(lazyByteString $ read str,"")]
     let [(x,r)] = readsPrec n str
     in [(byteString x,r)]


instance Loggable a => Loggable (StreamData a) where
    serialize (SMore x)= byteString "SMore/" <> serialize x
    serialize (SLast x)= byteString "SLast/" <> serialize x
    serialize SDone= byteString "SDone"
    serialize (SError e)= byteString "SError/" <> serialize e

    deserialize = smore <|> slast <|> sdone <|> serror
     where
     smore = symbol "SMore/" >> (SMore <$> deserialize)
     slast = symbol "SLast/"  >> (SLast <$> deserialize)
     sdone = symbol "SDone"  >> return SDone
     serror= symbol "SError/" >> (SError <$> deserialize)

instance Loggable () -- where
  -- serialize= mempty
  -- deserialize= return()

instance Loggable Bool where 
  serialize b= if b then "t" else "f"
  deserialize = withGetParseString $ \s -> 
     if (BS.head $ BS.tail s) /= '/'   
        then empty 
        else
            let h= BS.head s
                tail=  BS.tail s
            in if h== 't' then return (True,tail)  else if h== 'f' then return (False, tail) else empty 

instance Loggable Int
instance Loggable Integer

instance (Typeable a, Loggable a) => Loggable[a]  
  --  serialize x= if typeOf x== typeOf (undefined :: String) then BS.pack x else BS.pack $ show x
  --  deserialize= let [(s,r)]= 







instance Loggable Char
instance Loggable Float
instance Loggable Double
instance Loggable a => Loggable (Maybe a)
instance (Loggable a,Loggable b) => Loggable (a,b)
instance (Loggable a,Loggable b, Loggable c) => Loggable (a,b,c)
instance (Loggable a,Loggable b, Loggable c,Loggable d) => Loggable (a,b,c,d)
instance (Loggable a,Loggable b, Loggable c,Loggable d,Loggable e) => Loggable (a,b,c,d,e)
instance (Loggable a,Loggable b, Loggable c,Loggable d,Loggable e,Loggable f) => Loggable (a,b,c,d,e,f)
instance (Loggable a,Loggable b, Loggable c,Loggable d,Loggable e,Loggable f,Loggable g) => Loggable (a,b,c,d,e,f,g)
instance (Loggable a,Loggable b, Loggable c,Loggable d,Loggable e,Loggable f,Loggable g,Loggable h) => Loggable (a,b,c,d,e,f,g,h)
instance (Loggable a,Loggable b, Loggable c,Loggable d,Loggable e,Loggable f,Loggable g,Loggable h,Loggable i) => Loggable (a,b,c,d,e,f,g,h,i)


instance (Loggable a, Loggable b) => Loggable (Either a b)
-- #ifdef ghcjs_HOST_OS


-- intDec i= Builder $ \s -> pack (show i) <> s
-- int64Dec i=  Builder $ \s -> pack (show i) <> s

-- #endif
instance (Loggable k, Ord k, Loggable a) => Loggable (M.Map k a)  where
  serialize v= intDec (M.size v) <> M.foldlWithKey' (\s k x ->  s <> "/" <> serialize k <> "/" <> serialize x ) mempty v
  deserialize= do
      len <- int
      list <- replicateM len $
                 (,) <$> (tChar '/' *> deserialize)
                     <*> (tChar '/' *> deserialize)
      return $ M.fromList list

#ifndef ghcjs_HOST_OS
instance Loggable BS.ByteString where
        serialize str =  lazyByteString str
        deserialize= tTakeWhile (/= '/')
#endif

#ifndef ghcjs_HOST_OS
instance Loggable BSS.ByteString where
        serialize str =  byteString str
        deserialize = tTakeWhile (/= '/') >>= return . BS.toStrict
#endif
instance Loggable SomeException

newtype Raw= Raw BS.ByteString deriving (Read,Show)
instance Loggable Raw where
  serialize (Raw str)= lazyByteString str
  deserialize= Raw <$> do
        s <- notParsed
        BS.length s `seq` return s  --force the read till the end 

data Recover= RFalse | RTrue {-  Restore -} deriving (Show,Eq)
rrecover log= let r =recover log in r== RTrue    --   ||  r== Restore

data Log  = Log{ recover :: Recover, fromCont :: Bool, fulLog :: LogData,  hashClosure :: Int} deriving (Show)

data LogDataElem= LE  Builder  | LX LogData {- (Maybe LogData)-} deriving (Read,Show, Typeable)

newtype LogData=  LD [LogDataElem]  deriving (Read,Show, Typeable)

instance Loggable LogData where
  serialize = toPath
  deserializePure s= Just (LD[LE  $ lazyByteString s],mempty)

instance Semigroup LogData where
  (<>)= mappend
instance Monoid LogData where
  mempty= LD mempty
  LD [] `mappend` LD log= LD log
  LD log `mappend` LD log' = 
    case (splitAt (length log -1) log) of
      (_,[LE _]) -> LD $ log ++ log' 
      -- (prev,[LX  (LD[])]) -> LD $ prev ++ [LX ( LD  $ tail log' )]
      (prev,[LX  log'']) -> LD $ prev ++ [LX (log'' <> LD log' )]

      -- (prev,[LX  (LD log'')]) -> LD $ prev ++ [LX ( LD $ log''<> log' )]



-- >>> getEnd $ LD [LX (LD [LX (LD [])])]
-- [0,0]
--

-- >>> getEnd $  LD  [LE $ e "hello/",LX [LE $ e "world/"] ]
-- [1,1]
--

-- >>> getEnd $   [LE $pack "hello/",LX [LE $ pack "world/",LE $ pack"rest/",LE $ pack"rest2/"] ]
-- [3,1]
--


-- >>>  toPath $ LD[LE $ pack "hi/"] <> exec <> exec << pack "world/" <<- pack "hello"
-- hi/e/hello
--

-- >>> toPath $ (LD[] <> exec << wait <<- pack "hello/" ) <> exec << wait <<- pack "world"
-- hello/world
--



-- >>> getEnd $  [LE $pack"hello/",LX [LE $ pack "world/"] ] <<- pack "world2/"
-- [3]
--


-- >>> getEnd                    $ LD [LX (LD [e "f/",e "w/",e "w/",e "h/",e "",e "N0/",LX (LD [LX (LD [LX (LD [e "N2/e/"])])])])]
-- [0,6,0,0,1]
--


-- >>> getLogFromIndex [0,6,0,0,1] $ LD [LX (LD [e "f/",e "w/",e "w/",e "h/",e "",e" N0/",LX (LD [LX (LD [LX (LD [e "N2/e/",e "()/",e "()/",e "()/",LX (LD [LX (LD [LX (LD [])])])])])])])]
-- ()/()/()/e/e/e/
--



e x= LE $ pack x
-- >>> getLogFromIndex  [0] $ LD [LX (LD [e "f/",e "w/",e "w/",e "h/",e "node",e "N0/",LX (LD [LX (LD [LX (LD [])])])])]
-- "e/f/w/w/h/nodeN0/e/e/e/"
--


-- >>> toPathFragment  $ dropFromIndex  [0] $ LD [LX (LD [e "f/",e "w/",e "w/",e "h/",e "node",e "N0/",LX (LD [LX (LD [LX (LD [])])])])]
-- "f/w/w/h/nodeN0/e/e/e/"
--

--

--- >>> dropLast $ LD[e "hello",LX $ LD[e "world2"]]
--- [LE "hello"]
---

--- >>> getLogFromIndex [1,1] $ LD[e "hello",LX $ LD[e "world2", e "1111/"],e "world3",e "WORLD4"]
--- "1111/WORLD4"
---

-- >>> toPathFragment  $ dropFromIndex [1,1] $ LD[e "hello",LX $ LD[e "world2", e "1111/"],e "world3",e "WORLD4"]
-- "1111/WORLD4"
--

-- >>> getLogFromIndex [1] $ LD [e "efw...",LX (LD [e "N4/",LX (LD [LX (LD [LX (LD [])])])])]
-- "e/N4/e/e/e/"

-- >>> toPath $ LD $ dropLast  $ LD [e "efw...",LX (LD [e "N4/",LX (LD [LX (LD [LX (LD [])])])])]
-- "efw..."
--

-- >>> toPath $ LD $ dropFromIndex [1] $ LD [e "efw...",LX (LD [e "N4/",LX (LD [LX (LD [LX (LD [])])])])]
-- "e/N4/e/e/e/"
--


-- >>> getLogFromIndex [0,6,0,0,1] $  LD [LX (LD [e "f/",e "w/",e "w/",e "h/",e "nodes/",e "N0/",LX (LD [LX (LD [LX (LD [e "e/N2/e/e/e/",e "()/",LX (LD [])])])])])]
-- "()/e/"
--

-- >>> LD [e "\"p1\"/",e "HELLO/",e "()/",e "WORLD/",e "()/",LX (LD [e "PRE/",LX (LD [e "PRE1/",e "w/"])])] `substLast`  (pack "POST1")
-- LD [LE "\"p1\"/",LE "HELLO/",LE "()/",LE "WORLD/",LE "()/",LX (LD [LE "PRE/",LX (LD [LE "PRE1/",LE "POST1"])])]
--



-- >>> toPathFragment  $ dropFromIndex [0,6,0,0,1] $  LD [LX (LD [e "f/",e "w/",e "w/",e "h/",e "nodes/",e "N0/",LX (LD [LX (LD [LX (LD [e "e/N2/e/e/e/",e "()/",LX (LD [])])])])])]
-- "()/e/"
--




-- >>> toPath $ LD [LX (LD [LX (LD [e "\"HELLO\"/"]),e "\"HELLO\"/",e "()/",LX (LD [])])]
-- "e/\"HELLO\"/()/e/"




--

getEnd ::  LogData -> [Int]
getEnd  (LD log)= let n= g [0] log in reverse n
  where
  g n []= n

  g  ns ((LX (LD []) ):[]) = 0:ns 

  g  ns ((LX (LD rest) ):[]) = g (0:ns)  rest 
  g  (n:ns) (_:rest) = g (n+1:ns) rest 

substLast (LD x) a= LD $ append' x where
  append' []=[]
  append' [LE x]= [LE a]
  append' [LX(LD [])]= []
  append' [LX(LD xs)]= [LX(LD $ append' xs)]
  append' (x:xs)= x:append' xs

-- dropLast (LD x)= LD $ dropLast' x where
--   dropLast' []=[]
--   dropLast' [LE x]= []
--   dropLast' [LX(LD [])]= []
--   dropLast' [LX(LD xs)]= [LX(LD $ dropLast' xs)]
--   dropLast' (x:xs)= x:dropLast' xs

getLogFromIndex :: [Int] -> LogData -> Builder
getLogFromIndex [] (LD log)= toPathl log

getLogFromIndex [0] (LD log)= toPathl log

getLogFromIndex (i:is) (LD log)= 
  let ls= drop i  log
  in case ls of
    [] -> mempty
    _ ->
      case head ls of
        LX log' -> (if null is then byteString "e/" else mempty)  <> getLogFromIndex is log'  <> 
                                     case ls of
                                       [_] -> mempty
                                       _   -> toPathl (tail $ tail ls)
        _ -> toPathl   ls




dropFromIndex :: [Int] -> LogData -> [LogDataElem]
dropFromIndex [] (LD log)=  log

dropFromIndex [i] (LD log)=  drop i log


dropFromIndex (i:is) (LD log)= 
  let ls= drop i  log 
  in case ls of
    []          -> mempty
    -- (LX (LD [])):t ->  if null t then [] else  tail t
    (LX log':t) -> if null is then [LX $ LD $ dropFromIndex is log'] <> t
                                   else dropFromIndex is log'  <> if null t then [] else tail t
    (LE x:_)    -> if toLazyByteString x== "w/"  then ls else                   
                        drop (length is) ls !!> ("drop",length is,ls)

(!!>) a b = unsafePerformIO (print b) `seq` a

-- >>> dropFromIndex [1,0] $ LD [e "\"p\"/",e "()/",e "HELLO/",e "()/"]
-- [LE "HELLO/",LE "()/"]
--


-- >>> dropFromIndex [1,1] $ LD [e "\"p\"/",LX (LD [e "HI/",e "\"HO\"/"]),e "\"HO\"/",e "HELLO/",e "()/"]
-- [LE "\"HO\"/",LE "HELLO/",LE "()/"]
{- 
debe ser [[LE "\"HO\"/"],LE "HELLO/",LE "()/"]
necesario algo para preservar la estructura.
-}


-- shortest path
toPath (LD l)= toPathl l
toPathl :: [LogDataElem] -> Builder
toPathl  []  = mempty
toPathl (LE b:rest)= b <> toPathl rest
toPathl (LX (LD b):[])=  byteString "e/" <> toPathl  b
toPathl (LX _: b)= toPathl  b

-- longest path
toPathLon (LD x)= toPathlon' x
toPathlon' [] = mempty
toPathlon' (LE b:rest)= b <> toPathlon' rest
toPathlon' (LX x:[])= byteString "e/" <> toPathLon  x
toPathlon' (LX x: b)= byteString "e/" <> toPathLon  x  <> toPathlon' (tail b)
-- >>> toPathLon $ LD $ [e "\"HI\"/",LX (LD [])] <>  [e "\"HELLO\"/",e "()/",LX (LD [])] <>  [e "\"WORLD\"/",e "()/",LX (LD [])]
-- "\"HI\"/e/\"HELLO\"/()/e/\"WORLD\"/()/e/"
--

-- >>> toPathLon $ LD [e "\"proc\"/",e "HELLO/",e "()/",LX (LD [e "\"pre\"/"]),e "\"post\"/",e "WORLD/",e "()/"]
-- "\"proc\"/HELLO/()/e/\"pre\"/\"post\"/WORLD/()/"
--


toPathFragment :: [LogDataElem] -> Builder
toPathFragment []= mempty
toPathFragment (LX x:[]) = toPath x 

toPathFragment (LX x:rest) = toPath x <> toPathl (tail rest)
toPathFragment other= toPathl other

  

pack x=  byteString (BSS.pack x)

(<<) (LD[]) build =LD[LE build]
(<<) (LD log) build=  case splitAt (length log -1) log of

  (_,[LE _]) -> LD $ log ++ [LE build]
  (log',[LX log]) -> LD $ log'++[LX $ log << build]



(<<-) (LD[]) build = LD[LE build]
(<<-) (LD l) build=  case splitAt (length l -1) l of
  
  (_,[LE _]) -> LD $ l ++ [LE build]
  (log',[LX (LD [])]) ->  LD $ log'++[LE build]
  (log',[LX (LD log)]) -> case last log of
     LE _ -> LD $ l ++ [LE build]
     _       ->   LD $ log'++[LX $ (LD log) <<- build]
 



#ifndef ghcjs_HOST_OS


-- | Reads the saved logs from the @logs@ subdirectory of the current
-- directory, restores the state of the computation from the logs, and runs the
-- computation.  The log files are maintained.
-- It could be used for the initial configuration of a program.
rerun :: String -> TransIO a -> TransIO a
rerun path proc = do
     liftIO $ do
         r <- doesDirectoryExist path
         when (not r) $ createDirectory  path
         setCurrentDirectory path
     restore' proc False


logs= "logs/"

-- | Reads the saved logs from the @logs@ subdirectory of the current
-- directory, restores the state of the computation from the logs, and runs the
-- computation.  The log files are removed after the state has been restored.
--
restore :: TransIO a -> TransIO a
restore   proc= restore' proc True

-- >>> deserializePure (BS.pack "e/") :: Maybe(LD,BS.ByteString)
-- Just (LD [LE e/],"")
--

restore' proc delete= do
     liftIO $ createDirectory logs  `catch` (\(e :: SomeException) -> return ())
     list <- liftIO $ getDirectoryContents logs
                 `catch` (\(e::SomeException) -> return [])
     if null list || length list== 2 then proc else do
         let list'= filter ((/=) '.' . head) list
         file <- choose  list'

         log <-  liftIO $ BS.readFile (logs++file)
         -- 
         setData Log{recover= RTrue,fulLog= LD[LE $ lazyByteString log], hashClosure= 0}
         setParseString log
         when delete $ liftIO $ remove $ logs ++ file
         proc
     where
     -- read'= fst . head . reads1

     remove f=  removeFile f `catch` (\(e::SomeException) -> remove f)



-- | Saves the logged state of the current computation that has been
-- accumulated using 'logged', and then 'exit's using the passed parameter as
-- the exit code. Note that all the computations before a 'suspend' must be
-- 'logged' to have a consistent log state. The logs are saved in the @logs@
-- subdirectory of the current directory. Each thread's log is saved in a
-- separate file.
--
suspend :: Typeable a =>  a -> TransIO a
suspend  x= do
   log <- getLog
   if (rrecover log) then return x else do
        logAll  $ fulLog log
        exit x



-- | Saves the accumulated logs of the current computation, like 'suspend', but
-- does not exit.
checkpoint :: TransIO ()
checkpoint = do
   log <- getLog
   if (rrecover log) then return () else logAll  $ fulLog log

logAll :: LogData -> TransIO ()
logAll log= liftIO $do
        newlogfile <- (logs ++) <$> replicateM 7 (randomRIO ('a','z'))
        logsExist <- doesDirectoryExist logs
        when (not logsExist) $ createDirectory logs
        BS.writeFile newlogfile $ toLazyByteString $ serialize log
      -- :: TransIO ()
#else
rerun :: TransIO a -> TransIO a
rerun = const empty

suspend :: TransIO ()
suspend= empty

checkpoint :: TransIO ()
checkpoint= empty

restore :: TransIO a -> TransIO a
restore= const empty

#endif

getLog :: TransMonad m =>  m Log
getLog= getData `onNothing` return emptyLog

emptyLog= Log RFalse False (LD [])  0

-- emptyLogData= let ld=(LogDataChain (LE mempty) (u $ newIORef Nothing)) in LD ld (u $ newIORef ld)

-- | Run the computation, write its result in a log in the state
-- and return the result. If the log already contains the result of this
-- computation ('restore'd from previous saved state) then that result is used
-- instead of running the computation again.
--
-- 'logged' can be used for computations inside a nother 'logged' computation. Once
-- the parent computation is finished its internal (subcomputation) logs are
-- discarded.
--

logged :: Loggable a => TransIO a -> TransIO a
logged mx =   do
        log <- getLog
        -- tr ("BUILD inicio", toPath $ fulLog log)

        let full= fulLog log
        rest <- giveParseString
        tr ("parseString",rest)
        let log'= if BS.null rest then log{recover=RFalse} else log
        notRecover full log'
      -- <** do
      --   log <- getLog
      --   setData $ log{fulLog=fulLog log <<- wait,hashClosure=hashClosure log + 100000}

    where
    notRecover full log= do

        tr ("BUILDLOG0, recover",  rrecover log,fulLog log,fromCont log)

        let fullexec=  full <> exec  
        -- setData $ Log RFalse  fullexec (hashClosure log + 1000)     
        setData log{fulLog= fullexec, fromCont= False, hashClosure= hashClosure log + 1000}
        r <- if rrecover log 
               then recoverIt 
               else mx  -- <**  do setData $ Log (recover log) (fromCont log) (fullexec <<- wait)  (hashClosure log + 100000)
                          <** modifyData' (\log -> log{fulLog=fulLog log <<- wait,hashClosure=hashClosure log + 100000}) emptyLog
                            
                            -- when   p1 <|> p2, to avoid the re-execution of p1 at the
                            -- recovery when p1 is asynchronous or  empty

        log' <- getLog 

        let 
            recoverAfter= recover log'
            add=   (serialize r <> byteString "/")   -- Var (toIDyn r):  full

        tr ("FROMCONT",fromCont log',fromCont log,"RECOVER",recover log,recover log')
        tr ("LOG ",fulLog log)
        tr ("LOG'",fulLog log')

        if recover log == RFalse && (recoverAfter ==RTrue || fromCont log' || fromCont log) then do
            -- setData $ log'{fulLog= fulLog log' <<- add} --,hashClosure=hashClosure log' +10000000}

            -- let rlog= LD $ ful<> drop (length ful +1) full'
            setData $ Log{recover=recover log, fromCont= fromCont log' || fromCont log,fulLog= substLast(fulLog log')  add, hashClosure=hashClosure log +10000000}
            tr ("PROCESSING FROMCONT",substLast (fulLog log')  add)

        else do

            setData $ Log{recover=recover log, fromCont= False, fulLog= fullexec <<- add, hashClosure= hashClosure log +10000000}

            tr ("PROCESSIN NORMAL", fullexec <<- add)
                         
            -- setData $ Log{recover=recover log, fromCont=fromCont log',fulLog= fulLog log' <<- add, hashClosure=hashClosure log +10000000}


        return r

{-
dejar como estaba. poner flag recovery cuando hay un setCont
Necesario un criterio para poner recover= False en un momento dado
no se puede usar recover=False. usar otro flag returnfromcont
problema de wait:
    hasta ahora al acabar mx se recuperaba solo el resultado:
           log <- getLog
           r <- mx <** wait
           log= log + serial r
    eso hace que todo alternativo tenga un wait añadido
    y toda secuencia se le quite el wait
    como quitar el wait en en la siguiente sentencia monadica
       tiene que funcionar dentro de logged y en transient monad
          distinguir logged en alternativo de monadico
          no se puede distinguir si <|> no lo dice

    trasladar logged a la monada cloud
    añadir un 

o poner un w y quitarlo en la siguiente orden de secuencia
o poner alternativo solo en <|> 
  meterno en alternative <|> de Cloud y meter logged en la cloud monad.
  meter fromCont= False en todo aplicativo y monadico

como deshabilitar el flag fromCont:
quitarlo para la siguiente sentencia monadica
 no se puede hacer al principio o baja el flag creado por setCont
 guardar el valor ejecutar sin formCont
     prev 0, after 0 -> 0
     0 1 -> 1   no tenia, pero hay un setCont en mx
     1 0 -> 1   viene de un setCont, pero no hay setcont en mx
     1 1 -> 1   
     0 0 -> 0

plan: hacer los ejemplos con local

flag pasó o no paso mx
si no paso poner w
si paso, nada

siguente logged puede ser ejecutado:
 en la siguente accion monadica: delData ha sido ejecutado
 alternativo al anterior: delData emptychek no ha sido ejecutado
 dentro del anterior:     delData emptychek no ha sido ejecutado

 como se distinguen los dos ultimos casos?
   flag exec

 flag alternativo 

if not fromCont poner <** wait
   pero a la vuelta puede ser necesario recojer lo producido porque ha habido un fromCont
   quitar el wait en esa posicion log ++ drop (length log +1) log'

al entrar mx  tiene un "e/" de ejecución, cuando acaba de procesar, se pone un "w/" preventivo por si entra en un <|> al final se le quita ambos y se pone el resultado.
Ahora: lo mismo al log generado por mx se le añade un w/ preventivo, y hay que quitar
 pero
    logged mx <|> logged my
    ...
    my tendría el w/ preventivo
    como se quita si retorna?
      hay que quitar el ultimo elemento nada mas.
-}

    recoverIt = do
        s <- giveParseString

        tr ("BUILDLOG3 recover", s)

        case BS.splitAt 2 s of
          ("e/",r) -> do
            setParseString r                     --   !> "Exec"
            mx

          ("w/",r) -> do
            setParseString r
            modify $ \s -> s{execMode= Parallel}  --setData Parallel
            empty                                --   !> "Wait"

          _ -> value 

    value = r
      where
      typeOfr :: TransIO a -> a
      typeOfr _= undefined

      r= do
            x <- deserialize <|> do
                    psr <- giveParseString
                    error  (show("error parsing",psr,"to",typeOf $ typeOfr r))

            psr <- giveParseString
            when(not $ BS.null psr) $ tChar '/' >> return()

            -- tr ("BUILDLOG31 recover",   toPath $ fulLog log)

            return x



-- logged :: Loggable a => TransIO a -> TransIO a
-- logged mx =   do
--         log <- getLog
--         -- tr ("BUILD inicio", toPath $ fulLog log)

--         let full= fulLog log
--         rest <- giveParseString

--         if rrecover log                  -- !> ("recover",recover log)
--            then
--                   if not $ BS.null rest 
--                     then recoverIt log     !> "RECOVER" 
--                     else
--                       notRecover full log  !> "NOTRECOVER"

--            else notRecover full log
--     where
--     notRecover full log= do

--       --  tr ("BUILDLOG0,before exec",  toPath full)

--         let fullexec=  full <> exec  
--         setData $ Log RFalse  fullexec (hashClosure log + 1000)     

--         r <-  mx <** do setData $ Log RFalse  (fullexec <<- wait)  (hashClosure log + 100000)
--                             -- when   p1 <|> p2, to avoid the re-execution of p1 at the
--                             -- recovery when p1 is asynchronous or  empty

--         log' <- getLog 

--         tr ("BUILDLOG7 after exec recoveryafter?", recover log', toPath $ fulLog log')

--         let 
--             recoverAfter= recover log'
--             add=  (serialize r <> byteString "/")   -- Var (toIDyn r):  full
--         if recoverAfter == RTrue then
--               setData $ log'{fulLog= fulLog log' <<- add} --,hashClosure=hashClosure log' +10000000}
--         -- else if recoverAfter == Restore then
--         --       setData $ log'{fulLog= fulLog log'{recover=Restore}} -- ,hashClosure=hashClosure log' +10000000}
--         else 
--               setData $ Log{recover= RFalse, fulLog= fullexec <<- add, hashClosure=hashClosure log +10000000}
--               {- exec vacio permite logged $ do .. pero como se quita si no es necesario
--                  se junta en Restore o RTrue
--               -}
--         return r

--     recoverIt log= do
--         s <- giveParseString

--         tr ("BUILDLOG3 recover", s,fulLog log)

--         case BS.splitAt 2 s of
--           ("e/",r) -> do
--             setData $ log{ hashClosure= hashClosure log + 1000}
--             setParseString r                     --   !> "Exec"
--             mx

--           ("w/",r) -> do
--             setData $ log{ hashClosure= hashClosure log + 100000}
--             setParseString r
--             modify $ \s -> s{execMode= Parallel}  --setData Parallel
--             empty                                --   !> "Wait"

--           _ -> value log

--     value log= r
--       where
--       typeOfr :: TransIO a -> a
--       typeOfr _= undefined
--       r= do
--             x <- deserialize <|> do
--                    psr <- giveParseString
--                    error  (show("error parsing",psr,"to",typeOf $ typeOfr r))
                  
--             tChar '/'

--             setData $ log{{-recover= RTrue, -}hashClosure= hashClosure log + 10000000}
--             tr ("BUILDLOG31 recover",   toPath $ fulLog log)

--             return x




-------- parsing the log for API's

received :: (Loggable a, Eq a) => a -> TransIO ()
received n= Transient.Internals.try $ do
   r <- param
   if r == n then  return () else empty

param :: (Loggable a, Typeable a) => TransIO a
param = r where
  r=  do
       let t = typeOf $ type1 r
       (Transient.Internals.try $ tChar '/'  >> return ())<|> return () --maybe there is a '/' to drop
       --(Transient.Internals.try $ tTakeWhile (/= '/') >>= liftIO . print >> empty) <|> return ()
       if      t == typeOf (undefined :: String)     then return . unsafeCoerce . BS.unpack =<< tTakeWhile' (/= '/')
       else if t == typeOf (undefined :: BS.ByteString) then return . unsafeCoerce =<< tTakeWhile' (/= '/')
       else if t == typeOf (undefined :: BSS.ByteString)  then return . unsafeCoerce . BS.toStrict =<< tTakeWhile' (/= '/')
       else deserialize  -- <* tChar '/'


       where
       type1  :: TransIO x ->  x
       type1 = undefined


