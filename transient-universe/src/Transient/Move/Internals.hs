--------------------------------------------------------------------------
--
-- Module      :  Transient.Move.Internals
-- Copyright   :
-- License     :  MIT
--
-- Maintainer  :  agocorona@gmail.com
-- Stability   :
-- Portability :
-- Dedicated to:  Jesus Chist our Lord and Savior
--
-----------------------------------------------------------------------------
{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts #-}

{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverlappingInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}
{-# HLINT ignore "Use if" #-}
{-# HLINT ignore "Use unless" #-}
-- {-# LANGUAGE DeriveAnyClass #-}

module Transient.Move.Internals where
import Prelude hiding(drop,length)

import Transient.Internals
import Transient.Parse
import Transient.Move.Logged
import Transient.Loggable
import Transient.Indeterminism
import Transient.Mailboxes
import Transient.EVars
import Transient.Console
import Transient.Move.Defs

import Data.Typeable
import Control.Applicative
import Control.Exception(IOException(..))
import System.Random
import Data.String
import qualified Data.ByteString.Char8                  as BC
import qualified Data.ByteString.Lazy.Char8             as BS

import Data.TCache  hiding (onNothing)
import Data.TCache.IndexQuery

import System.Time
import System.IO
import Data.ByteString.Builder

import GHC.Generics
import Data.Hashable

#ifndef BROWSER
import Network.URI
--import qualified Data.IP                              as IP
import qualified Network.Socket                         as NS
import qualified Network.WebSockets                     as NWS -- S(RequestHead(..))

import qualified Network.WebSockets.Connection          as WS

import           Network.WebSockets.Stream hiding(parse)

import qualified Data.ByteString                        as B(ByteString)
import qualified Data.ByteString.Lazy.Internal          as BLC
import qualified Data.ByteString.Lazy                   as BL
import           Network.Socket.ByteString              as SBS(sendMany,sendAll,recv)
import qualified Network.Socket.ByteString.Lazy         as SBSL
import           Data.CaseInsensitive(mk,CI)
import           Data.Char
import           Data.Aeson
import qualified Data.ByteString.Base64.Lazy            as B64
import Network.Mime
import Data.Text.Encoding

#else
import Transient.Move.Browser
import qualified Data.ByteString.Lazy                   as BL

#endif

import Control.Monad
import Control.Monad.State
import Control.Monad.Fail
import Control.Exception hiding (onException,try)
import Transient.Base (onException, continue)
import Data.Maybe

import System.IO.Unsafe
import Control.Concurrent.STM as STM
import Control.Concurrent.MVar

import Data.Monoid
import qualified Data.Map as M
import Data.List (partition, nub, union,(\\),length, nubBy,isPrefixOf)
import Data.IORef

import Control.Concurrent

import System.Mem.StableName
import Unsafe.Coerce
import System.Environment
import Data.Default
import System.IO.Error (isResourceVanishedError)

pk = BS.pack
up = BS.unpack
#ifdef BROWSER
type HostName  = String
newtype PortID = PortNumber Int deriving (Read, Show, Eq, Typeable)
#endif

instance Read Connection where
  readsPrec _ str = let [(x,r')] = reads str in [(fromJust . fst . lazy . runTransient $ mconnect x,r')]

type UPassword = BS.ByteString

type Host = BS.ByteString

type ProxyData = (UPassword, Host, Int)

{-# NOINLINE rHTTPProxy #-}
rHTTPProxy = unsafePerformIO $ newIORef (Nothing :: Maybe (Maybe ProxyData, Maybe ProxyData))

getHTTProxyParams t = do
  mp <- liftIO $ readIORef rHTTPProxy
  case mp of
    Just (p1, p2) -> return $ if t then p2 else p1
    Nothing -> do
      ps <- (,) <$> getp "http" <*> getp "https"
      liftIO $ writeIORef rHTTPProxy $ Just ps
      getHTTProxyParams t
  where
    getp t = do
      let var = t ++ "_proxy"

      p <- liftIO $ lookupEnv var
      -- tr ("proxy", p)
      case p of
        Nothing -> return Nothing
        Just hp -> do
          pr <- withParseString (BS.pack hp) $ do
            tDropUntilToken (BS.pack "//") <|> return ()
            (,,) <$> getUPass <*> tTakeWhile' (/= ':') <*> int
          return $ Just pr
    getUPass = tTakeUntilToken "@" <|> return ""

#ifndef BROWSER

--- empty Hooks for TLS

{-# NOINLINE tlsHooks #-}
tlsHooks ::
  IORef
    ( Bool,
      SData -> BS.ByteString -> IO (),
      SData -> IO B.ByteString,
      NS.Socket -> BS.ByteString -> TransIO (),
      String -> NS.Socket -> BS.ByteString -> TransIO (),
      SData -> IO ()
    )
tlsHooks =
  unsafePerformIO $
    newIORef
      ( False,
        notneeded,
        notneeded,
        \_ i -> tlsNotSupported i,
        \_ _ _ -> return (),
        \_ -> return ()
      )
  where
    notneeded = error "TLS hook function called"

    tlsNotSupported input = do
      when ((not $ BL.null input) && BL.head input == 0x16) $ do
          conn <- getSData
          sendRaw conn $ BS.pack $ "HTTP/1.0 525 SSL Handshake Failed\r\nContent-Length: 0\nConnection: close\r\n\r\n"

(isTLSIncluded, sendTLSData, recvTLSData, maybeTLSServerHandshake, maybeClientTLSHandshake, tlsClose) = unsafePerformIO $ readIORef tlsHooks
#endif

-- | Means that this computation will be executed in the current node. the result will be logged
-- so the closure will be recovered if the computation is translated to other node by means of
-- primitives like `beamTo`, `forkTo`, `runAt`, `teleport`, `clustered`, `mclustered` etc
local :: Loggable a => TransIO a -> Cloud a
local = Cloud . logged


-- | Lift a 'TransIO' computation into 'Cloud' __without logging its result__.
--
-- This is NOT like 'local'. 'local' logs the result, so on replay (recovery, or
-- when the closure is translated to another node by `teleport`/`runAt`/… ) the
-- value is recovered from the log and the computation is NOT run again. 'onAll'
-- logs nothing, so:
--
--   * The computation is __re-executed every time__ the surrounding closure is
--     recovered or replayed. For anything non-deterministic (time, randomness,
--     reading mutable state, `getNodes`, IO in general) __each re-execution can
--     produce a different result__ — and a different result on different nodes,
--     which desynchronises the per-node stacks and breaks later distributed steps.
--
--   * It does not require 'Loggable', so it is the way to run a computation whose
--     result __cannot be serialised__.
--
-- Prefer 'local' by default. Use 'onAll' only for __non-'Loggable' results__, and
-- only when you fully understand that it re-runs and may differ on each run: you
-- must know well what you are doing.
onAll :: TransIO a -> Cloud a
onAll = Cloud

-- | Like 'onAll' (lifts a 'TransIO' computation without logging its own result),
-- but it forces an __effect inside the computation to always re-execute__.
--
-- Normally a function's log is substituted by its result: on replay/recovery the
-- function collapses to its logged value and its body is not run again.
-- 'onAllDeep' (via @preservePath = True@) stops that substitution, so the
-- computation is forced to __pass through__ the statement you want re-executed.
--
-- Use it for an effect that must be re-applied and __persist after the function
-- returns__ — e.g. a 'setState' of something important that has to stay set once
-- the function has finished. With plain 'onAll' the function would be replaced by
-- its result on replay and the effect would be lost.
onAllDeep :: TransIO a -> Cloud a
onAllDeep proc = do
    modifyState' (\prevclos -> prevclos{preservePath=True}) $ noExState "setCloudState"
    onAll proc

-- #ifndef BROWSER

-- | Run a distributed computation inside the IO monad. Enables asynchronous
-- console input (see 'keep').
runCloudIO :: Typeable a => Cloud a -> IO (Either String a)
runCloudIO (Cloud mx) = keep mx

-- | Run a distributed computation inside the IO monad with no console input.
runCloudIO' :: Typeable a => Cloud a -> IO [a]
runCloudIO' (Cloud mx) = keep' mx

-- #endif

-- | alternative to `local` It means that if the computation is translated to other node
-- this will be executed again if this has not been executed inside a `local` computation.
--
-- > onAll foo
-- > local foo'
-- > local $ do
-- >       bar
-- >       unCloud $ do
-- >               onAll baz
-- >               runAt node ....
-- > runAt node' .....
--
-- foo bar and baz will e executed locally.
-- But foo will be executed remotely also in node' while foo' bar and baz don't.

--


-- | Log the result a cloud computation. Like `loogged`, this erases all the log produced by computations
-- inside and substitute it for that single result when the computation is completed.
loggedc :: Loggable a => Cloud a -> Cloud a
loggedc (Cloud mx) = Cloud $ logged mx


-- | the `Cloud` monad has no `MonadIO` instance since the value must be `Loggable` and MonadIO can not express this contraint. `localIO= local . liftIO`
localIO :: Loggable a => IO a -> Cloud a
localIO = local . liftIO

-- | continue the execution in another node
beamTo :: Node -> Cloud ()
beamTo node = wormhole node teleport

-- | execute in the remote node with the same execution state and continues in the local node
forkTo :: Node -> Cloud ()
forkTo node = beamTo node <|> return ()

-- | Opens a wormhole to another node and executes an action there. The result is returned to the calling node
-- By default, the connection remains open for streaming additional requests and responses.
callTo :: Loggable a => Node -> Cloud a -> Cloud a
callTo node remoteProc = wormhole node $ atRemote remoteProc


-- | When distributed computations execute concurrent actions, this prefix is needed if there are further distributed computations in the mondad. This happens in applicatives or any binary operation (that makes use of applicative). This primitive sandbox the distributed concurrent operation and his result is logged.

-- concurrentCloud ::  Cloud a -> Cloud a

-- concurrentCloud clcomp=  do
--   log <- getLog

--   isapp <- gets isApplicative
--   modify $ \s ->s{isApplicative= True}
--   when (not isapp) $ Cloud $ endpoint Nothing <|> guard (not $ recover log)
--   r <-    clcomp <|>  do modify $ \s -> s{isApplicative= isapp} ; empty
--   modify $ \s -> s{isApplicative= isapp}
--   return r


-- | Superseded by the applicative of 'Cloud' ('apTransIO' in "Transient.LEngine"), which resolves the
-- distributed applicatives by itself: it is no longer necessary to wrap them. It is kept for the programs that
-- already use it, and none of the tests does.
--
-- It makes an endpoint before the computation and sets the 'isApplicative' flag while it runs.
concurrentCloud :: Loggable a =>  Cloud a -> Cloud a
concurrentCloud cl=   do
    log  <- getLog
    onAll $ endpoint Nothing <|> guard (not $ recover log)
    isapp <- gets isApplicative
    let restoreflag= do modify $ \s -> s{isApplicative= isapp} 

    modify $ \s ->s{isApplicative= True} 

    local $ sandboxData (ofType :: PrevClos)  $ do
           r <- unCloud cl   <|> (restoreflag >> empty)
           restoreflag
           return r




-- NOTE: erroneous since it deletes the data before the return of a remote invocation it must be after it
-- concurrent= error "CONCURRENT: pending"

-- -- | used for lifting primitives that are concurrent in the TransIO monad to perform
-- -- concurrent distributed computations like `collect`
-- liftConcurrent :: Loggable b => (TransIO a -> TransIO b) -> Cloud a -> Cloud b
-- liftConcurrent f x= concurrentCloud $ liftCloud f x

-- | Run @x@ aside and go on with the computation (the 'Cloud' version of a fork). 'abduce' is logged: the log of the
-- branch of @x@ has its result and the log of the other branch has the @w\/@ of the alternative, so a replay knows
-- which of the two branches a log belongs to.
forkCloud :: Cloud a -> Cloud ()
forkCloud x= (local abduce >> x >> empty) <|> return ()

-- | lift a TransIO computation which accept a TransIO parameter, like, for example, `threads` etc, to the Cloud monad. Just in case this ope
liftCloud :: Loggable b => (TransIO a -> TransIO b) -> Cloud a -> Cloud b
liftCloud f (Cloud x) = Cloud $  f x
--  do
--     log <- getLog
--     if not $ recover log then f x else x >> empty
    -- do NOT work without concurrent in concurrent since any furter invocation to any endpoint in the remote node will be sliently stopped
    -- because the emptyu after x. it is necessary to filter any endpoint withing the expression.


-- | Within a connection to a node opened by `wormhole`, it run the computation in the remote node and return
-- the result back to the original node.
--
-- If `atRemote` is executed in the remote node, then the computation is executed in the original node
--
-- > wormhole node2 $ do
-- >     t <- atRemote $ do
-- >           r <- foo              -- executed in node2
-- >           s <- atRemote bar r   -- executed in the original node
-- >           baz s                 -- in node2
-- >     bat t                       -- in the original node
atRemote :: Loggable a => Cloud a -> Cloud a
atRemote proc =  do
      tr "ATREMOTE TELEPORT1"
      teleport
      tr "ATREMOTE TELEPORT1 END"

      -- recover  is executed in serial mode
      modify $ \s -> s {execMode = if execMode s == Parallel then Parallel else Serial}
      r <- loggedc proc -- <** modify (\s -> s {execMode = Remote}) 
      
      tr "ATREMOTE TELEPORT2"
      teleport
      tr "ATREMOTE TELEPORT2 END"

      return r


-- | open a wormhole to another node and executes an action on it.
-- currently by default it keep open the connection to receive additional requests
-- and responses (streaming)
runAt :: Loggable a => Node -> Cloud a -> Cloud a
runAt node remoteProc = wormhole node $ atRemote remoteProc

-- | run a single thread with that action for each connection created.
-- When the same action is re-executed within that connection, all the threads generated by the previous execution
-- are killed
--
-- >   box <-  foo
-- >   r <- runAt node . local . single $ getMailbox box
-- >   localIO $ print r
--
-- if foo  return different mainbox indentifiers, the above code would print the
-- messages of  the last one.
-- Without single, it would print the messages of all of them since each call would install a new `getMailBox` for each one of them
single :: TransIO a -> TransIO a
single f = do
  cutExceptions
  Connection {closChildren = rmap} <- getSData <|> error "single: only works within a connection"
  mapth <- liftIO $ readIORef rmap
  id <- liftIO $ hashStableName <$> makeStableName f

  case M.lookup id mapth of
    Just tv -> liftIO $ killBranch tv
    Nothing -> return ()

  tv <- get
  f <** do liftIO $ modifyIORef rmap $ \mapth -> M.insert id tv mapth

-- | run an unique continuation for each connection in that place of the computation. The first thread that execute `unique` is
-- executed for that connection. The rest are ignored.
unique :: TransIO a -> TransIO a
unique f = do
  Connection {closChildren = rmap} <- getSData <|> error "unique: only works within a connection"
  mapth <- liftIO $ readIORef rmap
  id <- liftIO $ hashStableName <$> makeStableName (f `seq` f)

  let mx = M.lookup id mapth
  case mx of
    Just _ -> empty
    Nothing -> do
      tv <- get
      liftIO $ modifyIORef rmap $ \mapth -> M.insert id tv mapth
      f

-- | A wormhole opens a connection with another node anywhere in a computation.
-- `teleport` uses this connection to translate the computation back and forth between the two nodes connected.
-- If the connection fails, it search the network for suitable relay nodes to reach the destination node.
wormholeRelay :: Loggable b => Node -> Cloud b -> Cloud b
wormholeRelay node comp = do
    onAll $
        onException $ \e@(ConnectionError "no connection" nodeerr) ->
           when (nodeerr == node) $ do unCloud $ findRelay node; continue
    wormhole node comp
    where
        findRelay node = do
            relaynode <- exploreNetUntil $ do
                nodes <- local getNodes
                let thenode = filter (== node) nodes
                if not (null thenode) && isJust (connection $ Prelude.head thenode) then return $ Prelude.head nodes else empty
              <|> error ("no connection to: " ++ show node)
            local $ addNodes [node {nodeServices = nodeServices node ++ [Service $ M.fromList [("relay", show (nodeHost (relaynode :: Node), nodePort relaynode))]]}]


-- | wormhole without searching for relay nodes.
wormhole :: Loggable a => Node -> Cloud a -> Cloud a
wormhole node (Cloud comp) =  local $  do
    ttr ("WORMHOLE",node)
    moldconn <- getData :: TransIO (Maybe Connection)


    labelState $ "wormhole " <> BC.pack (nodeHost node <> ":"<> show (nodePort node))
    log <- getLog
    if not $ recover log
      then do
        abduce
        my <- getMyNode
        if node== my
          then do
            -- a call to the own node: a Self connection of its own, so that the connection of the state (the one to
            -- the caller of this node, if this node is executing a request) is not modified and it is restored at the end
            let conn = fromMaybe (error "wormhole: no connection") moldconn
            rself <- liftIO $ newIORef  $ Just Self
            rnode <- liftIO $ newIORef  $ Just node
            -- It is a call of this node, not the response to its caller: like in a call to another node, the closure to
            -- respond to is not used (see 'calledConn') and the connection is the one of a caller.
            sandboxData (ofType :: ClosToRespond) $ sandboxData (ofType :: Connection) $ do
                delState (ofType :: ClosToRespond)
                setData conn{connData= rself, remoteNode= rnode, calling= True}
                comp
          else do
            (prevprevclos,idconn,r) <-
                 sandboxData (ofType :: ClosToRespond) $
                 sandboxData (ofType :: Connection)    $ do
                  -- a new call to another node is not the response to the caller of this node: if this
                  -- node is executing a request that has not been answered yet, its ClosToRespond must not
                  -- be used as the destination closure of the first teleport (it is restored on exit)
                  delState (ofType :: ClosToRespond)
                  -- newRemoteClosureEnv

                  ps <- gets parseContext
                  ttr "before mconnect"
                  conn <- mconnect node
                  ttr "After mconnect"

                  modify $ \s -> s{parseContext=ps}
                  -- assert (Just node== (unsafePerformIO $ readIORef $ remoteNode conn)) $ return()
                  -- tr "wormhole after connect"

                  liftIO $ writeIORef (remoteNode conn) $ Just node
                  -- tr("WORMHOLE",node)
                  setData conn {synchronous = maybe False synchronous moldconn, calling = True}
                  ttr "after2 connection"
                  prevprevclos <- tryState <|> noExState "teleport"
                  r <- comp
                  delState $ ClosToRespond dbClos0

                  return (prevprevclos :: PrevClos,idConn conn,r)
            
            -- when (preservePath prevprevclos) $ do setState prevprevclos; void $ setLastClosureForConnection idconn $ prevDBRef prevprevclos

            return r


      else do
        tr "wormhole recover"
        let conn = fromMaybe (error "wormhole: no connection in remote node") moldconn
        setData $ conn{calling = False}
        -- setLastClosureForConnection (idConn conn) dbClos0
        -- The remote computation should'nt execute alternative computations afterwards (problemsol 12)
        comp  <|> (modify (\s -> s {execMode = Remote}) >> empty)


-- | set synchronous remote invocations 
-- this is necessary when data is transfered very fast from node to node in a stream non-deterministically
-- in order to keep the continuation of the calling node unchanged until the arrival of the response
-- since all the calls share a single continuation in the calling node when the session number is the same.
--
-- If there is no response from the remote node, the streaming is interrupted
--
-- > main= keep $ initNode $  onBrowser $  do
-- >  setSynchronous True
-- >  i  <- local $  threads 0 $ choose[1..10::Int]
-- >  localIO $ print ("1",i)
-- >  i' <- atRemote $ localIO $ print i >> return i
-- >  localIO $ print (i, i')
--
-- Without synchronous mode, all the 10 numbers are queued fast to be sent to the remote node and the callig node waits for responses. 
-- On arrival of the responses, i has the value 10. with synchronous mode, i == i'.
setSynchronous :: Bool -> Cloud ()
setSynchronous sync = onAll $ do
  modifyData' (\con -> con {synchronous = sync}) (error "setSynchronous: no connection data")
  return ()

-- set synchronous mode for remote calls within a cloud computation and also avoid unnecessary
-- thread creation
syncStream :: Cloud a -> Cloud a
syncStream proc = do
  sync <- local $ do
    Connection {synchronous = synchronous} <- modifyData' (\con -> con {synchronous = True}) err
    return synchronous
  Cloud $ threads 0 $ unCloud proc <*** modifyData' (\con -> con {synchronous = sync}) err
  where
    err = error "syncStream: no connection data"


-- | generates a new session id.
newSession :: TransIO BC.ByteString
newSession =  logged $ do
    newSession <- genSessionId
    setSession newSession
    return newSession
   
genSessionId =  BC.pack <$> replicateM 5 (randomRIO ('a', 'z'))

setSession :: BC.ByteString -> TransIO ()
setSession s= do
    ttr ("NEW SESSION", s)
    -- s <- logged $ return s'
    modifyData' (\prev@(PrevClos p mf l i c  :: PrevClos) -> 
                  case mf of
                    Just _  -> prev
                    Nothing -> PrevClos p  (Just $ SessionId s) l i c :: PrevClos)
                (error "genNewSession: no Previous closure")
    return()

getSession :: TransIO SessionId
getSession= do
 PrevClos dbprevclos mn _ isapp iscollect  :: PrevClos <- getData `onNothing` error "teleport: please use `initNode to perform distrubuted computing"
 return $ if isJust mn then fromJust mn else fst $ getSessClosure dbprevclos

{-|
  The 'teleport' function is an action in the 'Cloud' monad that
  facilitates the migration or transfer of the current transient
  computation to a different execution context, such as another node
  in a distributed system.

  This function abstracts the mechanics behind moving the execution
  state, allowing dynamic redistribution of workload in a multi-node
  environment. It encapsulates the necessary side effects required
  for this migration, ensuring a smooth transition between nodes.

  Use 'teleport' when you need to shift execution seamlessly, ensuring
  that computations can continue independently on a different host or
  environment without loss of state or context.

  The execution context migrates to the remote node opened by wormhole.
  A second teleport in the same wormhole brings back the execution to the original node. and so on
-}

refff= lazy $ newIORef 0
stopAt n = do
  r <- liftIO $ atomicModifyIORef refff $ \r ->(r+1,r)
  when (r>=n) $ exit ()

teleport :: Cloud ()
teleport =  do 
  modify $ \s -> s {execMode = if execMode s == Remote then Remote else Parallel}

  conn@Connection {idConn = idConn, connData = contype, synchronous = synchronous} <-
              getData
                `onNothing` error "teleport: No connection defined: use wormhole"
  tr ("connection",idConn,"teleport REMOTE NODE", calling conn, fmap  nodePort $ lazy $ readIORef $ remoteNode conn, idConn)
  log <- getLog
  -- case lazy $ readIORef contype of
  --    Just Self -> return ()
  --    _ -> onAll $ endpoint Nothing <|> guard (not $ recover log)
  -- tr ("after endpoint"
  -- create an endpoin and continue if is not in mode recover
  -- app <- gets isApplicative
  -- ttr ("teleport app",app)
  -- when (not app) $ 
    -- endpoint must be here even with applicative since it return the remote response of each remote app term
  onAll $ endpoint Nothing <|> guard (not $ recover log)
  -- In the called side of a replay, the closure to respond to is the closure with the name of the endpoint just
  -- created (the names of the endpoints are the same in all the nodes, since they depend on the position in the
  -- program). It can not be the one of the last message processed, which may belong to an inner level.
  when (recover log && not (calling conn)) $ onAll $ do
    PrevClos dbr _ _ _ _ :: PrevClos <- getData `onNothing` noExState "teleport"
    setState (ClosToRespond dbr)
  -- onAll $ stopAt 4

  -- let partlog= if app then [Fragment $ partLog log] else mempty
  local $ do

    -- executed in run mode and in recover mode when "e" is in the log
    -- notify to the calling teleport when no remaining threads are running in the remote node
    -- when (recover log && not (calling conn)) $ setNotifyFinishToCallingNode conn

    ttr ("teleport flags",case partLog log of mempty ->False; _ -> True , not $ recover log)
    when ( (not $ recover log)) $ do

        -- executed in run mode only
        -- In a called side recovered by a job, the connection of the state is not the one to the caller: it is
        -- a Self connection. The caller is in the closure of the first teleport (see 'localCaller').
        conn@Connection {idConn = idConn, connData = contype, synchronous = synchronous} <- calledConn conn
        ty <- liftIO $ readIORef contype
        case ty of
          -- when a node call itself, there is no need for socket communications
          Just Self -> do
            modify (\st -> st {execMode = Parallel})
            -- call himself
            tr "SELF"
            liftIO $ do
              remote <- readIORef $ remoteNode conn
              writeIORef (myNode conn) $ fromMaybe (error "teleport: no connection?") remote
          _ ->  do

            
            remoteClosDBRef <-
                do
                  cr@(ClosToRespond ref) <- tryState
                  ttr ("after ClosToRespond",ref)   -- it is the response to a previous teleport
                  -- stopAt 2
                  let (s,c) = getSessClosure ref
                  when (c== ClosureId "101503000") $ exit ()
                  delState cr
                  return ref
                
                <|> do
                  ttr ("getting closure for idConn",idConn)
                  ref <- getLastClosureForConnection idConn
                  ttr ("after getClosureForConnection",ref)   --new request to a node already called beforeSMore
                  return ref
                <|> do
                  ttr "return 0 0"
                  return dbClos0
                  


            PrevClos prevClosDBRef _ _ _ _ :: PrevClos<- getData `onNothing` noExState "teleport" 
            
            -- mc :: Maybe ConcurrentClosure <- getData
            -- when (isNothing mc) $ setLastClosureForConnection idConn prevClosDBRef

            ttr ("PREVCLOS",prevClosDBRef)
 
            prevlog <- noTrans $ getClosureLogFrom prevClosDBRef remoteClosDBRef
            -- log <- getLog
            {-
                prevlog es necesario para saber el fragmento a enviar edsde su lastclosure
                partLog es
            -}
            -- ttr ("PARTLOG", partlog)

            let tosend= prevlog   <> {- partlog <> -} [Fragment "e/"]  -- <-- "e/" since log was obtained  before  "local" which should inject "e/" in the log

            let (sessRemote,closRemote)= getSessClosure remoteClosDBRef
            let (idSession,clos) = getSessClosure prevClosDBRef

            -- onFinish $ const $ tr "TELEPORT ONFINISH"
            let msg=  SMore $ ClosureData closRemote sessRemote clos idSession tosend
            ttr ("msg to send",msg)
            msend conn $ toLazyByteString $ serialize msg
            -- the computation goes on in the other node, with its own jobs: the job of this one is finished
            finishJob
            -- setConcurrentClosure idConn 

            -- subsequent paquets sent to this remote closure will address this closure directly since it has been created
            -- updateLastClosureForConnection idConn prevClosDBRef

            -- In the called side, once the response has been sent nothing else must be executed here: the alternative
            -- computations (for example, the second term of an applicative) belong to the caller
            r <- abduce <|> do when (recover log || not (calling conn)) $ modify (\s -> s {execMode = Remote}); empty
            tr ("BEFORE EMPTY",r)
            empty

  


-- | A job is finished when a later job is executed ('Transient.Move.Job.job'). When the later job is in another node,
-- the job is finished when the call to that node has been sent without error: if this node is restarted, the
-- call is not repeated. If sending fails, the handler of 'Transient.Move.Job.job' writes the job again, to be retried
-- when the node recovers; so in an applicative the failure of any of its terms keeps the job.
--
-- The jobs of a 'Transient.Move.Job.jobTask' are not finished by a sending: they are finished when the task is completed.
finishJob :: TransIO ()
finishJob = do
  mjob <- getData :: TransIO (Maybe Job)
  forM_ mjob $ \j -> unless (jobScoped j) $ do
    ttr ("finishJob", j)
    liftIO $ atomically $ delDBRef (getDBRef $ keyResource j :: DBRef Job)
    delState j

-- | The connection to respond to. In a called side whose connection is a Self connection (the replay of a job
-- after a restart, which has no connection to the caller), it is opened to the node of the caller, stored in the closure
-- with the same key as the closure to respond to.
calledConn :: Connection -> TransIO Connection
calledConn c = do
  ty <- liftIO $ readIORef (connData c)
  mcr <- getData :: TransIO (Maybe ClosToRespond)
  case (ty, mcr) of
    (Just Self, Just (ClosToRespond ref)) | not (calling c) -> do
        mclos <- liftIO $ atomically $ readDBRef ref
        case mclos >>= localCaller of
          Just node -> do
            c' <- mconnect node
            let c'' = c' {calling = False}
            setData c''
            return c''
          Nothing -> return c
    _ -> return c

-- notify to the calling teleport when no remaining threads are running in the remote node
setNotifyFinishToCallingNode :: Connection -> TransIO ()
setNotifyFinishToCallingNode conn = do
    -- check if it is my node TODO
    mctr <- getData
    PrevClos prevClosDBRef _ _ _ _ :: PrevClos <- getData `onNothing` noExState "teleport" -- return (PrevClos  0 "0" False)

    case mctr of
      Nothing -> tr "NO CLOS TO RESPOND"
      Just (ClosToRespond ref) -> do
        tr ("SETTING ONFINISH for remote",ref)

        onFinish $ const $ do
          -- remove the EVar waiting for messages from the remote node
          -- PrevClos prevClosDBRef _ _<- getData `onNothing` error "teleport: no execution state" -- return (PrevClos  0 "0" False)
          tr ("ONFINISH IN TELEPORT",prevClosDBRef)

          -- lc <- liftIO $ atomically $ readDBRef prevClosDBRef `onNothing` error "teleport: no prevclos"
          -- tr ("prevClosDBRefs",prevClosDBRef)
          -- cleanEVar $ fromJust $ localEvar lc

          let (sessRemote,closRemote)= getSessClosure ref
          tr ("TRIGGERING  ONFINISH in teleport from to",prevClosDBRef,ref,"closremote=",closRemote)
          when (closRemote /= closureId0) $ do
            log <- getLog
            when (not $ recover log) $ do
              tr ("TELEPORT ONFINISH SEND TO",prevClosDBRef,ref, recover log)
              msend conn $ toLazyByteString $ serialize $ SLast $ ClosureData closRemote sessRemote closureId0 sessionId0 mempty


-- | forward exceptions back to the calling node
reportBack :: TransIO ()
reportBack = onException $ \(e :: SomeException) -> do
  conn <- getData `onNothing` error "reportBack: No connection defined: use wormhole"
  dbr <- getIndexData (idConn conn) `onNothing` error "teleport: no closRemote"
  node <- getMyNode
  -- clos <- liftIO $ atomically $ readDBRef dbr `onNothing` error "reportBack: no closRemote"
  let (sess,clos)= getSessClosure dbr
  let msg = SError $ toException $ ErrorCall $ show $ show $ CloudException node sess clos $ show e
  msend conn $ toLazyByteString $ serialize (msg :: StreamData NodeMSG) -- !> "MSEND"


-- | Set a state value in all the nodes participating in a cloud computation. This state data can be read and 
-- updated locally with other state primitives in each node, but only `setCloudState` set it in all the nodes
setCloudState :: Typeable b => b -> Cloud ()
setCloudState x = onAllDeep $ setState x
  -- modifyState' (\prevclos -> prevclos{preservePath=True}) $ noExState "setCloudState"
  -- onAll $ setState x


-- | execute a Transient action in each of the nodes connected.
--
-- The response of each node is received by the invoking node and processMessageed by the rest of the procedure.
-- By default, each response is processMessageed in a new thread. To restrict the number of threads
-- use the thread control primitives.
--
-- this snippet receive a message from each of the simulated nodes:
--
-- > main = keep $ do
-- >    let nodes= map createLocalNode [2000..2005]
-- >    addNodes nodes
-- >    (foldl (<|>) empty $ map listen nodes) <|> return ()
-- >
-- >    r <- clustered $ do
-- >               Connection (Just(PortNumber port, _, _, _)) _ <- getSData
-- >               return $ "hi from " ++ show port++ "\n"
-- >    liftIO $ putStrLn r
-- >    where
-- >    createLocalNode n= createNode "localhost" (PortNumber n)
clustered :: Loggable a => Cloud a -> Cloud a
clustered proc = foldNodes (<|>) empty proc

-- A variant of `clustered` that wait for all the responses and `mappend` them
mclustered :: (Monoid a, Loggable a) => Cloud a -> Cloud a
mclustered proc = foldNodes (<>) mempty proc


-- |   Applies a function to all the known nodes that share the same services, accumulating the results using a specified operator.
-- See `foldNodes'` for a detailed explanation

foldNodes :: (Loggable a1, Loggable a2) => (Cloud a2 -> Cloud a1 -> Cloud a1) -> Cloud a1 -> Cloud a2 -> Cloud a1
foldNodes op init proc = loggedc $ do
  nodes <- local getEqualNodes
  foldNodes' nodes op init proc

{- |
  Applies a function to a list of nodes, accumulating the results using a specified operator.

  The function 'proc' is applied to each node in the 'nodes' list using 'runAt', which executes the function in the context of the given node.
  The results of these applications are then accumulated using the binary operator 'op', starting with the initial value 'init'.
  The entire operation is wrapped in 'loggedc' to provide logging capabilities.

  @nodes@: A list of nodes to be processed.
  @op@: A binary operator used to accumulate the results.  It should take two arguments: the result of processing a node and the current accumulated value, and return the updated accumulated value.
  @init@: The initial value for the accumulation.
  @proc@: The action to be executed in each node.  Each result (if any) returned will be combined with the accumulated value using 'op'.

  Example:

  > foldNodes' [node1, node2, node3] (+) 0 $ do ...

  This example executes the do ... action in each node in the list '[node1, node2, node3]'.
  The results are then summed together, starting with an initial value of 0.
  The final result is the sum of the values returned by 'getValue' for each node.
  Following the design of Transient and the applicative operator wich is used in the definition of (+), no result will be returned by `foldNodes`
  until all the nodes return at least one result, and each new result of a node will return a new sum.

  > foldNodes' [node1, node2, node3] (<|>) 0 $ do ...

  In this other case, the alternative operator <|> dictates that each result will be returned individually. 
-}
foldNodes' :: (Loggable a1, Loggable a2) => [Node] -> (Cloud a2 -> Cloud a1 -> Cloud a1) -> Cloud a1 -> Cloud a2 -> Cloud a1
foldNodes' nodes op init proc = foldr (op . (`runAt` proc)) init nodes

-----
#ifndef BROWSER
-- reconnect if connection timed out
sendRawRecover con r =
  do
    c <- liftIO $ readIORef $ connData con
    ttr ("sendRawRecover",isJust c)

    con' <- case c of
      Nothing -> do
        tr "CLOSED CON"
        n <- liftIO $ readIORef $ remoteNode con
        case n of
          Nothing -> error "connection closed by caller"
          Just node -> do
            r <- mconnect' node
            return r
      Just _ -> return con
    sendRaw con' r  
   `whileException` \(SomeException e) -> do
              liftIO $ writeIORef (connData con) Nothing
              sendRawRecover con r


sendRaw con r = do
  tr ("SENDRAW---------->", fmap nodePort $ unsafePerformIO $ readIORef $ remoteNode con, idConn con,  r)

  let blocked = isBlocked con
  c <- liftIO $ readIORef $ connData con
  liftIO $
    modifyMVar_ blocked $
      const $ do
        ttr ("sendRaw")
        case c of
          Just (Node2Web sconn) -> liftIO $ WS.sendTextData sconn r
          Just (Node2Node _ sock _) ->do
            -- tr "NODE2NODE"
            SBS.sendMany sock (BL.toChunks r)
          Just (HTTP2Node _ sock _ _) ->
            SBS.sendMany sock (BL.toChunks r)
          Just (TLSNode2Node ctx) ->
            sendTLSData ctx r
          Just (HTTPS2Node ctx) ->
            sendTLSData ctx r
          _ ->  do
              n <-readIORef $ remoteNode con
              error $ "No connection stablished with " ++ show n
        TOD time _ <- getClockTime
        return $ Just time


#else
sendRaw con r= do
   c <- liftIO $ readIORef $ connData con
   case c of
      Just (Web2Node sconn) ->
              webSocketSend sconn (BS.unpack r)
      _ -> error "No connection stablished"


#endif


#ifndef BROWSER
-- | Find a live web connection for the given session, excluding 'conn'.
-- Returns 'Nothing' and cleans up the node if no live connection is found.
findLiveWebConn :: BC.ByteString -> Connection -> TransIO (Maybe Connection)
findLiveWebConn session conn = do
  ttr ("findliveconn", session)
  nodes <- getWebNodeForSession session
  case nodes of
    (webNode:_)
      | Just pool <- connection webNode -> do
          conns <- liftIO $ readMVar pool
          let alive c = do cd <- readIORef (connData c)
                           return $ case cd of
                             Just (HTTP2Node {})  -> True
                             Just (HTTPS2Node {}) -> True
                             _                     -> False
          mlive <- filterM (\c -> (idConn c /= idConn conn &&) <$> liftIO (alive c)) conns
          case mlive of
            (liveConn:_) -> return $ Just liveConn
            _ -> delNodes [webNode] >> return Nothing
      | otherwise -> delNodes [webNode] >> return Nothing
    _ -> return Nothing

-- | Ensure the connection is valid for web sending (HTTP2Node or HTTPS2Node).
-- If not (Self, Nothing), look up a live browser connection via the session ID
-- from PrevClos.
--
-- We prefer 'pnewSession' (mn) over 'getSessClosure prevDBRef' because during
-- log recovery 'execLog' sets prevDBRef to dbClos0 (the parent of the root
-- closure, key "0-0"), so getSessClosure would yield "0" and the lookup for
-- "httpnode-0" would fail.  pnewSession carries the real session ("qglzg") set
-- by execLog, so bids reach the browser even after a restart.
ensureWebConn :: Connection -> TransIO Connection
ensureWebConn  = return . id -- do
  -- cdata <- liftIO $ readIORef (connData conn)
  -- ttr ("ensureWebConn", lazy $ readIORef $ remoteNode conn, idConn conn, "connData", isJust cdata)

  -- case cdata of
  --   Just (HTTP2Node {})  -> return conn
  --   Just (HTTPS2Node {}) -> return conn
  --   _ -> do
  --     PrevClos dbr mn _ _ _ <- getData `onNothing` return emptyPrevClos
  --     let SessionId sid = fromMaybe (fst $ getSessClosure dbr) mn
  --     ttr ("ensureWebConn session", sid)
  --     if BC.null sid then return conn else do
  --       mlive <- findLiveWebConn sid conn
  --       case mlive of
  --         Just liveConn -> setState liveConn >> return liveConn
  --         Nothing       -> return conn
  -- where
  --   emptyPrevClos = PrevClos dbClos0 Nothing False False False

-- | Send on an HTTP2Node or HTTPS2Node connection.  When the send fails
-- because the browser closed the connection, find a live connection via
-- 'getNodes' (tagged by session ID) and 'continue' to retry.
webSend :: Connection -> BL.ByteString -> TransIO ()
webSend con bs = localExceptions $ do
  onException $ \(e :: IOException) -> do
    ttr ("msend: send failed, trying recovery", e)
    mnode <- liftIO $ readIORef (remoteNode con)
    case mnode of
      Just node | "httpnode-" `isPrefixOf` nodeHost node -> do
        let session = BC.drop 9 $ BC.pack $ nodeHost node
        mlive <- findLiveWebConn session con
        case mlive of
          Just liveConn -> do
            ttr ("msend: recovered, liveConn", idConn liveConn)
            setState liveConn
            continue
          Nothing -> return ()
      _ -> return ()
  conn' <- ensureWebConn con
  liveData <- liftIO $ readIORef (connData conn')
  ttr ("webSend----->",bs)
  case liveData of
    Just (HTTP2Node _ liveSock _ _) ->
      liftIO $ modifyMVar_ (isBlocked conn') $ const $ do
        tr "HTTP2NODE SEND"
        SBSL.sendAll liveSock $ bs
        TOD time _ <- getClockTime
        return $ Just time
    Just (HTTPS2Node liveCtx) ->
      liftIO $ modifyMVar_ (isBlocked conn') $ const $ do
        tr "HTTPS2NODE SEND"
        sendTLSData liveCtx $ bs
        TOD time _ <- getClockTime
        return $ Just time
    _ -> error "webSend: no HTTP/HTTPS connection"
#endif

-- | Send raw bytes over a connection. Dispatches on the connection type
-- (TLS, plain TCP, WebSocket, HTTP2Node, etc.) and handles keep-alive.
msend :: Connection -> BL.ByteString -> TransIO ()
#ifndef BROWSER

msend con bs = do
  ttr ("MSEND---------->", lazy $ readIORef $ remoteNode con, idConn con,  bs)
  c <- liftIO $ readIORef $ connData con
  con' <- case c of
    Nothing -> do
      tr "CLOSED CON"
      n <- liftIO $ readIORef $ remoteNode con
      case n of
        Nothing -> error "connection closed by caller"
        Just node -> do
          r <- mconnect node
          tr "after reconnect"
          return r

    Just _ -> return con
  let blocked = isBlocked con'
  c <- liftIO $ readIORef $ connData con'

  case c of
      Just (TLSNode2Node ctx) -> liftIO $ do
        modifyMVar_ blocked $
          const $ do
            tr "TLS SEND"
            sendTLSData ctx $ toLazyByteString $ int64Dec $ BS.length bs
            sendTLSData ctx bs
            TOD time _ <- getClockTime
            return $ Just time

      Just (Node2Node _ sock _) -> liftIO $ do
        modifyMVar_ blocked $
          const $ do
            let l = toLazyByteString $ int64Dec $ BS.length bs
            -- SBSL.send sock $ toLazyByteString $ int64Dec $ BS.length bs
            tr ("NODE2NODE SEND")
            SBSL.sendAll sock  $ l <> bs
            TOD time _ <- getClockTime
            return $ Just time

      -- Just (HTTP2Node {})  -> webSend con bs
      -- Just (HTTPS2Node {}) -> webSend con bs
      Just (HTTP2Node _ sock _ _) -> liftIO $ modifyMVar_ blocked (const $ do
            tr "HTTP2NODE SEND"
            SBSL.sendAll sock $ bs -- <> "\r\n"
            TOD time _ <- getClockTime
            return $ Just time)

      Just (HTTPS2Node ctx) -> liftIO $ modifyMVar_ blocked (const $ do
            tr "HTTPS2NODE SEND"
            sendTLSData ctx $ bs -- <> "\r\n"
            TOD time _ <- getClockTime
            return $ Just time)
      Just (Node2Web sconn) -> do
        tr "NODE2WEB"
        liftIO $ WS.sendTextData sconn bs
      Just Self -> return ()
      _ -> error "msend out of connection context: use wormhole to connect"

#else
msend con r= do
   ttr   ("MSEND --------->------>", r)

   let blocked= isBlocked con
   c <- liftIO $ readIORef $ connData con
   case c of
     Just (Web2Node sconn) -> liftIO $  do
              tr "MSEND BROWSER"
          --modifyMVar_ (isBlocked con) $ const $ do 
              let bs = toLazyByteString $ serialize r
              webSocketSend sconn (BS.unpack bs)   -- TODO OPTIMIZE THAT!
              tr "AFTER MSEND"
              --TOD time _ <- getClockTime
              --return $ Just time


     _ -> error "msend out of connection context: use wormhole to connect"
{-
msend (Connection _ _ remoten (Just (Web2Node sconn)) _ _ blocked _  _ _ _) r= liftIO $  do

  withMVar blocked $ const $ do -- JavaScript.Web.WebSocket.send (serialize r) sconn -- (JS.pack $ show r) sconn    !> "MSEND SOCKET"
      let bs = toLazyByteString $ serialize r
      JavaScript.Web.WebSocket.send  (toLazyByteString $ int64Dec $ BS.length bs) sconn
      JavaScript.Web.WebSocket.send bs sconn

-}

#endif


#ifdef BROWSER

mread con= do
   labelState "mread"
   sconn <- liftIO $ readIORef $ connData con
   case sconn of
    Just (Web2Node sconn) -> wsRead sconn
    Nothing               -> error "connection not opened"


--mread (Connection _ _ _ (Just (Web2Node sconn)) _ _ _ _  _ _ _)=  wsRead sconn


wsRead :: Loggable a => WebSocket  -> TransIO  a
wsRead ws= do
  text <- react (webSocketOnMessage ws) (return ())
  tr ("Browser webSocket read", text)  !> "<------<----<----<------"
  setParseString $ BS.pack text    -- TODO OPTIMIZE THAT
  deserialize


wsOpen :: String -> TransIO WebSocket
wsOpen url= do
   ws <-  liftIO $ webSocketNew url
   react (webSocketOnOpen ws) (return ())
   return ws


getWebServerNode :: TransIO Node
getWebServerNode = liftIO $ do
   h <- locationHostname
   p <- locationPort
   createNode h p


#else


mread conn=  do
  cc <- liftIO $ readIORef $ connData conn
  ttr (" mread REMOTE NODE", unsafePerformIO $ readIORef $ remoteNode conn, idConn conn )
  case cc of
    Nothing -> error "mread: connection empty"
    Just (Node2Node _ _ _) -> parallelReadHandler conn
    Just (TLSNode2Node _)  -> parallelReadHandler conn

receiveData' a b = NWS.receiveData b

--  parallel many, used for parsing
parMany p = do
  -- tr "parMany"
  -- modify $ \s -> s {execMode = Serial}
  d <- isDone
  tr ("parmany isdone",d)
  if d then empty else p <|> parMany p

-- | Read a stream of 'StreamData' packets from @conn@ in parallel, deserializing each one.
parallelReadHandler :: Loggable a => Connection -> TransIO (StreamData a)
parallelReadHandler conn = do
  -- onException $ \(e :: IOError) -> empty
  tr "parmany Extractpacket"
  parMany extractPacket
  where

    extractPacket = do
      -- s <- giveParseString
      -- sandbox $ do
      --   s <-tTake 3
      --   tr ("ttake",s)
      tr "EXTRACTPACKET"
      len <- int <|>  nomore
      tr ("extractPacket",len)

      tr ("LEN",len)
      str <- tTake (fromIntegral len)
      ttr ("MREAD  <-------<-------", lazy $ readIORef $ remoteNode conn, str)
      TOD t _ <- liftIO $ getClockTime
      liftIO $ modifyMVar_ (isBlocked conn) $ const $ Just <$> return t

      abduce
      setParseString str
      deserialize <|> (error $ show ("mread: BAD MESSAGE: error deserializing",  str))

    nomore = do
      s <- getParseBuffer
      if BS.null s
        then empty
        else do
            error $ show
              ("malformed data received: Int expected, received: ",  s)


getWebServerNode :: TransIO Node
getWebServerNode = getNodes >>= return . Prelude.head
#endif

-- | Close a connection, releasing the underlying socket/TLS context.
mclose :: MonadIO m => Connection -> m ()
#ifndef BROWSER

mclose con = do
  tr "mclose"
  --c <- liftIO $ readIORef $ connData con
  c <- liftIO $ atomicModifyIORef (connData con) $ \c -> (Nothing, c)

  case c of
    Just (TLSNode2Node ctx) -> liftIO $ withMVar (isBlocked con) $ const $ liftIO $ tlsClose ctx
    Just (HTTPS2Node ctx) -> do
      mnode <- liftIO $ readIORef $ remoteNode con
      let node = fromMaybe (error "mclose: no node") mnode
      delNodes [node]
      liftIO $ withMVar (isBlocked con) $ const $ liftIO $ tlsClose ctx
    Just (Node2Node _ sock _) -> liftIO $ withMVar (isBlocked con) $ const $ liftIO $ NS.close sock -- !> "SOCKET CLOSE"
    Just (Node2Web sconn) -> liftIO $ WS.sendClose sconn ("closemsg" :: BS.ByteString) -- !> "WEBSOCkET CLOSE"
    Just (HTTP2Node _ sock _ _) -> do
      mnode <- liftIO $ readIORef $ remoteNode con
      let node = fromMaybe (error "mclose: no node") mnode

      delNodes [node]
      liftIO $ withMVar (isBlocked con) $ const $ liftIO $ NS.close sock -- !> "SOCKET CLOSE"
    _ -> return ()
#else

mclose con= do
   c <- liftIO $ atomicModifyIORef (connData con) $ \c  -> (Nothing,c)
   case c of
     Just (Web2Node sconn)->
        liftIO $ webSocketClose sconn
#endif

#ifndef BROWSER
-- connection cookie
rcookie= unsafePerformIO $ newIORef $ BS.pack "cookie1"
#endif


{-# NOINLINE conSection #-}
conSection = unsafePerformIO $ newMVar ()

-- | Serialize the connections. The section is released whatever happens in @mx@: when it returns, when it stops
-- with @empty@ and when it fails with an exception (e.g. the connection is refused because the other node is down).
-- If it were not released, every later connection of the node would wait for ever.
exclusiveCon :: TransIO a -> TransIO a
exclusiveCon mx = do
  liftIO $ takeMVar conSection
  held <- liftIO $ newIORef True
  let release = liftIO $ do h <- atomicModifyIORef held (\h -> (False, h))
                            when h $ putMVar conSection ()
  r <- (onException (\(_ :: SomeException) -> release) >> mx) <|> (release >> empty)
  release
  return r

-- | Find the node (with its connection pool) in the global node list.
lookupNode :: MonadIO m => Node -> m  [Node]
lookupNode node= filter (== node) <$> getNodes

-- | Connect to @node@, reusing a cached connection from the pool when available.
mconnect' :: Node -> TransIO Connection
mconnect' node' = exclusiveCon $ do
  tr ("MCONNECT",node')
  conn <- do
    node <- fixNode node'
    nodes <- getNodes

    let fnode = filter (== node) nodes
    case fnode of
      [] -> mconnect1 node -- !> "NO NODE"
      (node'@(Node _ _ pool _) : _) -> do
        plist <- liftIO $ readMVar $ fromJust pool
        case plist of -- !>  ("length", length plist,nodePort node) of
          (handle : _) -> do
            c <- liftIO $ readIORef $ connData handle
            if isNothing c -- was closed by timeout
              then mconnect1 node
              else return handle
          -- !>  ("REUSED!", nodeHost node, nodePort node)
          _ -> do
            -- the registered node is used and it is not removed from the list (see 'mconnect')
            r <- mconnect1 node'
            -- tr "after mconnect1"
            return r

  setState conn

  return conn

lookupService x (Service s)= M.lookup x s

lookup2 key doubleList =
  let r = mapMaybe (lookupService key) doubleList
  in if null r then Nothing else Just $ head r

#ifndef BROWSER
-- effective connect trough different methods
mconnect1 (node@(Node host port _ services)) = do
  tr ("MCONNECT1",host,port,isTLSIncluded)
  {-
  onException $ \(ConnectionError msg node) -> do
              liftIO $ do
                  putStr  msg
                  putStr " connecting "
                  print node
              continue
              empty
     -}

  let types = mapMaybe (lookupService "type") services -- need to look in all services
  needTLS <-
    if "HTTP" `elem` types
      then return False
      else
        if "HTTPS" `elem` types
          then
            if not isTLSIncluded
              then error "no 'initTLS'. This is necessary for https connections. Please include it: main= do{ initTLS; keep ...."
              else return True
          else return isTLSIncluded
  -- case lookup "type" services  of
  --                  Just "HTTP" -> return False;
  --                  Just "HTTPS" ->
  --                         if not isTLSIncluded then error "no 'initTLS'. This is necessary for https connections. Please include it: main= do{ initTLS; keep ...."
  --                                              else return True
  --                  _ -> return isTLSIncluded

  -- tr ("NEED TLS", needTLS)
  (conn, parseContext) <-  --  fromJust <$> (connectNode2Node host port needTLS)
    checkSelf node
      <|> timeout1 1000000 (connectNode2Node host port needTLS)
      <|> timeout1 1000000 (connectWebSockets host port needTLS)
      <|> timeout1 1000000 (checkRelay needTLS)
      <|> throw (ConnectionError "no connection" node)

  -- tr "before end connection"

  setState conn

  modify $ \s -> s {execMode = Serial, parseContext = parseContext}

  -- "write node connected in the connection"
  liftIO $ writeIORef (remoteNode conn) $ Just node
  -- tr("MCONNECT",node)
  -- "write connection in the node"
  liftIO $ modifyMVar_ (fromJust $ connection node) . const $ return [conn]
  addNodes [node]


  return conn
  where
    checkSelf node = do
      -- tr "CHECKSELF"
      node' <- getMyNodeMaybe
      guard $ isJust (connection node')
      v <- liftIO $ readMVar (fromJust $ connection node') -- to force connection in case of calling a service of itself
      -- tr "IN CHECKSELF"
      if node /= node' || null v
        then empty
        else do
          conn <- case connection node of
            Nothing -> error "checkSelf error"
            Just ref -> do
              rnode <- liftIO $ newIORef node'
              cdata <- liftIO $ newIORef $ Just Self
              conn <- defConnection >>= \c -> return c {myNode = rnode, connData = cdata}
              liftIO $ withMVar ref $ const $ return [conn]
              return conn

          return (conn, noParseContext)


    timeout1 t proc = do
      r <- syncCollect 1 t proc
      case r of
        [] -> tr "TIMEOUT EMPTY" >> empty -- !> "TIMEOUT EMPTY"
        mr : _ -> case mr of
          Nothing -> throw $ ConnectionError "Bad cookie" node
          Just r -> return r

    checkRelay needTLS =
      case mapMaybe (lookupService "relay") (nodeServices node) of
      -- case lookup "relay" $ map head (nodeServices node) of
        [] -> empty -- !> "NO RELAY"
        (relayinfo:_) -> do
          let (h, p) = read relayinfo
          connectWebSockets1 h p ("/relay/" ++ h ++ "/" ++ show p ++ "/") needTLS

    connectSockTLS host (port :: Int) needTLS = do
      -- tr "connectSockTLS"

      let size = 8192
      c@Connection {myNode = my, connData = rcdata} <- getSData <|> defConnection
      -- tr "BEFORE HANDSHAKE"

      sock <- liftIO $ connectTo' size host $ show port
      let cdata = Node2Node undefined sock (error "addr: outgoing connection")
      cdata' <- liftIO $ readIORef rcdata

      --input <-  liftIO $ SBSL.getContents sock
      -- let pcontext= ParseContext (do mclose c; return SDone) input (unsafePerformIO $ newIORef False)

      pcontext <- makeParseContextFromStream $ SBSL.recv sock 4096

      conn' <-
        if isNothing cdata' -- lost connection, reconnect
          then do
            liftIO $ writeIORef rcdata $ Just cdata
            liftIO $ writeIORef (istream c) pcontext
            return c -- !> "RECONNECT"
          else do
            c <- defConnection
            rcdata' <- liftIO $ newIORef $ Just cdata
            liftIO $ writeIORef (istream c) pcontext

            return c {myNode = my, connData = rcdata'} -- !> "CONNECT"
      setData conn'

      --modify $ \s ->s{parseContext=ParseContext (do NS.close sock ; return SDone) input} --throw $ ConnectionError "connection closed" node) input}
      modify $ \s -> s {execMode = Serial, parseContext = pcontext}
      --modify $ \s ->s{execMode=Serial,parseContext=ParseContext (SMore . BL.fromStrict <$> recv sock 1000) mempty}
      -- tr "BEFORE HANDSHAKE1"
      when (isTLSIncluded && needTLS) $ maybeClientTLSHandshake host sock mempty
      -- tr "AFTER HNDSHAKE"

    connectNode2Node host port needTLS = localExceptions $ do
      onException $ \(e :: IOException) -> do

            liftIO $ System.IO.hPutStrLn  stderr $ "Connection error: Can not connect to "<> show host <> ":" <> show port <> ": " <> show e
            throw  $ ConnectionError (show e) node

      -- tr "NODE 2 NODE"
      mproxy <- getHTTProxyParams needTLS
      let (upass, h', p) = case (mproxy) of
            Just p -> p
            _ -> ("", BS.pack host, port)
          h = BS.unpack h'

      if isLocal host || h == host && p == port
        then connectSockTLS h p needTLS
        else do
          let connect =
                -- connect trough a proxy
                "CONNECT " <> pk host <> ":" <> pk (show port) <> " HTTP/1.1\r\n"
                  <> "Host: "
                  <> pk host
                  <> ":"
                  <> BS.pack (show port)
                  <> "\r\n"
                  <> "User-Agent: transient\r\n"
                  <> (if BS.null upass then "" else "Proxy-Authorization: Basic " <> (B64.encode upass) <> "\r\n")
                  <> "Proxy-Connection: Keep-Alive\r\n"
                  <> "\r\n"
          tr connect
          connectSockTLS h p False
          conn <- getSData <|> error "mconnect: no connection data"

          sendRaw conn connect
          first@(vers, code, _) <- getFirstLineResp -- tTakeUntilToken (BS.pack "\r\n\r\n")
          tr ("PROXY RESPONSE=", first)
          guard (BC.head code == '2')
            <|> do
              headers <- getHeaders
              Raw body <- parseBody headers
              error $ show (headers, body) --  decode the body and print
          when (isTLSIncluded && needTLS) $ do
            Just (Node2Node {socket = sock}) <- liftIO $ readIORef $ connData conn
            maybeClientTLSHandshake h sock mempty

      -- tr "after connectsocktls"
      conn <- getSData <|> error "mconnect: no connection data"

      --mynode <- getMyNode
      parseContext <- gets parseContext
      -- tr "CONNECTNODE2NODE"
      return $ Just (conn, parseContext)

    connectWebSockets host port needTLS = connectWebSockets1 host port "/" needTLS
    connectWebSockets1 host port verb needTLS = do
      -- onException $ \(e :: SomeException) -> empty
      tr "WEBSOCKETS"
      connectSockTLS host port needTLS -- a new connection
      never <- liftIO $ newEmptyMVar :: TransIO (MVar ())
      conn <- getSData <|> error "connectWebSockets: no connection"

      stream <- liftIO $ makeWSStreamFromConn conn
      co <- liftIO $ readIORef rcookie
      let hostport = host ++ (':' : show port)
          headers = [("cookie", "cookie=" <> BS.toStrict co)] -- if verb =="/" then [("Host",fromString hostport)] else []
      onException $ \(NWS.CloseRequest code msg) -> do
        -- conn <- getSData
        -- cleanConnectionData conn
        throw $ ConnectionError (BS.unpack msg) node
        empty

      wscon <-
        react
          ( NWS.runClientWithStream
              stream
              hostport
              verb
              WS.defaultConnectionOptions
              headers
          )
          (takeMVar never)

      msg <- liftIO $ WS.receiveData wscon
      tr "WS RECEIVED"
      case msg of
        ("OK" :: BS.ByteString) -> do
          tr "return connectWebSockets"
          cdata <- liftIO $ newIORef $ Just $ (Node2Web wscon)
          return $ Just (conn {connData = cdata}, noParseContext)
        _ -> do tr "RECEIVED CLOSE"; liftIO $ WS.sendClose wscon ("" :: BS.ByteString); return Nothing

-- | Return 'True' if @host@ refers to the local machine (localhost or a local interface IP).
isLocal :: String -> Bool
isLocal host =
  host == "localhost"
    || or
      ( map
          (flip isPrefixOf host)
          ["0.0", "10.", "100", "127", "169", "172", "192", "198", "203"]
      )
    || isAlphaNum (head host) && not ('.' `elem` host) -- is not a host address with dot inside: www.host.com

--  >>> isLocal "titan"
--  True
--
parseBody headers = r
 where
 r= case lookup "Transfer-Encoding" headers of
      Just "chunked" ->  dechunk |-  deserialize
      _ -> case fmap (read . BC.unpack) $ lookup "Content-Length" headers of
        Just length -> do
          msg <- tTake length
          tr ("parseBody: not chunked message", length)
          withParseString msg deserialize
        _ -> do
          str <- notParsed -- TODO: must be strict to avoid premature close
          BS.length str `seq` withParseString str deserialize


dechunk =
  do
    n <- numChars
    tr ("dechunk",n)
    if n == 0
      then do
         string "\r\n"
        --  tr "RETURN SDONE"
         return SDone
      else do
        r <- tTake $ fromIntegral n -- !> ("numChars",n)
        -- tr ("message", r)
        trycrlf
        tr ("SMORE1",r)
        return $ SMore r
    <|> return SDone -- !> "SDone in dechunk"
  where
    trycrlf = try (string "\r\n" >> return ()) <|> return ()
    numChars = do l <- hex; tDrop 2 >> return l

getFirstLineResp = do
  -- showNext "getFirstLineResp" 20
  (,,) <$> httpVers <*> (BS.toStrict <$> getCode) <*> getMessage
  where
    httpVers = tDropUntil (BS.isPrefixOf "HTTP") >> parseString
    getCode = parseString
    getMessage = tTakeUntilToken ("\r\n")

#else
-- the browser only connects to its web server, through a websocket
mconnect1 node@(Node host port pool _) = do
  conn <- getSData <|> error "mconnect: listen not set for this node"
  if host == "webnode"
    then do
      liftIO $ writeIORef (connData conn) $ Just Self
      return conn
    else do
      ws <- connectToWS host $ PortNumber $ fromIntegral port
      liftIO $ writeIORef (connData conn) $ Just (Web2Node ws)
      liftIO $ writeIORef (remoteNode conn) $ Just node
      liftIO $ modifyMVar_ (fromJust pool) . const $ return [conn]
      addNodes [node]
      return conn
#endif

-- check for cached connect, if not, it connects and check cookie with mconnect2
mconnect node' = exclusiveCon $ do
  node <- fixNode node'
  nodes <- getNodes

  let fnode = filter (== node) nodes
  case fnode of
    [] -> do
      r <- mconnect2 node --   !> "NO NODE"
      tr "after mconnect2"
      return r
    [node'@(Node _ _ pool _)] -> do
      plist <- liftIO $ readMVar $ fromJust pool
      case plist of -- !>  ("length", length plist,nodePort node) of
        (handle : _) -> do
          c <- liftIO $ readIORef $ connData handle
          if isNothing c -- was closed by timeout
            then do
              r <- mconnect2 node
              tr "after mconnect2 2"
              return r
            else return handle
        _ -> do
              -- tr "mconnect2 2"
              -- the registered node is used (it has the pool of connections): the node is not removed from the list
              -- while the connection is tried, since it may be down just now and the other threads of the program
              -- must not see a list of nodes without it
              r <- mconnect2 node'
              tr "after mconnect2 3"
              return r
  where
    -- connect and check for connection cookie among nodes
    mconnect2 node = do
      tr "MCONNECT2"
      conn <- mconnect1 node
      --  `catcht` \(e :: SomeException) -> empty
      cd <- liftIO $ readIORef $ connData conn
      case cd of
        Just Self -> return ()
#ifndef BROWSER
        Just (TLSNode2Node _) -> do
          checkCookie conn
          watchConnection conn node
        Just (Node2Node _ _ _) -> do
          checkCookie conn
          watchConnection conn node
#endif
        _ -> watchConnection conn node
      -- tr "before mconnect2 return"
      return conn
#ifndef BROWSER   
    checkCookie conn = do
      cookie <- liftIO $ readIORef rcookie
      mynode <- getMyNode
      sendRaw conn $
        "CLOS " <> cookie
          <> " b \r\nHost: " --" b \r\nField: value\r\n\r\n"  -- TODO put it standard: Set-Cookie:...
          <> BS.pack (nodeHost mynode)
          <> "\r\nPort: "
          <> BS.pack (show $ nodePort mynode)
          <> "\r\n\r\n"

      r <- liftIO $ readFrom conn
      ttr ("mconn received:",r)
      case r of
        "OK" -> return ()
        _ -> do
          let Connection {connData = rcdata} = conn
          cdata <- liftIO $ readIORef rcdata
          case cdata of
            Just (Node2Node _ s _) -> liftIO $ NS.close s -- since the HTTP firewall closes the connection
            Just (TLSNode2Node c) -> liftIO $ tlsClose c
          empty
#endif

    watchConnection conn node = do
      liftIO $ atomicModifyIORef connectionList $ \m -> (conn : m, ())

      parseContext <-
        gets parseContext ::  TransIO ParseContext
      chs <- liftIO $ newIORef M.empty

      let conn' = conn {closChildren = chs}

      -- tell listenResponses to watch incoming responses
      putMailbox ((conn', parseContext, node) :: (Connection, ParseContext, Node))
      ttr "AFTER PUTMAILBOX"
      liftIO $ threadDelay 100000 -- give time to initialize listenResponses
      -- tr "after watchConnection"


#ifndef BROWSER


-- | Open a TCP socket to @host@:@port@ with the given receive buffer size.
connectTo' :: Int -> NS.HostName -> NS.ServiceName -> IO NS.Socket
connectTo' bufSize host port = do
  -- tr ("HOSTPORT", host, port)
  addr <- resolve
  open addr
  where
    resolve = do
      let hints = NS.defaultHints {NS.addrSocketType = NS.Stream}
      head <$> NS.getAddrInfo (Just hints) (Just host) (Just port)
    open addr = bracketOnError (NS.openSocket addr) NS.close $ \sock -> do
      NS.setSocketOption sock NS.RecvBuffer bufSize
      NS.setSocketOption sock NS.SendBuffer bufSize
      NS.setSocketOption sock NS.ReuseAddr  10

      NS.connect sock $ NS.addrAddress addr
      return (sock :: NS.Socket)
#else
connectToWS  h (PortNumber p) = do
   protocol <- liftIO locationProtocol
   pathname <- liftIO locationPathname
   tr ("PAHT",pathname)
   let ps = case protocol of "http:" -> "ws://"; "https:" -> "wss://"
   wsOpen $ ps++ h++ ":"++ show p ++ pathname
#endif


-- | Global list of open outgoing connections (used for cleanup on shutdown).
connectionList :: IORef [Connection]
connectionList = unsafePerformIO $ newIORef []



noParseContext =
  let err = error "parseContext not set"
   in ParseContext err err err

-- #ifndef BROWSER
instance Default Connection where def= lazy defConnection


-- | Build a minimal default 'Connection' for a Self (in-process) endpoint.
defConnection :: MonadIO m => m Connection
defConnection = do
  idc <-   genPersistId
  tr ("DEFCONNECTION",idc)
  liftIO $ do
    my <- createNode "localhost" 0 >>= newIORef
    x <- newMVar Nothing
    --y <- newMVar M.empty
    ref <- newIORef Nothing
    z <- newIORef M.empty
    noconn <- newIORef Nothing
    np <- newIORef noParseContext
    -- whls <- newIORef []
    return $
      Connection
        (fromIntegral idc)
        my
        ref
        noconn
        np
        8192
        x
        False
        False
        z

#ifndef BROWSER

-- | Override the receive buffer size for the current connection (default 8192 bytes).
setBuffSize :: Int -> TransIO ()
setBuffSize size = do
  conn <- getData `onNothing` defConnection -- !> "DEFF3")
  setData $ conn {bufferSize = size}

getBuffSize =
  (do getSData >>= return . bufferSize) <|> return 8192

-- | Setup the node to start listening for incoming connections.
listen :: Node -> TransIO ()
listen node@(Node _ port _ _) =  do
  labelState "listen"

  -- onException $ \(ConnectionError msg node) -> empty

  --addThreads 2
  -- fork connectionTimeouts
  --  fork loopClosures

  putLog emptyLog

  conn' <- tryState <|> defConnection
  chs <- liftIO $ newIORef M.empty
  cdata <- liftIO $ newIORef $ Just Self
  --  loc   <- liftIO $ newMVar M.empty
  let conn = conn' {connData = cdata, closChildren = chs} --,localClosures=loc}
  pool <- liftIO $ newMVar [conn]

  let node' = node {connection = Just pool}
  liftIO $ writeIORef (myNode conn) node'
  setData conn

  -- onException $ \(e :: SomeException) -> do  -- msend conn $ BS.pack $ show e ; empty
  --   -- cdata <- liftIO $ readIORef $ connData conn 
  --   tr "ONEXcepTION1"
  --   msend conn $ chunked "404: not found" <> endChunk
  --   -- case cdata of 
  --   --   Just(HTTP2Node _ _ _ _) -> msend conn $ "\r\n" <> chunked "404: not found" <> endChunk
  --   --   Just (HTTPS2Node _)     -> msend conn $ "\r\n" <> chunked "404: not found" <> endChunk
  --   --   _ -> msend conn $ BS.pack $ show e
  --   empty

  liftIO $ modifyMVar_ (fromJust $ connection node') $ const $ return [conn]

  addNodes [node']
  setRState (JobGroup M.empty) --used by resetRemote
  -- ex <- exceptionPoint :: TransIO (BackPoint SomeException)
  -- setData ex

  onException $ \(e :: SomeException) -> tttr e

  mlog <-  listenNew (show port) conn <|> listenResponses :: TransIO (StreamData NodeMSG)
  execLog mlog


chunked tosend= do
    let l= fromIntegral $ BS.length tosend
    toHex l <> "\r\n" <> tosend <> "\r\n"

endChunk= "0\r\n\r\n"

toHex 0 = mempty
toHex l =
  let (q, r) = quotRem l 16
    in toHex q <> (BS.singleton $ if r <= 9 then toEnum (fromEnum '0' + r) else toEnum (fromEnum 'A' + r -10))

-- | Bind and listen on @port@, returning the server socket.
listenOn :: NS.ServiceName -> IO NS.Socket
listenOn port = do
  addr <- resolve
  open addr
  where
    resolve = do
      let hints = NS.defaultHints {NS.addrFlags = [NS.AI_PASSIVE], NS.addrSocketType = NS.Stream}
      head <$> NS.getAddrInfo (Just hints) Nothing (Just port)
    open addr = bracketOnError (NS.openSocket addr) NS.close $ \sock -> do
      NS.setSocketOption sock NS.ReuseAddr 1
      NS.withFdSocket sock NS.setCloseOnExecIfNeeded
      NS.bind sock $ NS.addrAddress addr
      NS.listen sock 1024
      return sock

-- | Accept incoming connections on @port@, wrapping each in an HTTP\/WebSocket
-- connection and dispatching packets to 'execLog' via the Transient mailbox.
listenNew port conn' = do
  sock <- liftIO $ listenOn port

  tr "LISTEN ON"
  liftIO $ do
    let bufSize = bufferSize conn'
    NS.setSocketOption sock NS.RecvBuffer bufSize
    NS.setSocketOption sock NS.SendBuffer bufSize

  -- wait for connections. One thread per connection
  liftIO $ do putStr "Connected to port: "; print port

  -- onException $ \(e :: SomeException) -> empty -- do get >>= liftIO . killBranch; empty

  (sock, addr) <- waitEvents $ NS.accept sock
  ttr ("NEW EVENT",addr)
  onException $ \e ->
    if  isResourceVanishedError e
       then do liftIO $ NS.close sock; empty
       else backtrack
  tr ("LISTENNEW",addr)

  chs <- liftIO $ newIORef M.empty

  noNode <- liftIO $ newIORef Nothing
  id1 <- genPersistId
  tr ("idConn-->", id1)
  let conn = conn' {idConn = fromIntegral id1, closChildren = chs, remoteNode = noNode {-,localClosures=cls-}}

  input <- liftIO $ SBSL.getContents sock
  -- tr "INPUT"
  let nod = unsafePerformIO $ liftIO $ createNode "incoming connection" 0
   in modify $ \s ->
        s{ execMode = Serial,
            parseContext =
               ParseContext

                  (return SDone) --(do liftIO $ NS.close sock;return SDone) -- throw (ConnectionError "connection closed" nod))
                  input
                  (unsafePerformIO $ newIORef True) :: ParseContext

          }


  cdata <- liftIO $ newIORef $ Just (Node2Node port sock addr)
  let conn' = conn {connData = cdata}

  liftIO $ modifyMVar_ (isBlocked conn) $ const $ return Nothing -- Just <$> return t
  setState conn'
  liftIO $ atomicModifyIORef connectionList $ \m -> (conn' : m, ()) -- TODO
  maybeTLSServerHandshake sock input
  -- tr "AFTER HANDSHAKE"

  firstLine@(method, uri, vers) <- getFirstLine
  headers <- getHeaders

  case (method, uri) of
    ("CLOS", hisCookie) -> do
      conn <- getSData
      let host = BC.unpack $ fromMaybe (error "no host in header") $ lookup "Host" headers
          port = read $ BC.unpack $ fromMaybe (error "no port in header") $ lookup "Port" headers
      remNode' <- liftIO $ createNode host port
      tr ("Connection received from", remNode')

      rc <- liftIO $ newMVar [conn]
      let remNode = remNode' {connection = Just rc}

      liftIO $ writeIORef (remoteNode conn) $ Just remNode
      tr ("ADDED NODE", remNode)
      addNodes [remNode]

      myCookie <- liftIO $ readIORef rcookie
      tr (myCookie,hisCookie)
      if BS.toStrict myCookie /= hisCookie
        then do
          sendRaw conn "NOK"
          mclose conn
          error "connection attempt with bad cookie"
        else do
          tr "sending OK"
          sendRaw conn "OK" --    !> "CLOS detected"
          tr ("listenNew REMOTE NODE", unsafePerformIO $ readIORef $ remoteNode conn, idConn conn )

          -- when the other node closes the connection (it fell), the reader finishes: the connection is marked as
          -- closed, so that the next 'msend' reconnects instead of writing to a dead socket, where the write succeeds
          -- and the message is lost
          mread conn <|> (mclose conn >> empty)
    _ -> do
      -- it is a HTTP request
      -- processMessage the current request in his own thread and then (<|>) any other request that arrive in the same connection
      -- first@(method,uri, vers) <-cutBody firstLine headers <|> parMany cutHTTPRequest

      -- all requests are parsed here
      
      httpHeaders@(HTTPHeaders (first@(method,uri, vers)) headers) <- cutBody firstLine headers  <|>   (parMany  cutHTTPRequest)
      tr ("NEW REQUEST",httpHeaders)
      setState httpHeaders
      

      let uri' = BC.tail $ uriPath uri -- !> uriPath uri
      -- tr ("uri'", uri')


      case BC.span (/= '/') uri' of
        ("api", _) -> do
          let log = "e/" <> (lazyByteString method <> byteString "/" <> byteString (BC.drop 4 uri'))

          maybeSetHost headers
          -- tr ("HEADERS", headers)
          str <- giveParseString <|> error "no api data"
          if lookup "Transfer-Encoding" headers == Just "chunked"
            then error $ "chunked not supported"
            else do
              len <-
                ( read <$> BC.unpack
                    <$> (transient $ return (lookup "Content-Length" headers))
                  )
                  <|> return 0
              log' <- case lookup "Content-Type" headers of
                Just "application/json" -> do
                  let toDecode = BS.take len str
                  -- tr ("TO DECODE", log <> lazyByteString toDecode)

                  setParseString $ BS.take len str
                  return $ log <> "/" <> lazyByteString toDecode -- [(Var $ IDynamic json)]    -- TODO hande this serialization
                Just "application/x-www-form-urlencoded" -> do
                  -- tr ("POST HEADERS=", BS.take len str)

                  setParseString $ BS.take len str
                  return $ log <> lazyByteString (BS.take len str) 
                Just x -> do
                  -- tr ("POST HEADERS=", BS.take len str)
                  let str = BS.take len str
                  return $ log <> lazyByteString str 
                _ -> return $ log
              --  let build= toPath log'
              setParseString $ toLazyByteString log'
              ttr "CLOSUREDATA"
              return $ SMore $ ClosureData closureId0 sessionId0 closureId0 sessionId0 $ [Fragment $ fixed log'] -- [[log']] 

        ("relay", _) -> proxy sock method vers uri'

        (h, rest) -> do
          if BC.null h || h == "file" || h =="index.html"
            then do
              --headers <- getHeaders
              maybeSetHost headers
              let uri = if BC.null h || BC.null rest then uri' else BC.tail rest
              tr (method, uri)
              -- stay serving pages until a websocket request is received
              servePage (method, uri, headers)

              -- when servePage finish, is because a websocket request has arrived
              conn <- getSData
              sconn <- makeWebsocketConnection conn uri headers

              -- websockets mode
              -- para qué reiniciarlo todo????
              rem <- liftIO $ newIORef Nothing
              chs <- liftIO $ newIORef M.empty
              cls <- liftIO $ newMVar M.empty
              cme <- liftIO $ newIORef M.empty
              cdata <- liftIO $ newIORef $ Just (Node2Web sconn)
              let conn' =
                    conn
                      { connData = cdata,
                        closChildren = chs {-,localClosures=cls-},
                        remoteNode = rem --,comEvent=cme}
                      }
              setState conn' -- !> "WEBSOCKETS CONNECTION"
              co <- liftIO $ readIORef rcookie

              let receivedCookie = lookup "cookie" headers

              tr ("cookie", receivedCookie)
              recvcookie <- case receivedCookie of
                Just str ->
                  Just <$> do
                    withParseString (BS.fromStrict str) $ do
                      tDropUntilToken "cookie="
                      tTakeWhile (not . isSpace)
                Nothing -> return Nothing
              tr ("RCOOKIE", recvcookie)
              if recvcookie /= Nothing && recvcookie /= Just co
                then do
                  node <- getMyNode
                  --let msg= SError $ toException $ ErrorCall $  show $ show $ CloudException node 0 $ show $ ConnectionError "bad cookie" node
                  tr "SENDINg"

                  liftIO $ WS.sendClose sconn ("Bad Cookie" :: BS.ByteString) -- !> "SendClose Bad cookie"
                  empty
                else do
                  liftIO $ WS.sendTextData sconn ("OK" :: BS.ByteString)

                  -- a void message is sent to the application signaling the beginning of a connection
                  -- async (return (SMore $ ClosureData 0 0[Exec])) <|> do

                  tr "WEBSOCKET"
                  --  onException $ \(e :: SomeException) -> do
                  --     liftIO $ putStr "listen websocket:" >> print e
                  --     -- liftIO $ mclose conn'
                  --     -- killBranch
                  --     -- empty

                  s <- waitEvents $ receiveData' conn' sconn :: TransIO BS.ByteString
                  setParseString s
                  ttr ("WEBSOCKET RECEIVED <-----------", s)
                  -- integer
                  deserialize
                    -- a void message is sent to the application signaling the beginning of a connection
                    <|> (return $ SMore (ClosureData closureId0 sessionId0 closureId0 sessionId0 [Fragment $ exec <> fixed (lazyByteString s)]))
            else do
              -- let uri'' = if not $ isNumber $ BS.head uri'
              --               then
              --                  M.lookup uri' rpaths
              --               else uri'
              let uriparsed = BS.pack $ unEscapeString $ BC.unpack uri'

              body <- if method == "POST" then   "/" <> giveParseString else return mempty
              tr ("BODY",body)
              setParseString $ uriparsed  <> body

              -- we are receiving, not sending. In this case remoteClosure is my closure addressed by the request
              ttr ("URI PARSED", uriparsed)
              remoteClosure <- BL.toStrict <$> tTakeWhile' (\c -> c /= '/' && c /= '\n') 
              ttr ("REMOTECLOSURE",remoteClosure)

              -- for different formats of URLs
              (s1 :: BC.ByteString,thisClosure :: BC.ByteString, s2 :: BC.ByteString ) 
                   <- try allParClosParams <|>  shortWithIdParam <|> shortClosParams body <|> noparams remoteClosure <|> return("0","0","0")


              tr (s1, uri, uri', uriparsed, remoteClosure, s2, thisClosure)

              --cdata <- liftIO $ newIORef $ Just (HTTP2Node (PortNumber port) sock addr)
              conn <- getSData
              liftIO $
                atomicModifyIORef' (connData conn) $ \cdata -> case cdata of
                  Just (Node2Node port _ addr) -> (Just $ HTTP2Node port sock addr httpHeaders, ())
                  Just (HTTP2Node port _ addr _) -> (Just $ HTTP2Node port sock addr httpHeaders, ())
                  Just (TLSNode2Node ctx) -> (Just $ HTTPS2Node ctx, ())
                  Just (HTTPS2Node ctx) -> (Just $ HTTPS2Node ctx, ())
                  _ -> error $ "line 2258: " <> show cdata
              let name= "httpnode-" <> BC.unpack(if '#'  == BC.head s1
                   then BC.tail $ BC.dropWhile (/= '-')s1
                   else s1)
              ttr ("WEBNODE",name)
              -- 2026-06-06: pool merging via addNodes is sufficient.
              -- Previous explicit pool manipulation kept as reference:
              --   existing <- lookupNode nodeBase
              --   pool <- case existing of
              --     (n:_) | Just p <- connection n -> do
              --       liftIO $ modifyMVar_ p $ return . (conn :)
              --       return p
              --     _ -> liftIO $ newMVar [conn]
              --   let node = nodeBase{connection = Just pool}
              pool <- liftIO $ newMVar [conn]
              let node = Node name 0 (Just pool) [Service $ M.fromList [("httpnode", "")]]
              addNodes [node]
              putMailbox (Ping node)
              liftIO $ writeIORef (remoteNode conn) $ Just node

              requestString <- giveParseString

              


              ttr ("SENDING RESPONSE HEADERS to sock", sock, "idConn", idConn conn)
              liftIO $ SBSL.sendAll sock $ "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n"
              ttr ("string to parse", requestString)
              return $ SMore $ ClosureData (ClosureId remoteClosure)  (SessionId s1)  (ClosureId thisClosure)  (SessionId s2)  [Fragment $ fixed $ lazyByteString requestString]
  where

    noparams clos= do  -- example"http://localhost:8080/init"
      ttr "NOPARAMS"
      ms1 <-getCookie "state"
      guard (isJust ms1)
      let s1 = fromJust ms1
      ttr("NOPARAMS",(s1,"0","0"))
      return (s1,"0","0")
   

    -- shortClosParams :: TransIO (BC.ByteString,BC.ByteString,BC.ByteString)
    shortClosParams body= do  -- example -- example"http://localhost:8080/init/Sdfdef"
        ttr "SHORTCLOSPARAMS"
        tChar 'S'
        s1' <-   deserialize 
        tChar '/'  <|> return '/'  
        
        ms1 <-getCookie "state"
        let s1 = BC.cons '#' s1' <> BC.cons '-' (fromMaybe "0" ms1)

        return (s1,"0","0")

    shortWithIdParam = do
        tChar 'T'
        s1 <-  deserialize   -- :: TransIO SessionId
        -- s <- giveParseString
        -- setParseString $ BS.tail s -- add a extra parameter sessionid for minput
        tr "SHORTWITH PARAM"
        return (s1,"0","0")

    allParClosParams= do
      -- liftIO $ print "allParClosParams"
      s1 <- deserialize
      tChar '/'
      thisClosure <-  BL.toStrict <$> tTakeWhile' (/= '/')
      s2 <- deserialize
      tChar '/'
      return (s1,thisClosure,s2)

    cutHTTPRequest = do
      -- tr "cutHTTPRequest"
      first@(method, _, _) <- getFirstLine
      tr ("first",first)
      -- tr ("after getfirstLine", method, uri, vers)
      headers <- getHeaders
      -- setState $ HTTPHeaders first headers
      cutBody first headers

    cutBody (first@(method, _, _)) (headers :: NWS.Headers) = do
      -- tr "cutBody"
      let ret=  HTTPHeaders first headers
      -- tr("headers",headers)
      if method == "POST"
        then case fmap (read . BC.unpack) $ lookup "Content-Length" headers of
          Nothing -> return ret -- most likely chunked encoding, processed in the same thread
          Just len -> do
            str <- tTake (fromIntegral len)
            tr ("LEN",len,"body",str)

            abduce                              -- new thread
            setParseString str                  -- set the parse string
            return ret
        else do
          abduce
          return ret

    uriPath = BC.dropWhile (/= '/')
    split [] = []
    split ('/' : r) = split r
    split s =
      let (h, t) = Prelude.span (/= '/') s
       in h : split t

    -- reverse proxy for urls that look like http://host:port/relay/otherhost/otherport/
    proxy sclient method vers uri' = do
      let (host : port : _) = split $ BC.unpack $ BC.drop 6 uri'
      tr ("RELAY TO", host, port)
      --liftIO $ threadDelay 1000000
      sserver <- liftIO $ connectTo' 4096 host port
      tr "CONNECTED"
      rawHeaders <- getRawHeaders
      tr ("RAWHEADERS", rawHeaders)
      let uri = BS.fromStrict $ let d x = BC.tail $ BC.dropWhile (/= '/') x in d . d $ d uri'

      let sent =
            method <> BS.pack " /"
              <> uri
              <> BS.cons ' ' vers
              <> BS.pack "\r\n"
              <> rawHeaders
              <> BS.pack "\r\n\r\n"
      tr ("SENT", sent)
      liftIO $ SBSL.send sserver sent
      -- Connection{connData=Just (Node2Node _ sclient _)} <- tryState <|> error "proxy: no connection"

      (send sclient sserver <|> send sserver sclient)
        `catcht` \(e :: SomeException) -> liftIO $ do
          putStr "Proxy: " >> print e
          NS.close sserver
          NS.close sclient
          empty

      empty
      where
        send f t = async $ mapData f t
        mapData from to = do
          content <- recv from 4096
          tr (" proxy received ", content)
          if not $ BC.null content
            then sendAll to content >> mapData from to
            else finish
          where
            finish = NS.close from >> NS.close to
    -- throw $ Finish "finish"

    maybeSetHost headers = do
      setHost <- liftIO $ readIORef rsetHost
      when setHost $ do
        mnode <- liftIO $ do
          let mhost = lookup "Host" headers
          case mhost of
            Nothing -> return Nothing
            Just host -> atomically $ do
              -- set the first node (local node) as is called from outside
              nodes <- readTVar nodeList
              let (host1, port) = BC.span (/= ':') host
                  hostnode =
                    (Prelude.head nodes)
                      { nodeHost = BC.unpack host1,
                        nodePort =
                          if BC.null port
                            then 80
                            else read $ BC.unpack $ BC.tail port
                      }
              writeTVar nodeList $ hostnode : Prelude.tail nodes
              return $ Just hostnode -- !> (host1,port)
        when (isJust mnode) $ do
          conn <- tryState
          liftIO $ writeIORef (myNode conn) $ fromJust mnode
        liftIO $ writeIORef rsetHost False -- !> "HOSt SET"

rcookies= unsafePerformIO $ newIORef []  -- HTTP cookies

header200Chunked= BS.pack "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n"

header404Chunked= BS.pack "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n"

{-# NOINLINE rsetHost #-}
rsetHost = unsafePerformIO $ newIORef True

-- | filter out HTTP requests
noHTTP = onAll $ do
  conn <- tryState
  cdata <- liftIO $ readIORef $ connData conn
  case cdata of
    Just (HTTPS2Node ctx) -> do
      liftIO $ sendTLSData ctx $ "HTTP/1.1 403 Forbidden\r\nConnection: close\r\nContent-Length: 11\r\n\r\nForbidden\r\n"
      liftIO $ tlsClose ctx
      empty
    Just (HTTP2Node _ sock  _ _) -> do
      liftIO $ SBSL.sendAll sock $ "HTTP/1.1 403 Forbidden\r\nConnection: close\r\nContent-Length: 11\r\n\r\nForbidden\r\n"
      liftIO $ NS.close sock
      empty
    _ -> return ()

#endif

-- | Read a stream of 'StreamData' responses from a remote node connection
-- established via ' or 'mconnect'.
listenResponses :: Loggable a => TransIO (StreamData a)
listenResponses = do
  labelState "listen responses"
  (conn, parsecontext, node) <- getMailbox :: TransIO (Connection, ParseContext, Node)
  abduce
  tr ("LISTEN from", node)
  labelState . fromString $ "listen from: " ++ show node
  setData conn

  modify $ \s -> s {execMode = Serial, parseContext = parsecontext}


  -- cutExceptions
  --     onException $ \(e:: SomeException) -> do
  --          liftIO $ putStr "ListenResponses: " >> print e
  --          liftIO $ putStr "removing node: " >> print node
  --          nodes <- getNodes
  --          setNodes $ nodes \\ [node]
  --          --  topState >>= showThreads
  --          killChilds
  --          let Connection{localClosures=localClosures}= conn
  --          liftIO $ modifyMVar_ localClosures $ const $ return M.empty
  --          empty

  mread conn


-- | if there is a remote job  identified by th string identifier, it stop that job, and set the
-- current remote operation (if any) as the current remote job for this identifier.
-- The purpose is to have a single remote job.
--  to identify the remote job, it should be used after the `wormhole` and before the remote call:
--
-- > r <- wormhole node $ do
-- >        stopRemoteJob "streamlog"
-- >        atRemote myRemotejob
--
-- So:
--
-- > runAtUnique ident node job= wormhole node $ do stopRemoteJob ident; atRemote job

-- This program receive a stream of "hello" from a second node when the option "hello" is entered in the keyboard
-- If you enter  "world", the "hello" stream from the second node
-- will stop and will print an stream of "world" from a third node:
-- Entering "hello" again will stream "hello" again from the second node and so on:

-- > main= keep $ initNode $ inputNodes <|> do
-- >
-- >     local $ option "init" "init"
-- >     nodes <- local getNodes
-- >     r <- proc (nodes !! 1) "hello" <|> proc (nodes !! 2) "world"
-- >     localIO $ print r
-- >     return ()
-- >
-- > proc node par = do
-- >   v <- local $ option par par
-- >   runAtUnique "name" node $ local $ do
-- >    abduce
-- >    r <- threads 0 $ choose $ repeat v
-- >    liftIO $ threadDelay 1000000
-- >    return r

-- the nodes could be started from the command line as such in different terminals:

-- > program -p start/localhost/8000
-- > program -p start/localhost/8002
-- > program -p start/localhost/8001/add/localhost/8000/n/add/localhost/8002/n/init

-- The third is the one wich has the other two connected and can execute the two options.

stopRemoteJob :: BC.ByteString -> Cloud ()

instance Loggable Closure

stopRemoteJob ident = do
  resetRemote ident

  local $ do
    conn <- getData `onNothing` error "stopRemoteJob: Connection not set, use wormhole"

    (_, closr) <- getSessClosure <$> getIndexData (idConn conn) `onNothing` error "stopRemoteJob: Connection not set, use wormhole"
    remote <- liftIO $ readIORef $ remoteNode conn
    return (remote, closr)

    JobGroup map <- getRState <|> return (JobGroup M.empty)
    setRState $ JobGroup $ M.insert ident (fromJust remote, closr) map

-- | kill the remote job. Usually, before starting a new one.
resetRemote :: BC.ByteString -> Cloud ()
resetRemote ident = do
  mj <- local $ do
    JobGroup map <- getRState <|> return (JobGroup M.empty)
    return $ M.lookup ident map

  when (isJust mj) $ do
    let (remote, closr) = fromJust mj
    --do   -- when (closr /= 0) $ do
    runAt remote $
      local $ do
        PrevClos {prevDBRef= ref} <- tryState <|> error "resetRemote: no state"
        -- mcont <- liftIO $ modifyMVar localClosures $ \map -> return ( M.delete closr map,  M.lookup closr map)
        mlc <- liftIO $ atomically $ readDBRef ref
        let mcont = fmap localCont mlc
        case mcont of
          Nothing -> error $ "closure not found: " ++ show closr
          Just Nothing -> error $ "closure not found: " ++ show closr
          Just (Just cont) -> do
            -- topState >>= showThreads
            liftIO $ killBranch cont
            return ()

-- | Dispatch an incoming 'NodeMSG' packet: route it to the matching closure,
-- handle errors and stream termination, or resume a waiting 'receive1' call.
execLog :: StreamData NodeMSG -> TransIO ()
execLog mlog = transient $ do
  tr "EXECLOG"
  -- tr("execLog",mlog)
  st <- get
  -- tr ("execlog", threadId $ fromJust $ unsafePerformIO $ readIORef $ parent st)
  case mlog of
    SError e -> do
      tr ("SERROR", e)
      case fromException e of
        Just (ErrorCall str) -> do
          case read str of
            e@(CloudException _ s1 closl err) -> do
              processMessage s1 closl (error "session: should not be used") (error "closr: should not be used") (Left e) True
    SDone -> runTrans (back $ ErrorCall "SDone") >> return Nothing -- TODO remove closure?
    SMore (ClosureData closl s1 closr s2 log) -> processCommMessage s1 closl  s2 closr (Right log) False
    SLast (ClosureData closl s1 closr s2 log) -> processCommMessage s1 closl  s2 closr (Right log) True
  where
  processCommMessage ::   SessionId -> ClosureId -> SessionId -> ClosureId -> Either CloudException [FragmentType] -> Bool -> StateIO (Maybe ())
  processCommMessage  s1 closl s2 closr log bool= do
    -- conn <- getData `onNothing` error ("execLog: " <> "no connection")
    -- mode <- gets execMode
    -- ttr ("MODE",mode)
    -- if mode == Applicative then set la closure de envio else esta, de recepcion
    -- como se sabe la closure del envio?
    -- when (mode /= Applicative) $ 
    --      setLastClosureForConnection (idConn conn) $ getDBRef (kLocalClos s2 closr)
    processMessage  s1 closl s2 closr log bool

#ifdef BROWSER
listen :: Node -> TransIO ()
listen node = do
        addNodes [node]
        setRState(JobGroup M.empty)
        -- ex <- exceptionPoint :: TransIO (BackPoint SomeException)
        -- setData ex

        events <- liftIO $ newIORef M.empty
        rnode  <- liftIO $ newIORef node
        conn <-  defConnection >>= \c -> return c{myNode=rnode} -- ,comEvent=events}
        liftIO $ atomicModifyIORef connectionList $ \m ->  (conn: m,())

        setData conn
        r <- listenResponses
        execLog  r

#endif


-- lookup2 key doubleList =
--   let r = mapMaybe (lookupService key) doubleList
--   in if null r then Nothing else Just $ head r

-- filter2 key doubleList = mapMaybe (lookup key) doubleList

--------------------------------------------
#ifndef BROWSER


readFrom con = do
  cd <- readIORef $ connData con
  case cd of
    Just (TLSNode2Node ctx) -> recvTLSData ctx
    Just (Node2Node _ sock _) -> BS.toStrict <$> loop sock
    _ -> error "readFrom error"
  where
    bufSize = 4098
    loop sock = loop1
      where
        loop1 :: IO BL.ByteString
        loop1 = unsafeInterleaveIO $ do
          s <- SBS.recv sock bufSize

          if BC.length s < bufSize
            then return $ BLC.Chunk s mempty
            else BLC.Chunk s `liftM` loop1

-- toStrict= B.concat . BS.toChunks

makeWSStreamFromConn conn = do
  tr "WEBSOCKETS request"
  let rec = readFrom conn
      send x = sendRaw conn x
  makeStream
    ( do
        bs <- rec -- SBS.recv sock 4098
        return $ if BC.null bs then Nothing else Just bs
    )
    ( \mbBl -> case mbBl of
        Nothing -> return ()
        Just bl -> send bl -- SBS.sendMany sock (BL.toChunks bl) >> return())   -- !!> show ("SOCK RESP",bl)
    )

makeWebsocketConnection conn uri headers = liftIO $ do
  stream <- makeWSStreamFromConn conn
  let pc =
        WS.PendingConnection
          { WS.pendingOptions = WS.defaultConnectionOptions, -- {connectionOnPong=xxx}
            WS.pendingRequest = NWS.RequestHead uri headers False, -- RequestHead (BC.pack $ show uri)
            -- (map parseh headers) False
            WS.pendingOnAccept = \_ -> return (),
            WS.pendingStream = stream
          }

  sconn <- WS.acceptRequest pc -- !!> "accept request"
  WS.forkPingThread sconn 30
  return sconn

-- if it is a websocket request, end. otherwise serve the page and stop

servePage (method, uri, headers :: NWS.Headers) = do
  --   return ()                        !> ("HTTP request",method,uri, headers)
  conn <- getSData <|> error " servePageMode: no connection"

  if isWebSocketsReq headers
    then return ()    -- Not elegant, but it works
    else do
      ttr "FILESERVER"
      let file = if BC.null uri then "index.html" else uri

      {- TODO rendering in server
         NEEDED:  recodify View to use blaze-html in server. wlink to get path in server
         does file exist?
         if exist, send else do
            store path, execute continuation
            get the rendering
            send trough HTTP
         - put this logic as independent alternative programmer options
            serveFile dirs <|> serveApi apis <|> serveNode nodeCode
      -}
      mcontent <-
        liftIO $
          (Just <$> BL.readFile ("./static/" ++ dropWhile (== '.') (BC.unpack file)))
            `catch` (\(e :: SomeException) -> return Nothing)

      --                                    return  "Not found file: index.html<br/> please compile with ghcjs<br/> ghcjs program.hs -o static/out")
      case mcontent of
        Just content -> do
          ttr "content found"
          let mime = defaultMimeLookup $ decodeUtf8 file
          cook <- liftIO $ readIORef rcookie
          -- Generar 'state' cookie estable por navegador si no existe.
          -- Garantiza que todos los requests del mismo navegador usen
          -- el mismo httpnode, permitiendo que addNodes mergee conexiones.
          ttr ("COOKIE SERVEPAGE",  lookup "Cookie" headers)
          stateHdr <- case lookup "Cookie" headers of
            Just cs | "state=" `BC.isInfixOf` cs -> return mempty
            _ -> do sid <- liftIO $ BC.pack <$> replicateM 5 (randomRIO ('a', 'z'))
                    return $ BS.pack $ "Set-Cookie: state=" <> BC.unpack sid <> "\r\n"
          sendRawRecover conn $
              "HTTP/1.0 200 OK\r\nContent-Type: " <> BL.fromStrict mime <> "\r\nConnection: close\r\nContent-Length: "
                <> BS.pack (show $ BL.length content)
                <> "\r\n"
                <> stateHdr
                <> "Set-Cookie:"
                <> "cookie="
                <> cook
                <> "\r\n\r\n"
                <> content
        Nothing ->
          sendRawRecover conn $
              BS.pack $
                "HTTP/1.0 404 Not Found\nContent-Length: 13\r\nConnection: close\r\n\r\nNot Found 404"
      empty

-- | Expose a raw HTTP endpoint: only runs during recovery and responds with the
-- bytestring produced by @w@, respecting HTTP\/1.0 vs 1.1 keep-alive.
api :: TransIO BS.ByteString -> Cloud ()
api w = Cloud $ do
  log <- getLog
  if not $ recover log
    then empty
    else do
      -- HTTPHeaders (_, _, vers) hdrs <- tryState <|> error "api: no HTTP headers???"
      conn <- tryState <|> error "api: Need a connection opened with initNode, listen, simpleWebApp"
      cdata <- liftIO $ readIORef $ connData conn
      case fromJust cdata of
        HTTP2Node _ _ _ (HTTPHeaders (_, _, vers) hdrs) -> sendit w vers hdrs conn
        -- XXXX others
        _ -> error "Transient.Internals.Move:2842. wrong connection"

  where
    sendit w vers hdrs conn= do
      r <- w
      tr ("response", r)
      let send = sendRaw conn
      send r

      tr (vers, hdrs)
      when
        ( vers == http10
            || BS.isPrefixOf http10 r
            || lookup "Connection" hdrs == Just "close"
            || closeInResponse r
        )
        $ liftIO $ mclose conn

    closeInResponse r =
      let rest = findSubstring "Connection:" r
          rest' = BS.dropWhile (== ' ') rest
       in if BS.isPrefixOf "close" rest' then True else False
      where
        findSubstring sub str
          | BS.null str = str
          | BS.isPrefixOf sub str = BS.drop (BS.length sub) str
          | otherwise = findSubstring sub (BS.tail str)

http10 = "HTTP/1.0"

isWebSocketsReq =
  not . null
    . filter ((==  "Sec-WebSocket-Key") . fst)


getFirstLine = (,,) <$> getMethod <*> (BS.toStrict <$> getUri) <*> getVers
  where
    getMethod = parseString

    getUri = parseString
    getVers = parseString

getRawHeaders = dropSpaces >> (withGetParseString $ \s -> return $ scan mempty s)
  where
    scan res str
      | "\r\n\r\n" `BS.isPrefixOf` str = (res, BS.drop 4 str)
      | otherwise = scan (BS.snoc res $ BS.head str) $ BS.tail str

type PostParams = [(BS.ByteString, String)]

-- | Parse an @application\/x-www-form-urlencoded@ body into @[(key, value)]@ pairs.
parsePostUrlEncoded :: TransIO PostParams
parsePostUrlEncoded = do
  dropSpaces
  many $ (,) <$> param <*> value
  where
    param = tTakeWhile' (/= '=') -- !> "param"
    value = unEscapeString <$> BS.unpack <$> tTakeWhile' (/= '&')

getHeaders = manyTill paramPair (string "\r\n\r\n") :: TransIO NWS.Headers -- !>  (method, uri, vers)
  where
    paramPair = (,) <$> (mk <$> getParam) <*> getParamValue

    getParam = do
      dropSpaces
      r <- tTakeWhile (\x -> x /= ':' && not (endline x))
      if BS.null r || r == "\r" then empty else anyChar >> return (BS.toStrict r)
      where
        endline c = c == '\r' || c == '\n'

    getParamValue = BS.toStrict <$> (dropSpaces >> tTakeWhile (\x -> not (endline x)))
      where
        endline c = c == '\r' || c == '\n'
#endif
#ifdef BROWSER
isBrowserInstance= True
api _= empty
#else
-- | Returns 'True' if we are running in the browser.
isBrowserInstance= False

#endif

{-# NOINLINE emptyPool #-}
-- | Allocate an empty connection pool 'MVar'.
emptyPool :: MonadIO m => m (MVar Pool)
emptyPool = liftIO $ newMVar []

-- | Create a node from a hostname (or IP address), port number and a list of
-- services.
createNodeServ :: String -> Int -> [Service] -> IO Node
createNodeServ h p svs = return $ Node h p Nothing svs

-- | Create a plain node with no services.
createNode :: MonadIO m => String -> Int -> m Node
createNode h p = liftIO $ createNodeServ h p []

-- | Create an ephemeral web node (hostname @\"webnode\"@, random port, empty pool).
createWebNode :: MonadIO m => m Node
createWebNode = liftIO $ do
  pool <- emptyPool
  port <- randomIO
  return $ Node "webnode" port (Just pool) [Service $ M.fromList [("webnode", "")]]


-- | Global list of known cluster nodes (STM transactional variable).
nodeList :: TVar [Node]
nodeList = unsafePerformIO $ newTVarIO []

--myNode :: Int -> DBRef  MyNode
--myNode= getDBRef $ key $ MyNode undefined

errorMyNode f = error $ f ++ ": Node not set. initialize it with connect, listen, initNode..."

setMyNode n= do
  ns <- getNodes
  setNodes $ n : tail ns
  Connection {myNode = rnode} <- getSData <|> errorMyNode "getMyNode" :: TransIO Connection
  liftIO $ writeIORef rnode n


-- | Return the local node i.e. the node where this computation is running.
getMyNode :: TransIO Node
getMyNode = do
  Connection {myNode = rnode} <- getSData <|> errorMyNode "getMyNode" :: TransIO Connection
  liftIO $ readIORef rnode

-- | empty if the node is not set
getMyNodeMaybe = do
  Connection {myNode = node} <- getSData
  liftIO $ readIORef node


-- | Return the list of nodes in the cluster.
getNodes :: MonadIO m => m [Node]
getNodes = liftIO $ readTVarIO nodeList

-- | Get the nodes that have the same service definition than the calling node
getEqualNodes = do
  nodes <- getNodes

  let srv = nodeServices $ Prelude.head nodes
  case srv of
    [] -> return $ filter (null . nodeServices) nodes
    (srv : _) -> return $ filter (\n -> (not $ null $ nodeServices n) && Prelude.head (nodeServices n) == srv) nodes

getWebNodes :: MonadIO m => m [Node]
getWebNodes = do
  nodes <- getNodes
  return $ filter ((==) "webnode" . nodeHost) nodes

-- | Get web nodes matching a specific session ID.
-- The host is expected to be \"httpnode-<sessionId>\".
getWebNodeForSession :: BC.ByteString -> TransIO [Node]
getWebNodeForSession sessionId = do
  nodes <- getNodes
  let hostMatch = "httpnode-" <> BC.unpack sessionId
  return $ filter (\n -> nodeHost n == hostMatch) nodes


-- | Remove httpnodes whose connection pool contains no live connections
-- (connData is Nothing).  Call periodically to clean up stale browser nodes.
reapStaleWebNodes :: TransIO ()
reapStaleWebNodes = do
  nodes <- getNodes
  let webnodes = filter (\n -> "httpnode-" `isPrefixOf` nodeHost n) nodes
  stale <- filterM (fmap not . hasLiveConn) webnodes
  when (not $ null stale) $ do
    ttr ("reapStaleWebNodes: removing", length stale, "stale nodes")
    delNodes stale
  where
    hasLiveConn n = case connection n of
      Just pool -> liftIO $ do
        cs <- readMVar pool
        or <$> mapM (\c -> isJust <$> readIORef (connData c)) cs
      Nothing -> return False

matchNodes f = do
  nodes <- getNodes
  return $ Prelude.map (\n -> filter f $ nodeServices n) nodes

-- | Add a list of nodes to the list of existing nodes know locally.
-- If the node is already present, It add his services to the already present node
-- services which have the first element equal (usually the "name" field) will be substituted if the match
addNodes :: [Node] -> TransIO ()
addNodes nodes = liftIO $ do
  -- the local node should be the first
  tr "addNodes"
  nodes' <- mapM fixNode nodes
  atomically $ do
    prevnodes <- readTVar nodeList
    newnodes  <- insert [] nodes' prevnodes
    writeTVar nodeList  newnodes
  where
    -- existing  newnotprocessed prevnodesnotprocessed
    insert ins  nodes []= return $ reverse ins ++  nodes
    insert ins  nodes (node':prevnodes)= do
      case filter (==node') nodes of
        [] ->  insert (node':ins)  nodes prevnodes
        [node] -> do
          let mixservices = nub $ nodeServices node ++ nodeServices node'
          let newnode= node'{nodeServices = mixservices}
          unsafeIOToSTM $ do
            cs' <- if isJust (connection node) then readMVar $ fromJust $ connection node else return []
            modifyMVar (fromJust $ connection newnode) $ \cs -> return (cs' ++ cs, ())
          insert (newnode:ins) (nodes \\ [node]) prevnodes

delNodes nodes = liftIO $ do
  tr "delNodes"
  atomically $ do
    nodes' <- readTVar nodeList
    writeTVar nodeList $ nodes' \\ nodes

fixNode n = case connection n of
  Nothing -> do
    pool <- emptyPool
    return n {connection = Just pool}
  Just _ -> return n

-- | set the list of nodes
setNodes nodes = liftIO $ do
  tr "setNodes"
  nodes' <- mapM fixNode nodes
  atomically $ writeTVar nodeList nodes'

-- | Shuffle the list of cluster nodes and return the shuffled list.
shuffleNodes :: MonadIO m => m [Node]
shuffleNodes = liftIO . atomically $ do
  nodes <- readTVar nodeList
  let nodes' = Prelude.tail nodes ++ [Prelude.head nodes]
  writeTVar nodeList nodes'
  return nodes'


-- | add this node to the list of know nodes in the remote node connected by a `wormhole`.
--  This is useful when the node is called back by the remote node.
-- In the case of web nodes with webSocket connections, this is the way to add it to the list of
-- known nodes in the server.
addThisNodeToRemote = do
  n <- local getMyNode
  atRemote $
    local $ do
      n' <- setConnectionIn n
      addNodes [n']

setConnectionIn node = do
  conn <- tryState <|> error "addThisNodeToRemote: connection not found"
  ref <- liftIO $ newMVar [conn]
  return node {connection = Just ref}


#ifndef BROWSER

-- | Reconcile the list of nodes in the cluster using a remote node already
-- part of the cluster. Reconciliation end up in each node in the cluster
-- having  the same list of nodes.
connect' :: Node -> Cloud ()
connect' remotenode = loggedc $ do
  nodes <- local getNodes
  localIO $ putStr "connecting to: " >> print remotenode

  newNodes <- runAt remotenode $ interchange nodes

  --return ()                                                              !> "interchange finish"

  -- add the new  nodes to the local nodes in all the nodes connected previously

  let toAdd = remotenode : Prelude.tail newNodes
  foldNodes' nodes (<>) mempty $
    local $ do
      liftIO $ putStr "New nodes: " >> print toAdd -- !> "NEWNODES"
      addNodes toAdd
  where
    -- receive new nodes and send their own
    interchange nodes =
      do
        newNodes <- local $ do
          conn@Connection {remoteNode = rnode} <-
            getSData
              <|> error ("connect': need to be connected to a node: use wormhole/connect/listen")

          -- if is a websockets node, add only this node
          -- let newNodes = case  cdata of
          --                  Node2Web _ -> [(head nodes){nodeServices=[("relay",show remotenode)]}]
          --                  _ ->  nodes

          let newNodes = nodes -- map (\n -> n{nodeServices= nodeServices n ++ [("relay",show (remotenode,n))]}) nodes
          callingNode <- fixNode $ Prelude.head newNodes

          liftIO $ writeIORef rnode $ Just callingNode

          liftIO $ modifyMVar_ (fromJust $ connection callingNode) $ const $ return [conn]

          -- onException $ \(e :: SomeException) -> do
          --      liftIO $ putStr "connect:" >> print e
          --      liftIO $ putStrLn "removing node: " >> print callingNode
          --     --  topState >>= showThreads
          --      nodes <- getNodes
          --      setNodes $ nodes \\ [callingNode]

          return newNodes

        oldNodes <- local $ getNodes

        mclustered . local $ do
          liftIO $ putStrLn "New nodes: " >> print newNodes

          addNodes newNodes

        localIO $
          atomically $ do
            -- set the first node (local node) as is called from outside
            --                     tr "HOST2 set"
            nodes <- readTVar nodeList
            let nodes' =
                  (Prelude.head nodes)
                    { nodeHost = nodeHost remotenode,
                      nodePort = nodePort remotenode
                    } :
                  Prelude.tail nodes
            writeTVar nodeList nodes'

        return oldNodes
#else
connect _ _= empty
connect' _ = empty
#endif


-- | crawl the nodes executing the same action in each node and accumulate the results using a binary operator
foldNet :: Loggable a => (Cloud a -> Cloud a -> Cloud a) -> Cloud a -> Cloud a -> Cloud a
foldNet op init action = atServer $ do
  ref <- onAll $ liftIO $ newIORef Nothing -- eliminate additional results due to unneded parallelism when using (<|>)
  r <- exploreNetExclude []
  v <- localIO $ atomicModifyIORef ref $ \v -> (Just r, v)
  case v of
    Nothing -> return r
    Just _ -> empty
  where
    exploreNetExclude nodesexclude = loggedc $ do
      action `op` otherNodes
      where
        otherNodes = do
          node <- local getMyNode
          nodes <- local getNodes'
          tr ("NODES to explore", nodes)
          let nodesToExplore = Prelude.tail nodes \\ (node : nodesexclude)
          foldNodes' nodesToExplore op init $
            exploreNetExclude ((node : nodesexclude) `union` nodes)

        getNodes' = getEqualNodes -- if isBrowserInstance then  return <$>getMyNode  -- getEqualNodes
        -- else   getEqualNodes <> getWebNodes

-- | execute in all nodes discoverable and mappend all the results 
exploreNet :: (Loggable a, Monoid a) => Cloud a -> Cloud a
exploreNet = foldNet mappend mempty

-- | execute in all nodes discoverable and return every result in a stream
exploreNetUntil :: (Loggable a) => Cloud a -> Cloud a
exploreNetUntil = foldNet (<|>) empty

-- | only execute if the the program is executing in the browser. The code inside can contain calls to the server.
-- Otherwise return empty (so it stop the computation and may execute alternative computations).
onBrowser :: Cloud a -> Cloud a
onBrowser x = do
  r <- local $ return isBrowserInstance
  if r then x else empty

-- | only executes the computaion if it is in the server, but the computation can call the browser. Otherwise return empty
onServer :: Cloud a -> Cloud a
onServer x = do
  r <- local $ return isBrowserInstance
  if not r then x else empty

-- | If the computation is running in the server, translates i to the browser and return back.
-- If it is already in the browser, just execute it
atBrowser :: Loggable a => Cloud a -> Cloud a
atBrowser x = do
  r <- local $ return isBrowserInstance
  if r then x else atRemote x

-- | If the computation is running in the browser, translates i to the server and return back.
-- If it is already in the server, just execute it
atServer :: Loggable a => Cloud a -> Cloud a
atServer x = do
  r <- local $ return isBrowserInstance
  tr ("AT SERVER", r)
  if not r then x else atRemote x

------------------- timeouts -----------------------
-- delete connections.
-- delete receiving closures before sending closures


{-
 por qué esto? localSession no contiene un numero de conexion sino el id de sesion
 añadir un campo de conexion localCon? 
cleanConnectionData c = liftIO $ do
  -- reset the remote accessible closures
  -- modifyMVar_ (localClosures c) $ const $ return M.empty
  rs <- atomically $ localSession .==. idConn c
  atomically $ mapM flushDBRef rs -- (\r -> do reg <- readDBRef r;writeDBRef r reg{localCont=Nothing}) rs
  return ()


delta = 60 -- 3*60

-- | Background loop that closes idle connections and flushes stale closures from TCache.
connectionTimeouts :: TransIO ()
connectionTimeouts = do
  labelState "loop connections"

  threads 0 $ waitEvents $ return () --loop
  liftIO $ threadDelay 1000000
  tr "timeout connections"
  TOD time _ <- liftIO getClockTime

  toClose <- liftIO $
    atomicModifyIORef connectionList $ \cons ->
      Data.List.partition
        ( \con ->
            let mc = unsafePerformIO $ readMVar $ isBlocked con
             in isNothing mc
                  || ((time - fromJust mc) < delta) -- check that is not doing some IO
        )
        cons -- !> Data.List.length cons
        -- time etc are in a IORef
  forM_ toClose $ \c -> liftIO $ do
    tr ("close ", idConn c)
    --when (calling c) $
    mclose c
    cleanConnectionData c -- websocket connections close everithing on  timeout


loopClosures= do

  labelState  "loop closures"

  threads 0 $ do                              -- in the current thread
    waitEvents $ threadDelay 5000000          -- every 5 seconds
    tr "check closures"
    nodes <- getNodes                                             -- get the nodes known
    node <- choose $ tail nodes                                   -- walk trough them, except my own node
    guard (isJust $ connection node)                              -- when a node has connections
    nc <- liftIO $ readMVar $ fromJust (connection node)          -- get them
    conn <- choose nc                                             -- and walk trough them
    lcs <- liftIO $ readMVar $ localClosures conn                 -- get the local endpoints of this node for that connection
    (closLocal,(clos,_,cont)) <- choose $ M.toList lcs         -- walk trough them
    chs <- liftIO . readMVar . children $ fromJust  (unsafePerformIO $ readIORef $ parent cont)  -- get the threads spawned by requests to this endpoint
    tr ("NUMBER=",length chs)
    guard (null chs)                                              -- when there is no activity
    tr ("REMOVING", closLocal)
    liftIO $ modifyMVar (localClosures conn) $ \lcs -> return $ (M.delete closLocal lcs,())  -- remove the closure
    msend conn $ SLast $ ClosureData clos closLocal mempty                                   -- notify the remote node
    dat <- liftIO $ readIORef (connData conn)
    case dat of
      Just (HTTP2Node _ sock _) -> mclose conn    -- to simulate HTTP 1.0
      _ -> return()

-}

