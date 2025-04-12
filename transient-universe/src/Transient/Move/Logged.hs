 {-#Language OverloadedStrings, FlexibleContexts, GeneralizedNewtypeDeriving, RecordWildCards #-}
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
--
-- Author: Alabado sea Dios que inspira todo lo bueno que hago. Porque Él es el que obra en mi
--
-- | The 'logged' primitive is used to save the results of the subcomputations
-- of a transient computation (including all its threads) in a  buffer.  The log
-- contains purely application level state, and is therefore independent of the
-- underlying machine architecture. The saved logs can be sent across the wire
-- to another machine and the computation can then be resumed on that machine.
-- We can also save the log to gather diagnostic information.
--

-----------------------------------------------------------------------------
{-# LANGUAGE  CPP, ExistentialQuantification, FlexibleInstances, ScopedTypeVariables, UndecidableInstances #-}
{-# LANGUAGE InstanceSigs #-}
module Transient.Move.Logged(Cloud(..),
Loggable(..), logged, endpoint, received, param, getLog, exec,wait, emptyLog, Log(..),hashExec,genPersistId,persistDBRef,setCont,setCont',receive1,firstCont, dbClos0,setLastClosureForConnection) where

import Data.Typeable
import Data.Maybe
import Unsafe.Coerce
import Transient.Internals
import Transient.EVars
import Transient.Indeterminism(choose)
import Transient.Parse
import Transient.Loggable
import Transient.Move.Defs

import Control.Applicative
import Control.Monad.State
import System.Directory
import Control.Exception
import Control.Monad
import qualified Data.ByteString.Lazy.Char8 as BS
import qualified Data.ByteString.Char8 as BSS
import qualified Data.ByteString                        as B(ByteString)
import qualified Data.Map as M
import Data.TCache hiding (onNothing)
import qualified Data.TCache.DefaultPersistence as TC

import Data.IORef
import System.IO.Unsafe ( unsafePerformIO )
import GHC.Stack

import Data.ByteString.Builder

import Data.TCache (getDBRef)

import Control.Concurrent.MVar ( newEmptyMVar, newMVar )

import System.Random ( randomRIO )

u :: IO a -> a
u= unsafePerformIO

exec :: Builder
exec=  lazyByteString $ BS.pack "e/"
wait :: Builder
wait=  lazyByteString $ BS.pack "w/"





-- | last closure/continuation executed for each remote connection in this branch of execution. Other branches could have other closures so the container should be pure. All further calls from this node to each node/connection should be directed to this corresponding closure.
setLastClosureForConnection :: Int -> Closure -> TransIO (M.Map Int Closure)
setLastClosureForConnection= setIndexData


  {-|
  The 'endpoint' function saves the current execution state and validates
  that all necessary prerequisites for recovery are in place. It is intended
  to be used for distributed computing. 
  
  endpoints can be continued by messages received in the EVar variable that
  is associated with the endpoint.(:++)

  It is basically invokes a `setCont`, which saves the state
   and a `receive` function that wait for messages. and continue the execution

  == Parameters

  maybeName The current mame, that can be used to invoke it from a remote node.
  If not provided, the identifier is generated from a hash that depends on the branch of the computation, so
  that in all the nodes, the name generated is the same.

  
  -}
endpoint :: Maybe B.ByteString -> Cloud ()
endpoint maybeName= Cloud $ do

  PrevClos dbr _ _ <- getData `onNothing` error "teleport: please use `initNode to perform distrubuted computing"
  -- idSession <- localSession <$> liftIO (atomically $ readDBRef dbr `onNothing` error "logApp: no prevClos")
  let (idSession,_) = getSessClosure dbr
  closLocal <- maybe (unCloud $ logged $  liftIO $ BSS.pack . show <$> liftIO (randomRIO (0,100000) :: IO Int)) return maybeName -- hashClosure log
  log <-  getLog

  -- let closLocal= fromMaybe (BSS.pack $ show $ hashClosure log) maybeName

  lc <- setCont' (partLog log) closLocal idSession
  receive1 lc <|> return ()
  -- return ()
  -- Alabado sea Dios



newtype PersistId = PersistId Integer deriving (Read, Show, Typeable)

instance TC.Indexable PersistId where key _ = "persistId"

persistDBRef = getDBRef "persistId" :: DBRef PersistId

genPersistId :: TransIO Integer
genPersistId = liftIO $
  atomically $ do
    PersistId n <- readDBRef persistDBRef `onNothing` return (PersistId 0)
    writeDBRef persistDBRef $ PersistId $ n + 1
    return n


receive1 :: LocalClosure -> TransIO ()
receive1 lc = do
      tr "RECEIVE1'"
      -- when (synchronous conn) $ liftIO $ takeMVar $ localMvar lc 
      -- tr ("EVAR waiting in", localSession lc, localClos lc)
      mr <- readEVar $ fromJust $ localEvar lc

      -- tr ("RECEIVED", mr)

      case mr of
        Right (SDone, _, _, _)    -> empty
        Right (SError e, _, _, _) -> error $ show ("receive:",e)
        Right (SLast log, s2, closr, conn') -> do
          -- cdata <- liftIO $ readIORef $ connData conn' -- connection may have been changed
          -- liftIO $ writeIORef (connData conn) cdata
          setData conn'
          -- tr ("RECEIVED <------- SLAST", log)
          setLog (idConn conn') log s2 closr
        Right (SMore log, s2, closr, conn') -> do
          -- cdata <- liftIO $ readIORef $ connData conn'
          -- liftIO $ writeIORef (connData conn) cdata
          setData conn'
          -- tr ("receive REMOTE NODE", unsafePerformIO $ readIORef $ remoteNode conn,idConn conn)
          -- tr ("receive REMOTE NODE'", unsafePerformIO $ readIORef $ remoteNode conn',idConn conn')

          setLog (idConn conn') log s2 closr
        Left except -> do
          throwt except
          empty


setLog :: Int -> Builder -> Int -> B.ByteString -> TransIO ()
setLog idConn log sessionId closr = do
  tr ("setLog for",idConn,"Closure",sessionId, closr )
  void $ setLastClosureForConnection idConn (getDBRef $ kLocalClos sessionId closr) --  (Closure sessionId closr [])
  setParseString $ toLazyByteString log

  modifyData' (\l -> l {recover = True}) emptyLog
  setState $ ClosToRespond $ getDBRef $ kLocalClos sessionId closr
  -- setCont' log closr sessionId
  return ()

  {-|
    Stores the computation state for the current session id and names it with the given name. If the name is not provided, a name is generated. The state is stored in the database and the computation continues. The computation can be recovered later and executed with `getClosureLog`.
  -}
setCont :: Maybe B.ByteString -> Int -> TransIO (LocalClosure, Log)
setCont mclos idSession = do
  log <- getLog
  closLocal <- case mclos of
                    Just cls -> return cls
                    _ -> return $  BSS.pack . show $ hashClosure log -- BSS.pack . show <$> liftIO (randomRIO (0,100000) :: IO Int) -- 



  -- let dblocalclos = getDBRef $ kLocalClos idSession closLocal :: DBRef LocalClosure

  -- log <- getLog

  lc <- setCont' (partLog log) closLocal idSession
  return (lc, log)

setCont' :: Builder -> B.ByteString -> Int -> TransIO LocalClosure
setCont' logstr closName idSession=  do

  PrevClos dbprevclos _ isapp <- getState <|> error "setCont: no execution state, use initNode"

  let dblocalclos = getDBRef $ kLocalClos idSession closName :: DBRef LocalClosure

  -- tr "RESET LOG"
  modifyState' (\log -> log{partLog= mempty}) (error "setCont: no log")

  ev <- newEVar
  tr ("SETSTATE PREVCLOS",idSession, closName)

  cont <- get




  mr <- liftIO $ atomically $ readDBRef dblocalclos
  closure <- case mr of
    Just (locClos@LocalClosure {..}) -> do
      tr "found dblocalclos"
      if toLazyByteString logstr== mempty -- two consecutive endpoints
        then return locClos
        else return locClos {localEvar = Just ev, localCont = Just cont,localLog= logstr}
    _ -> do
      mv <- liftIO $ newEmptyMVar


      return $
            LocalClosure
              { localSession = idSession,
                prevClos = dbprevclos,
                localLog =  logstr,
                localClos = closName,
                localEvar = Just ev,
                localMvar = mv,
                localCont = Just cont
              }


  tr ("SETCONT", closName, idSession,"PREVCLOS",dbprevclos,logstr)

  setState $ PrevClos dblocalclos True isapp

  liftIO $ atomically $ writeDBRef dblocalclos closure


  return closure


-- dbClos0= getDBRef $ kLocalClos 0 "0"


firstCont = do
  cont <- get
  log <- getLog

  ev <- newEVar
  mv <- liftIO $ newMVar ()

  let this =
        LocalClosure
          { localSession = 0,
            prevClos = dbClos0,
            localLog = partLog log,
            localClos = BSS.pack "0", -- hashClosure log,
            localEvar = Just ev,
            localMvar = mv,
            localCont = Just cont
          }

  liftIO $ atomically $ writeDBRef dbClos0 this
  setState $ PrevClos dbClos0 False False
  return this


-- hashExec= 10000000
-- hashWait= 100000
-- hashDone= 1000

hashDone= 10000000
hashExec= 100000
hashWait= 1000


-- | Run the computation, write its result in a log in the state
-- and return the result. If the log already contains the result of this
-- computation ('restore'd from previous saved state) then that result is used
-- instead of running the computation.
--
-- 'logged' can be used for computations inside a nother 'logged' computation. Once
-- the parent computation is finished its internal (subcomputation) logs are
-- discarded.
--


logged :: Loggable a => TransIO a -> Cloud a
logged mx =  Cloud $ sandboxDataCond handle $ do

    -- Cristo es Rey.  Chirst is King.

    modifyState' ( \prevc -> prevc{hadTeleport= False}) $ error "logged: no execution state"

    indent
    r <- logit <** outdent

    tr ("finish logged stmt of type",typeOf logit, "with value", r)

    return r

    where

    handle (Just mnow) (Just mprev) = Just $ PrevClos (dbref mnow) ( hadTeleport mnow || hadTeleport mprev) False

    logit = do
          initialLog <- getLog
          let initialSegment= partLog initialLog
          rest <- getParseBuffer

          tr ("LOGGED:" <> if recover initialLog then "recovering" else "executing" <> " logged stmt of type",typeOf logit,"parseString", rest,"PARTLOG",partLog initialLog)

          setData initialLog{partLog=  initialSegment <> exec, hashClosure= hashClosure initialLog + hashExec}

          r <-(if not $ BS.null rest then recoverIt else  mx)  <|> addWait initialSegment

          rest <- giveParseString

          let add= serialize r <> "/"
              recov= not $ BS.null rest
              parlog= initialSegment <> add


          prevc <- getData `onNothing` error "logged: no execution state"

          tr ("HADTELEPORT", hadTeleport prevc,recov)

          let hash= hashClosure initialLog{-Alabado sea Dios-} + hashDone -- hashClosure finalLog

          if hadTeleport prevc
            then do
              tr "HADTELEPORT"
              modifyState'  (\finalLog -> finalLog{recover=recov,  hashClosure= hash }) emptyLog

            else
              modifyState'  (\finalLog -> finalLog{recover=recov, partLog= parlog, hashClosure= hash }) emptyLog

          return r


    -- when   p1 <|> p2, to avoid the re-execution of p1 at the
    -- recovery when p1 is asynchronous or  empty
    addWait initialSegment = do
      -- tr ("ADDWAIT",initialSegment)
      -- outdent
      tr ("finish logged stmt of type",typeOf logit, "with empty")
      -- Alabado sea Dios y su madre santísima
      modifyData' (\log -> trace (show ("LOGWAIT",partLog log)) log{partLog= initialSegment <> wait, hashClosure=hashClosure log + hashWait})
                  emptyLog
      empty




    recoverIt = do

        s <- giveParseString

        let (h,t)=  BS.splitAt 2 s
        case  (BS.unpack h,t) of
          ("e/",r) -> do
            -- tr "EXEC"
            setParseString r
            mx

          ("w/",r) -> do
            tr "WAIT"
            setParseString r
            modify $ \s -> s{execMode= if execMode s /= Remote then Parallel else Remote}
                          -- in recovery, execmode can not be parallel(NO; see below)
            empty

          _ -> value s

    value s = r
      where
      typeOfr :: TransIO a -> a
      typeOfr _= undefined

      r= (do
        -- tr "VALUE"
        -- set serial for deserialization, restore execution mode
        x <- do mod <- gets execMode;modify $ \s -> s{execMode=Serial}; r <- deserialize; modify $ \s -> s{execMode= mod};return r
        tr ("value parsed",x)
        psr <- giveParseString
        tr ("parsestring after deserialize",psr)

        when (not $ BS.null psr) $ void (tChar '/')

        return x) <|> errparse

      errparse :: TransIO a
      errparse = do
        -- psr <- getParseBuffer;
        error  ("error parsing <" <> BS.unpack s <> ">  to " <> show (typeOf $ typeOfr r) <> "\n")





-------- parsing the log for API's

received :: (Loggable a, Eq a) => a -> TransIO ()
received n= Transient.Internals.try $ do
   r <- param
   if r == n then  return () else empty

param :: (Loggable a, Typeable a) => TransIO a
param = r where
  r=  do
       let t = typeOf $ type1 r
       Transient.Internals.try (void (tChar '/'))<|> return () --maybe there is a '/' to drop
       --(Transient.Internals.try $ tTakeWhile (/= '/') >>= liftIO . print >> empty) <|> return ()
       if      t == typeRep (Proxy :: Proxy String)     then unsafeCoerce . BS.unpack <$> tTakeWhile' (/= '/')
       else if t == typeRep (Proxy :: Proxy BS.ByteString) then unsafeCoerce <$> tTakeWhile' (/= '/')
       else if t == typeRep (Proxy :: Proxy BSS.ByteString)  then unsafeCoerce . BS.toStrict <$> tTakeWhile' (/= '/')
       else deserialize  -- <* tChar '/'


       where
       type1  :: TransIO x ->  x
       type1 = undefined


