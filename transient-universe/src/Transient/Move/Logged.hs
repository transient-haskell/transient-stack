 {-# LANGUAGE OverloadedStrings, FlexibleContexts, RecordWildCards #-}
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
Loggable(..), logged, endpoint, received, param, getLog, exec,wait, emptyLog,
 Log(..),hashExec,genPersistId,persistDBRef,setCont,setCont',endpointWait,firstCont,
  firstEndpoint,dbClos0, noExState, setLastClosureForConnection,getLastClosureForConnection,updateLastClosureForConnection,setLog) where

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

-- | last closure/continuation executed for each remote connection IN THIS BRANCH of execution. Other branches could have other closures so the container should be pure. All further calls from this node to each node/connection should be directed to this corresponding closure.
-- other branches could have different closures for the same connection since this data is pure.
-- setLastClosureForConnection :: TransMonad m => Int -> Closure -> m ()
-- setLastClosureForConnection a b= setIndexData a b >> return ()

-- getLastClosureForConnection ::   Int -> TransIO Closure
-- getLastClosureForConnection= getIndexState
-- type RemoteClosures = M.Map Int (DBRef Closure)
-- need to store remote closure environment which survives collect
-- but how to survive shutdown and restar?
-- newRemoteClosureEnv = do
--     cls :: RemoteClosures <- getRState <|> return ( ClosToRespond dbClos0)
--     newRState  cls 

setLastClosureForConnection :: (MonadIO m,TransMonad m) => Int -> Closure -> m ()
setLastClosureForConnection c cl = void $ setIndexData c (lazy $ newIORef cl)

updateLastClosureForConnection :: (TransMonad m,MonadIO m) => Int -> Closure -> m ()
updateLastClosureForConnection c cl= do
  mref <- getIndexData c
  case mref of
    Nothing -> void $ setIndexData c (lazy $ newIORef cl)
    Just ref -> liftIO $ writeIORef ref cl

getLastClosureForConnection ::  (TransMonad m, MonadIO m, Alternative m) => Int -> m Closure
getLastClosureForConnection c = do
  mref <- getIndexData c
  case mref of
    Nothing -> empty
    Just ref -> liftIO $ readIORef ref

-- {-#NOINLINE remoteClosures #-}
-- remoteClosures=  unsafePerformIO $ H.fromList [] :: H.LinearHashTable Int Closure

-- setLastClosureForConnection con cl= H.insert remoteClosures con cl

-- getLastClosureForConnection com = do
--      mcl <- H.lookup remoteClosures con
--      case mcl of
--        Nothing -> return dbClos0
--        Just cl -> return cl

-- updateLastClosureForConnection= setIndexRData

-- getLastClosureForConnection n=  getIndexRData n `onNothing` return dbClos0

-- setLastClosureForConnection node clos =newIndexRData node  clos


-- setIndexRData :: (TransMonad m,MonadIO m,Typeable node, Ord node,Typeable val) => node -> val -> m() 
-- setIndexRData node val= do
--     mref <- getData -- `onNothing` error "index not initialized: " <> 
--     case mref of
--       Nothing -> do
--         tr ("index not initialized: ",typeOf (fromJust mref))
--         newIndexRData node val
--       Just ref -> do
--         map <- liftIO $ readIORef ref
--         let mrclos = M.lookup node map
--         case mrclos of
--             Nothing -> liftIO $ writeIORef ref $ M.insert node (lazy $ newIORef val) map
--             Just rclos -> do liftIO $ writeIORef rclos val

-- getIndexRData node= do
--    mref <- getData
--    case mref of
--      Nothing -> return Nothing

--      Just ref ->do
--        map <- liftIO $ readIORef ref
--        let mrefclos =lookup node map
--        case mrefclos of
--          Nothing -> return Nothing
--          Just refclos -> Just <$> liftIO (readIORef refclos)

-- newIndexRData :: (TransMonad m, MonadIO m,Typeable k, Ord k,Typeable v) => k -> v -> m()
-- newIndexRData k v = do
--     -- tr ("SETLASTCLOSURE FOR CONNECTION", k,v)
--     mref <- getData 
--     tr ("setting",typeOf $ fromJust mref)
--     case mref of
--        Nothing -> setData $ lazy $ newIORef (M.singleton k (lazy $ newIORef v))
--        Just ref -> do
--          map <- liftIO $ readIORef ref `asTypeOf`  return (M.singleton k  (lazy $ newIORef v))
--          ref' <- liftIO $ newIORef $ M.insert k  (lazy $ newIORef v) map
--          setData  ref'

-- | a endpoint that blocks waiting for input. It expect a session identifier too
-- it is used by `minput` since a web application can use different sessions/users
endpointWait ::   Maybe B.ByteString -> Int -> TransIO ()
endpointWait  mclos idSession = do
  -- tr ("RECEIVE FROM",unsafePerformIO $ readIORef $ remoteNode conn)
  (mlc, log) <-   setCont mclos idSession
  -- guard to continue restoring the execution stack in case of recovery
  receive1 mlc  <|> guard  (recover log)
 
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
endpoint :: Maybe B.ByteString -> TransIO ()
endpoint maybeName= do

  PrevClos dbr _ _ <- getData `onNothing` error "teleport: please use `initNode to perform distrubuted computing"
  -- idSession <- localSession <$> liftIO (atomically $ readDBRef dbr `onNothing` error "logApp: no prevClos")
  let (idSession,_) = getSessClosure dbr
  -- closLocal <- maybe (unCloud $ logged $  liftIO $ BSS.pack . show <$> liftIO (randomRIO (0,100000) :: IO Int)) return maybeName -- hashClosure log
  log <- getLog
  closLocal <- maybe ( return $ BSS.pack . show $ hashClosure log) return maybeName -- hashClosure log
  -- log <-  getLog

  -- let closLocal= fromMaybe (BSS.pack $ show $ hashClosure log) maybeName

  mlc <- setCont' (partLog log) closLocal idSession
  receive1 mlc <|> return ()
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

-- | receive messages for a closure just created
receive1 ::  LocalClosure -> TransIO ()

receive1  lc = do
  guard (isJust  $ localEvar lc) <|> error "receive: No EVar"
  conn <- getState

  tr ("RECEIVE1'",localClos lc)
  labelState $ "endpoint " <> localClos lc

  -- when (synchronous conn) $ liftIO $ takeMVar $ localMvar lc 
  -- tr ("EVAR waiting in", localSession lc, localClos lc)
  let ev= fromJust $ localEvar lc
  ctr :: Maybe ClosToRespond <- getData

  mr <- if isJust ctr then readEVar1 ev else readEVar ev
          -- (\(e::BlockedIndefinitelyOnSTM) ->  throwt $ ErrorCall $ show (e,localClos lc))

  -- tr ("RECEIVED", mr)

  case mr of
    Right (SDone, _, _, _)    -> error "endpoint/teleport: SDone not expected"
    Right (SError e, _, _, _) -> error $ show ("unexpected remote error:",e)
    Right (SLast log, s2, closr, conn') -> do
      cleanEVar ev
      tr ("RECEIVED <------- SLAST", log)
      liftIO $ writeResource lc{localEvar = Nothing}
      setData conn'
      empty


    Right (SMore log, s2, closr, conn') -> do
      -- cdata <- liftIO $ readIORef $ connData conn'
      -- liftIO $ writeIORef (connData conn) cdata
      setData conn'{calling= calling conn}
      -- tr ("receive REMOTE NODE", unsafePerformIO $ readIORef $ remoteNode conn,idConn conn)
      -- tr ("receive REMOTE NODE'", unsafePerformIO $ readIORef $ remoteNode conn',idConn conn')

      setLog (idConn conn') log s2 closr

    Left except -> do
      throwt except
      empty


-- setLog :: Int -> Builder -> Int -> B.ByteString -> TransIO ()
setLog :: (MonadState TranShip m, MonadIO m, Show a) => Int -> Builder -> a -> B.ByteString -> m ()
setLog idConn log sessionId closr = do
  tr ("setLog for",idConn,"Closure",sessionId, closr )
  void $ updateLastClosureForConnection idConn (getDBRef $ kLocalClos sessionId closr) --  (Closure sessionId closr [])
  setParseString $ toLazyByteString log

  modifyData' (\l -> l {recover = True}) emptyLog
  setState $ ClosToRespond $ getDBRef $ kLocalClos sessionId closr
  tr "setLog done"
  return ()

  {-|
    Stores the computation state for the current session id and names it with the given name. If the name is not provided, a name is generated. The state is stored in the database and the computation continues. The computation can be recovered later and executed with `getClosureLog`.
  -}
setCont :: Maybe B.ByteString -> Int -> TransIO  ( LocalClosure, Log)
setCont mclos idSession =do
  log <- getLog
  closLocal <- case mclos of
                    Just cls -> return cls
                    _ -> return $  BSS.pack . show $ hashClosure log -- BSS.pack . show <$> liftIO (randomRIO (0,100000) :: IO Int) -- 



  -- let dblocalclos = getDBRef $ kLocalClos idSession closLocal :: DBRef LocalClosure

  -- log <- getLog

  lc <- setCont' (partLog log) closLocal idSession
  return (lc, log)

setCont' :: Builder -> B.ByteString -> Int -> TransIO   LocalClosure
setCont' logstr closName idSession=   noTrans $ do

  tr("SETCONT INIT",closName, idSession,logstr)
  let dblocalclos = getDBRef $ kLocalClos idSession closName :: DBRef LocalClosure

  -- tr "RESET LOG"
  modifyState' (\log -> log{partLog= mempty}) (error "setCont: no log")

  PrevClos dbprevclos _ isapp <- getData `onNothing` noExState "setCont"
  -- ctr <- getData :: StateIO (Maybe ClosToRespond)
  cont <- get


  -- mr <- liftIO $ atomically $ readDBRef dblocalclos
  -- case mr of
  --   Just locClos@LocalClosure {..} -> do
  --     tr "found dblocalclos"
  --     closure <- if toLazyByteString logstr== mempty -- two consecutive endpoints
  --       then return locClos
  --       else do
  --         ev <- runTrans newEVar -- if isNothing ctr then runTrans newEVar else return Nothing
  --         return locClos {localEvar = ev, localCont = Just cont,localLog= logstr}
  --     setState $ PrevClos dblocalclos True isapp
  --     liftIO $ atomically $ writeDBRef dblocalclos closure

  --     return  closure
  --   _ -> do
  do
      mv <- liftIO  newEmptyMVar
      ev <- runTrans newEVar -- if isNothing ctr then runTrans newEVar else return Nothing
      tr ("createEVar",closName)

      let closure=
            LocalClosure
              { localSession = idSession,
                prevClos = dbprevclos,
                localLog =  logstr,
                localClos = closName,
                localEvar = ev,
                localMvar = mv,
                localCont = Just cont
              }


      tr ("SETCONT", closName, idSession,"PREVCLOS",dbprevclos,logstr)
      tr ("SETSTATE PREVCLOS",idSession, closName)
      -- here the flag True is set to preserve the endpoint/teleport/continuation si that every log restore pass trough this continuation
      setState $ PrevClos dblocalclos True isapp

      liftIO $ atomically $ writeDBRef dblocalclos closure


      return  closure


-- dbClos0= getDBRef $ kLocalClos 0 "0"

-- | first endpoint for cloud applications. It is internally used by initNode
firstEndpoint= firstCont >>= receive1


-- | first checkpoint to be serialized in cloud applications that do not use distributed/web computing.
-- normally could application use firstEndpoint which makes the checkpoint and can receive serializations of
-- remote stacks (logs) to continue the execution from the checkpoint on.
firstCont =  do
  setState $ PrevClos dbClos0 False False

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

noExState s= error $ s <> ": no execution state. Use initNode to init the Cloud computation"
logged :: Loggable a => TransIO a -> Cloud a
logged mx =  Cloud $ sandboxDataCond handle $ do

    -- Cristo es Rey.  Chirst is King.

    modifyState' ( \prevc -> prevc{preservePath= False}) $ noExState "logged"

    indent
    r <- logit <*** outdent

    tr ("finish logged stmt of type",typeOf logit, "with value", r)

    return r

    where

    handle (Just mnow) (Just mprev) = Just $ PrevClos (dbref mnow) ( preservePath mnow || preservePath mprev) False
    handle _ _ = error "no log initialized: use initNode before logging"

    logit = do
          initialLog <- getLog
          let initialSegment= partLog initialLog
          rest <- getParseBuffer

          tr ("LOGGED:", if recover initialLog then "recovering" else "executing" <> " logged stmt of type",typeOf logit,"parseString", rest,"PARTLOG",partLog initialLog)

          setData initialLog{partLog=  initialSegment <> exec, hashClosure= hashClosure initialLog + hashExec}

          r <-(if not $ BS.null rest then recoverIt else  mx)  <|> addWait initialSegment

          rest <- giveParseString

          let add= serialize r <> "/"
              recov= not $ BS.null rest
              parlog= initialSegment <> add


          prevc <- getData `onNothing` noExState "logged"

          tr ("HADTELEPORT", preservePath prevc,recov)

          let hash= hashClosure initialLog{-Alabado sea Dios-} + hashDone -- hashClosure finalLog

          if preservePath prevc
            then do
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
      modifyData' (\log -> -- trace (show ("LOGWAIT",partLog log)) 
                        log{partLog= initialSegment <> wait, hashClosure=hashClosure log + hashWait})
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


