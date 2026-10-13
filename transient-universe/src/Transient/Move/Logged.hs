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
 Log(..),hashExec,genPersistId,persistDBRef,firstCont,
  firstEndpoint,dbClos0, noExState, setLastClosureForConnection,getLastClosureForConnection,updateLastClosureForConnection,setLog,
  processMessage, sendToClosure, getClosureLog, getClosureLogFrom) where

import Data.Typeable
import Data.Maybe
import Unsafe.Coerce
import Transient.Internals
import Transient.EVars
import Transient.Parse
import Transient.Loggable
import Transient.Move.Defs

import Control.Applicative
import Control.Monad.State
import Control.Exception
import Control.Monad
import qualified Data.ByteString.Lazy.Char8 as BS
import qualified Data.ByteString.Char8 as BSS
import qualified Data.ByteString as B(ByteString)
import qualified Data.Map as M
import Data.TCache hiding (onNothing)
import qualified Data.TCache.DefaultPersistence as TC

import Data.IORef
import System.IO.Unsafe ( unsafePerformIO )

import Data.ByteString.Builder

import Control.Concurrent.MVar

-- | Log marker for an executed branch (@e\/@).
exec :: Builder
exec=  lazyByteString $ BS.pack "e/"
-- | Log marker for a waiting (alternative) branch (@w\/@).
wait :: Builder
wait=  lazyByteString $ BS.pack "w/"

-- | Record the last closure reached on a given connection, so that subsequent
-- messages from that node are routed to the correct continuation.
setLastClosureForConnection :: (MonadIO m,TransMonad m) => Int -> Closure -> m ()
setLastClosureForConnection c cl = void $ setIndexData c (lazy $ newIORef cl)

-- | Update an already-recorded last-closure entry, or create one if absent.
updateLastClosureForConnection :: (TransMonad m,MonadIO m) => Int -> Closure -> m ()
updateLastClosureForConnection c cl= do
  mref <- getIndexData c
  case mref of
    Nothing -> void $ setIndexData c (lazy $ newIORef cl)
    Just ref -> liftIO $ writeIORef ref cl

-- | Retrieve the last closure recorded for a connection, or 'empty' if none.
getLastClosureForConnection ::  (TransMonad m, MonadIO m, Alternative m) => Int -> m Closure
getLastClosureForConnection c = do
  mref <- getIndexData c
  case mref of
    Nothing -> empty
    Just ref -> liftIO $ readIORef ref


newtype PersistId = PersistId Integer deriving (Read, Show, Typeable)

instance TC.Indexable PersistId where key _ = "persistId"

persistDBRef = getDBRef "persistId" :: DBRef PersistId

-- | Atomically allocate a globally unique integer from the TCache-persisted counter.
genPersistId :: TransIO Integer
genPersistId = liftIO $
  atomically $ do
    PersistId n <- readDBRef persistDBRef `onNothing` return (PersistId 0)
    writeDBRef persistDBRef $ PersistId $ n + 1
    return n

-- | Block on the closure's 'EVar' waiting for the next incoming message
-- ('SMore' or 'SLast'), then update the connection, headers, and log so
-- that execution resumes in the correct context.
receive1 ::  LocalClosure -> TransIO ()

receive1  lc = do
  guard (isJust  $ localEvar lc) <|> error "receive: No EVar"
  conn <- getState

  tr ("RECEIVE1'",localClos lc)
  labelState $ "endpoint " <> let ClosureId id =localClos lc in id

  let ev= fromJust $ localEvar lc
  ctr :: Maybe ClosToRespond <- getData

  mr <- if isJust ctr then readEVar1 ev else readEVar ev

  -- tr ("RECEIVED", mr)

  case mr of
    Right (SDone, _, _, _)    -> error "endpoint/teleport: SDone not expected"
    Right (SError e, _, _, _) -> error $ show ("unexpected remote error:",e)
    Right (SLast logs, s2, closr, map) -> do
      cleanEVar ev
      ttr ("RECEIVED <------- SLAST", logs)
      liftIO $ writeResource lc{localEvar = Nothing}
      let conn' = fromMaybe (error "receive1: no connection") $ unsafeCoerce $ M.lookup (typeOf (ofType :: Connection))  map
      setData conn'{calling= calling conn}

      let hdrs= fromMaybe (unsafeCoerce emptyHeaders) $ unsafeCoerce $ M.lookup (typeOf (ofType :: HTTPHeaders))  map
      modify $ \st -> st{mfData= M.insert (typeOf (ofType :: HTTPHeaders)) hdrs $ mfData st }
      setLog (idConn conn') logs s2 closr

    Right (SMore logs, s2, closr, map) -> do
      let conn' = fromMaybe (error "receive1: no connection") $ unsafeCoerce $ M.lookup (typeOf (ofType :: Connection))  map
      ttr (lc,"RECEIVED <------- SMORE",idConn conn', logs)
      let hdrs= fromMaybe (unsafeCoerce emptyHeaders) $ unsafeCoerce $ M.lookup (typeOf (ofType :: HTTPHeaders))  map
      modify $ \st -> st{mfData= M.insert (typeOf (ofType :: HTTPHeaders)) hdrs $ mfData st }
      setData conn'{calling= calling conn}
      setLog (idConn conn') logs s2 closr


    Left except -> do
      throwt except
      empty


-- | Consume the first fragment of a log list.  A 'Jump' teleports execution
-- to the referenced closure; 'Fragment' and 'Collect' return the builder
-- directly.
firstFragment :: [FragmentType] -> TransIO Builder
firstFragment logs = case head logs of
  Jump key   -> do
    let (s,c) = getSessClosure (getDBRef key)
    noTrans $ processMessage s c sessionId0 closureId0 (Right $ tail logs) False
    empty
  Fragment x -> return x
  Collect xs -> for xs

-- | Install a fragment list as the current parse buffer and set 'recover=True'.
setLogFromFile :: [FragmentType] -> TransIO ()
setLogFromFile logs = do
  log <- firstFragment logs
  tr ("SENDING LOG",log)
  setParseString $ toLazyByteString log
  modifyData' (\l -> l {recover = True, restLog= tail logs}) emptyLog{recover = True,restLog= tail logs}
  tr "setLog done"
  return ()

-- | Record the last-reached closure for a connection and install the log
-- fragment list as the recovery parse buffer.
setLog idConn log sessionId  closr = do
  tr ("setLog for",idConn,"Closure",sessionId, closr,log  )
  void $ updateLastClosureForConnection idConn (getDBRef $ kLocalClos sessionId closr) --  (Closure sessionId closr [])
  setState $ ClosToRespond $ getDBRef $ kLocalClos sessionId closr
  setLogFromFile  log  


{-| Save the current execution state (continuation) under the given name, or a
hash-derived name if 'Nothing' is provided, so that remote nodes can resume
execution here.  Blocks waiting for a message on the associated 'EVar'.

Endpoints can be continued by messages written to their 'EVar'.  The name is
stable across nodes that share the same code base, so distributed peer nodes
refer to the same continuation by the same identifier.
-}
endpoint :: Maybe BSS.ByteString  -> TransIO ()
endpoint  maybeName = do

  log@Log{..} <- getLog
  ttr("RECOVER",recover)
  pstring <- giveParseString
  ttr("endpoint log",maybeName,log,pstring)
  closName <- maybe ( return $ BSS.pack . show $ hashClosure ) return maybeName
  PrevClos dbprevclos mn _ isapp iscollect  :: PrevClos <- getData `onNothing` error "teleport: please use `initNode to perform distrubuted computing"
  let idSession = if isJust mn then fromJust mn else fst $ getSessClosure dbprevclos :: SessionId
  ttr ("ENDPOINT PREVCLOS",mn,dbprevclos,idSession)

  ttr("endpoint",closName, idSession,partLog,restLog,recover )
  let dblocalclos = getDBRef $ kLocalClos idSession (ClosureId closName) :: DBRef LocalClosure
  setState  log{partLog= mempty}
  cont <- get


  mr <- liftIO $ atomically $ readDBRef dblocalclos
  closure <- do
      case mr of
        Just locClos@LocalClosure {..} -> do
          tr "found dblocalclos"
          closure <- if toLazyByteString partLog== mempty -- two consecutive endpoints
            then return locClos
            else do 
              
              ev <-  newEVar 
              return locClos {localEvar = Just ev, localCont = Just cont,localLog= 
                      if  recover  then localLog               -- unaltered
                      else if  iscollect  then  Collect $ partLog:
                        case localLog of
                          Collect rest -> rest -- all the paths are stored in the closure log
                          other -> error $ "teleport, collect mismatch: " <> show other
                      else Fragment partLog}                          -- only the current and remove the previous
          -- preservePath= True
          ttr( "SET PREVCLOS",dblocalclos)
          setState (PrevClos dblocalclos Nothing True isapp iscollect :: PrevClos)
          liftIO $ atomically $ writeDBRef dblocalclos closure
          
          liftIO $ tryPutMVar localMvar ()   -- getClosurelog blocks on the MVar, so we need to release it here when it has been restored

          return  closure
        _ -> do
      
          mv <- liftIO  newEmptyMVar
          ev <-  newEVar -- if isNothing ctr then runTrans newEVar else return Nothing
          tr ("createEVar",closName)

          let closure=
                LocalClosure
                  { localSession = idSession,
                    prevClos = dbprevclos,
                    localLog =  Fragment partLog,
                    localClos = ClosureId closName,
                    localEvar = Just ev,
                    localMvar = mv,
                    localCont = Just cont
                  }


          tr ("SETCONT", closName, idSession,"PREVCLOS",dbprevclos,partLog)
          -- here the flag True is set to preserve the endpoint/teleport/continuation si that every log restore pass trough this continuation
          ttr("SET PREVCLOS2",dblocalclos)
          setState (PrevClos dblocalclos Nothing True isapp iscollect :: PrevClos)


          liftIO $ atomically $ writeDBRef dblocalclos closure
          liftIO $ tryPutMVar (localMvar closure) ()   -- getClosurelog blocks on the MVar, so we need to release it here when it has been restored

          return  closure

  conn <- getState <|> error "endpoint: No connection" :: TransIO Connection
  let   
    injectNextSegment=  do
        ttr ("inject", recover, partLog, restLog)
        guard $ not $ null restLog
        b <- firstFragment restLog
        let segment= toLazyByteString b
            isw=  "w/" `BS.isPrefixOf` segment
        guard (recover  && not isw)
           <|> do 
            -- send the segment to the alternative branch
            if recover 
              then do
                guard $ not $ null restLog
                setParseString $ BS.drop 2 segment
                void $ modifyData' (\l -> l {recover = True, partLog=mempty,restLog= tail restLog}) emptyLog
              else 
                setState log{partLog= "w/",restLog= if not $ null restLog then tail restLog else restLog}
            -- log <-getLog
            -- ttr ("setting wait",log)
            empty
        ttr "INJECT"
        setState conn
        mfdata <- gets mfData
        let msg= Right $ (SMore restLog          :: StreamData [FragmentType]
                          , idSession            :: SessionId
                          , ClosureId closName   :: ClosureId
                          , mfdata               :: PolyMap )
        writeEVar (fromJust $ localEvar closure) msg
        empty
  
        

  receive1 closure <|> void injectNextSegment   
  

                                        
  ttr "AFTER ENDPOINT"
  return ()


-- | first endpoint for cloud applications. It is internally used by initNode
firstEndpoint= firstCont >>= receive1


-- | first checkpoint to be serialized in cloud applications that do not use distributed/web computing.
-- normally could application use firstEndpoint which makes the checkpoint and can receive serializations of
-- remote stacks (logs) to continue the execution from the checkpoint on.
firstCont =  do
  ttr "FIRSTCONT"
  setState (PrevClos  dbClos0 Nothing False False False :: PrevClos)

  cont <- get
  log <- getLog

  ev <- newEVar
  mv <- liftIO $ newMVar ()

  let this =
        LocalClosure
          { localSession = sessionId0,
            prevClos  = dbClos0,
            localLog  = Fragment $ partLog log,
            localClos = closureId0, -- hashClosure log,
            localEvar = Just ev,
            localMvar = mv,
            localCont = Just cont
          }

  liftIO $ atomically $ writeDBRef dbClos0 this
  return this

hashDone= 10000000
hashExec= 100000
hashWait= 1000

-- | Throw a missing-execution-state error with a context label.
noExState s= error $ s <> ": no execution state. Use initNode to init the Cloud computation"


-- | Run the computation, write its result in a log in the state
-- and return the result. If the log already contains the result of this
-- computation ('restore'd from previous saved state) then that result is used
-- instead of running the computation.
--
-- 'logged' can be used for computations inside a nother 'logged' computation. Once
-- the parent computation is finished its internal (subcomputation) logs are
-- discarded.
--


logged :: Loggable a => TransIO a -> TransIO a
logged mx =  sandboxDataCond handle $ do

    -- Jesuschrist loves you

    modifyState' ( \prevc -> prevc{preservePath= False}) $ noExState "logged"

    -- indent
    r <- logit  -- <*** outdent
    -- l <- getLog
    ttr ("finish logged stmt of type",typeOf logit, "with value", r) -- ,"LOG",l)

    return r

    where

    handle (Just mnow) (Just mprev) = Just (PrevClos (prevDBRef mnow) (pnewSession mnow) 
                                           ( preservePath mnow || preservePath mprev) 
                                           False 
                                           (isCollect mnow || isCollect mprev) :: PrevClos)
    handle _ _ = error "no log initialized: use initNode before logging"
    logit = do
          initialLog <- getLog
          let initialSegment= partLog initialLog
          rest <- getParseBuffer

          ttr ("LOGGED:", if recover initialLog then "recovering" else "executing" <> " logged stmt of type",typeOf logit,"parseString", rest,"PARTLOG",partLog initialLog)
          
          setData initialLog{partLog=  initialSegment <> exec, hashClosure= hashClosure initialLog + hashExec}

          r <-(if not $ BS.null rest then recoverIt else  mx)  <|> addWait initialLog 

          rest <- giveParseString

          let add= serialize r <> "/"
              recov=  not $ (BS.null rest && null (restLog initialLog))
              parlog= initialSegment <> add


          prevc <- getData `onNothing` noExState "logged"
          ttr ("recov",recov,rest,restLog initialLog)
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
    addWait initialLog  = do
          -- the alternative branch has been chosen. This is a algebraic composition. the execution continues in the alternative branch
          --
          let initialSegment= partLog initialLog
          ttr ("finish logged stmt of type",typeOf logit, "with empty")
          prevc <- getData `onNothing` noExState "logged"

          rest <- giveParseString

          let recov= not $ (BS.null rest && null (restLog initialLog))
          ttr ("HADTELEPORT", preservePath prevc,recov)

          if preservePath prevc
            then do
              modifyState'  (\finalLog -> finalLog{recover=recov
                    ,partLog=partLog finalLog 
                    ,hashClosure= hashClosure finalLog + hashWait }) emptyLog

            else
              modifyState'  (\finalLog -> finalLog{recover=recov
                  , partLog= initialSegment <> wait
                  , hashClosure= hashClosure finalLog  + hashWait }) emptyLog

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
        let err= "error parsing <" <> BS.unpack s <> ">  to " <> show (typeOf $ typeOfr r) <> "\n"
        ttr err
        error  err





-------- parsing the log for API's

-- | Succeed only if the next 'param' in the log equals @n@; otherwise 'empty'.
received :: (Loggable a, Eq a) => a -> TransIO ()
received n= Transient.Internals.try $ do
   r <- param
   if r == n then  return () else empty

-- | Parse the next slash-delimited value from the log, deserializing it to the
-- expected type.  Handles 'String', strict\/lazy 'ByteString', and any
-- 'Loggable' via 'deserialize'.
param :: (Loggable a, Typeable a) => TransIO a
param = r where
  r=  do
       let t = typeOf $ type1 r
       Transient.Internals.try (void (tChar '/'))<|> return () --maybe there is a '/' to drop
       if      t == typeRep (Proxy :: Proxy String)     then unsafeCoerce . BS.unpack <$> tTakeWhile' (/= '/')
       else if t == typeRep (Proxy :: Proxy BS.ByteString) then unsafeCoerce <$> tTakeWhile' (/= '/')
       else if t == typeRep (Proxy :: Proxy BSS.ByteString)  then unsafeCoerce . BS.toStrict <$> tTakeWhile' (/= '/')
       else deserialize  -- <* tChar '/'


       where
       type1  :: TransIO x ->  x
       type1 = undefined


-- | Route an incoming log fragment to the closure identified by (@s1@, @closl@).
-- A session starting with @#@ denotes a cross-session jump: the closure is
-- copied under the new session and execution continues there.
-- @deleteClosure@ controls whether the EVar receives 'SLast' (close) or
-- 'SMore' (keep open).
processMessage :: SessionId -> ClosureId -> SessionId -> ClosureId -> Either CloudException [FragmentType] -> Bool -> StateIO (Maybe ())
processMessage s1@(SessionId ss1) closl s2 closr mlog deleteClosure = do
  ttr ("processMessage", s1,closl,s2,closr,mlog,deleteClosure)
  conn <- getData `onNothing` error "Listen: myNode not set, use initNode"
  tr ("processMessage REMOTE NODE", unsafePerformIO $ readIORef $ remoteNode conn, idConn conn)
  
  case BSS.head ss1 of
      '#' -> do  -- is a jump
        let (sx,sx')= BSS.span(/= '-') ss1
        let s= BSS.tail sx; s'= BSS.tail sx'
        let contref = getDBRef $ kLocalClos (SessionId s) closl
            contref'= getDBRef $ kLocalClos (SessionId s') closl

        liftIO $  do
          -- create a new closure copy of the endpoint referenced but with the new session id
          cl <- (atomically $ readDBRef contref) `onNothing` errClosure conn (SessionId s) closl
          let cl'= cl{localSession=SessionId s',prevClos= contref} --,localCont=Nothing}
          atomically $ writeDBRef (getDBRef $ kLocalClos (SessionId s') closl) cl'
        -- send to this new closure
        modifyState' (\pc ->pc{prevDBRef= contref'}) $ error "processMessage: no prevclos"
        processMessage (SessionId s') closl  s2 closr mlog deleteClosure

      _ -> do
          mcont <- liftIO $ atomically $
              readDBRef (getDBRef (kLocalClos s1 closl) :: DBRef LocalClosure)

          tr ("mcont", isJust mcont)
          case mcont of
            Nothing -> do
              errClosure conn s1 closl
              return Nothing

            Just LocalClosure {localCont = Nothing} -> do
              tr "RESTORECLOSuRE"
              (log', closreg) <- getClosureLog s1 closl
              tr "AFTER RESTORECLOS"
              case mlog of
                Right log -> do
                  mfdata <- gets mfData
                  sendToClosure ((log' :: [FragmentType]) <> log) s2 closr mfdata deleteClosure closreg
                Left except -> do
                  tr ("receive:", except)
                  runTrans $ writeEVar (fromJust $ localEvar closreg) $ Left except
                  return()
              return Nothing

            Just closreg@LocalClosure {localEvar = Just ev, localCont = Just cont} -> do
              tr "localcont found"
              when (synchronous conn) $ liftIO $ void (tryPutMVar (localMvar closreg) ())
              case mlog of
                Right log -> do
                  mfdata <- gets mfData
                  sendToClosure log s2 closr mfdata deleteClosure closreg
                Left except -> do
                  tr ("receive:", except)
                  runTrans $ writeEVar ev $ Left except
                  return()
              return Nothing

errClosure conn s clos = do
  node <- liftIO $ readIORef (remoteNode conn) `onNothing` error "mconnect: no remote node?"
  let err = CloudException node s clos "request received for non existent closure"
  tr err
  throw err


-- | Write a log fragment to a closure's 'EVar', using 'SLast' if
-- @deleteClosure@ is 'True' (last message) or 'SMore' otherwise.
sendToClosure :: [FragmentType] -> SessionId -> ClosureId -> PolyMap -> Bool -> LocalClosure -> StateIO ()
sendToClosure logs s2 closr map deleteClosure clos@LocalClosure{localEvar = mev} = do
  tr "before writeevar"
  case mev of
    Nothing -> error $ show ("NO EVAR IN CLOSURE",clos)
    Just ev -> do
      runTrans $ do
        if deleteClosure
            then writeEVar ev $ Right (SLast logs, s2, closr, map)
            else writeEVar ev $ Right (SMore logs, s2, closr, map)
      return()


-- | Retrieve the accumulated log and the live closure for (@idSession@, @clos@).
-- Walks the prevClos chain until a closure with a live continuation is found,
-- prepending each closure's stored fragment to the log.
-- Blocks on the closure's 'MVar' to serialise concurrent recoveries.
getClosureLog :: MonadIO m => SessionId -> ClosureId -> m ([FragmentType], LocalClosure)
getClosureLog (SessionId "0") (ClosureId "0") = do
  ttr ("getClosureLog", sessionId0, closureId0)
  clos <- liftIO $ atomically $ readDBRef (getDBRef $ kLocalClos sessionId0 closureId0) `onNothing` error "closure 0 not found in DB"
  return (mempty, clos)

getClosureLog idSession clos = do
  ttr ("getClosureLog", idSession, clos)
  let dbref= getDBRef $ kLocalClos idSession clos
  closReg <- liftIO $ atomically (readDBRef dbref)  `onNothing` error ("closure not found in DB:" <> show (idSession, clos))
  liftIO $ takeMVar (localMvar closReg) -- avoid being recovered by different threads
  closReg <- liftIO $ atomically $ readDBRef dbref  `onNothing` error ("closure not found in DB:" <> show (idSession, clos))
  case localCont closReg of
    Nothing -> do
      prev <- liftIO $ atomically $ readDBRef (prevClos closReg) `onNothing` error "prevClos not found"
      (prevLog, clos) <- getClosureLog (localSession prev) (localClos prev)
      let locallogclos = localLog closReg
      tr ("PREVLOG",   prevLog)
      tr ("LOCALLOG",  locallogclos)
      tr ("SUM",       prevLog <> [locallogclos])
      return (prevLog <> [locallogclos], clos)
    Just cont -> do
      tr ("JUST", idSession, clos)
      return (mempty, closReg)


-- | Collect the log fragments on the path from @remclos@ up to (but not
-- including) @prevclos@, stopping at 'dbClos0'.
getClosureLogFrom :: DBRef LocalClosure -> DBRef LocalClosure -> StateIO [FragmentType]
getClosureLogFrom prevclos remclos
  | prevclos == dbClos0 = return mempty
  | otherwise = do
  prevReg <- liftIO $ atomically $ readDBRef prevclos `onNothing` error ("closure not found in DB:" <> keyObjDBRef prevclos)
  tr ("getClosureLogFrom", prevclos, remclos)
  case prevclos == remclos of
    False -> do
      prevLog <- getClosureLogFrom (prevClos prevReg) remclos
      let locallogclos = localLog prevReg
      tr ("PREVLOG",  prevLog)
      tr ("LOCALLOG", prevclos, locallogclos)
      tr ("SUM",      prevLog <> [locallogclos])
      return (prevLog <> [locallogclos])
    True ->
      return mempty


