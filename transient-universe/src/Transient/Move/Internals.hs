--------------------------------------------------------------------------
--
-- Module      :  Transient.Move.Internals
-- Copyright   :
-- License     :  MIT
--
-- Maintainer  :  agocorona@gmail.com
-- Stability   :
-- Portability :
--
--
-----------------------------------------------------------------------------
{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverlappingInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE UndecidableInstances #-}
-- {-# LANGUAGE DeriveAnyClass #-}

module Transient.Move.Internals where
import Prelude hiding(drop,length)

import Transient.Internals
import Transient.Parse
import Transient.Logged
import Transient.Indeterminism
import Transient.Mailboxes
import Transient.EVars
import Transient.Console

import Data.Typeable
import Control.Applicative
import System.Random
import Data.String
import qualified Data.ByteString.Char8                  as BC
import qualified Data.ByteString.Lazy.Char8             as BS

import System.Time
import Data.ByteString.Builder
import qualified Data.TCache.DefaultPersistence as TC
import Data.TCache  hiding (onNothing)
import Data.TCache.IndexQuery
import GHC.Generics

#ifndef ghcjs_HOST_OS
-- import Network
--- import Network.Info
import Network.URI
--import qualified Data.IP                              as IP
import qualified Network.Socket                         as NS
-- import qualified Network.BSD                            as BSD
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

-- import System.Random

#else
import           JavaScript.Web.WebSocket
import qualified JavaScript.Web.MessageEvent           as JM
import           GHCJS.Prim (JSVal)
import           GHCJS.Marshal(fromJSValUnchecked)
import qualified Data.JSString                          as JS
-- import Data.Text.Encoding
import           JavaScript.Web.MessageEvent.Internal
import           GHCJS.Foreign.Callback.Internal (Callback(..))
import qualified GHCJS.Foreign.Callback                 as CB
--import           Data.JSString  (JSString(..), pack,drop,length)

#endif


import Control.Monad.State
import Control.Monad.Fail
import Control.Exception hiding (onException,try)
import Data.Maybe
--import Data.Hashable


import System.IO.Unsafe
import Control.Concurrent.STM as STM
import Control.Concurrent.MVar

import Data.Monoid
import qualified Data.Map as M
import Data.List (partition,union,(\\),length, nubBy,isPrefixOf) -- (nub,(\\),intersperse, find, union, length, partition)
--import qualified Data.List(length)
import Data.IORef

import Control.Concurrent

import System.Mem.StableName
import Unsafe.Coerce
import System.Environment
import Data.Default

--import System.Random
pk = BS.pack
up = BS.unpack
#ifdef ghcjs_HOST_OS
type HostName  = String
newtype PortID = PortNumber Int deriving (Read, Show, Eq, Typeable)
#endif
-- type HostName  = String

data Node = Node
  { nodeHost :: NS.HostName,
    nodePort :: Int,
    connection :: Maybe (MVar Pool),
    nodeServices :: [Service]
  }
  deriving (Typeable,Generic) -- ,Generic,ToJSON,FromJSON)

-- instance ToJSON Node where
--   toJSON node= object["nodeHost".= nodeHost, "nodePort" .= nodePort, "nodeServices" .= nodeServices] 

-- instance FromJSON Node where
--     parseJSON = withObject "Node" $ \v -> Node
--         <$> v .: "nodeHost"
--         <*> v .: "nodePort"
--         <*> v .: "nodeServices"

-- to allow JSON instances for Node
instance ToJSON (MVar a) where
  toJSON mv= Null

instance FromJSON (MVar a) where
  parseJSON _= return(unsafePerformIO  newEmptyMVar)

instance ToJSON Node

instance FromJSON Node

instance Loggable Node

instance Ord Node where
  compare node1 node2 = compare (nodeHost node1, nodePort node1) (nodeHost node2, nodePort node2)

-- The cloud monad is a thin layer over Transient in order to make sure that the type system
-- forces the logging of intermediate results
newtype Cloud a = Cloud {runCloud :: TransIO a}
  deriving
    ( AdditionalOperators,
      Functor,
      Semigroup,
      Monoid,
      Alternative,
      Applicative,
      MonadFail,
      Monad,
      Num,
      Fractional,
      MonadState EventF
    )

-- instance Applicative Cloud where
--   pure a = Cloud $ return  a

--   Cloud mf <*> Cloud mx =  Cloud $ sandboxData (M.empty :: M.Map Int (Closure,[Int]))  mf <*> mx

{-

instance Applicative Cloud where
  pure a = Cloud $ return  a

  Cloud mf <*> Cloud mx = do

    r1 <- onAll . liftIO $ newIORef Nothing
    r2 <- onAll . liftIO $ newIORef Nothing
    onAll $ fparallel r1 r2 <|> xparallel r1 r2

    where

    fparallel r1 r2= do
      f <- mf
      liftIO $ (writeIORef r1 $ Just f)
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
                       liftIO $ (writeIORef r2 $ Just x)

                       mr <- liftIO (readIORef r1)
                       case mr of
                         Nothing -> empty
                         Just f  -> return $ f x

            Just f -> do
              x <- mx
              liftIO $ (writeIORef r2 $ Just x)
              return $ f x

-}

type UPassword = BS.ByteString

type Host = BS.ByteString

type ProxyData = (UPassword, Host, Int)

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
      tr ("proxy", p)
      case p of
        Nothing -> return Nothing
        Just hp -> do
          pr <- withParseString (BS.pack hp) $ do
            tDropUntilToken (BS.pack "//") <|> return ()
            (,,) <$> getUPass <*> tTakeWhile' (/= ':') <*> int
          return $ Just pr
    getUPass = tTakeUntilToken "@" <|> return ""

-- | Execute a distributed computation inside a TransIO computation.
-- All the  computations in the TransIO monad that enclose the cloud computation must be `logged`
-- runCloud :: Cloud a -> TransIO a

-- runCloud x= do
--        closRemote  <- getState <|> return (Closure  0)
--        runCloud' x <*** setState  closRemote

--instance Monoid a => Monoid (Cloud a) where
--  f mappend x y = mappend <$> x <*> y
--   mempty= return mempty
#ifndef ghcjs_HOST_OS

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
      if ((not $ BL.null input) && BL.head input == 0x16)
        then do
          conn <- getSData
          sendRaw conn $ BS.pack $ "HTTP/1.0 525 SSL Handshake Failed\r\nContent-Length: 0\nConnection: close\r\n\r\n"
        else return ()

(isTLSIncluded, sendTLSData, recvTLSData, maybeTLSServerHandshake, maybeClientTLSHandshake, tlsClose) = unsafePerformIO $ readIORef tlsHooks
#endif

-- | Means that this computation will be executed in the current node. the result will be logged
-- so the closure will be recovered if the computation is translated to other node by means of
-- primitives like `beamTo`, `forkTo`, `runAt`, `teleport`, `clustered`, `mclustered` etc
local :: Loggable a => TransIO a -> Cloud a
-- local =  Cloud . logged'

-- data EnterLocal= EnterLocal deriving (Typeable,Show)
local mx = Cloud $
  logged $ do
    r <- mx

    parseString <- getParseBuffer
    
    when (BS.null parseString) $ do

      mconn <- getData  -- `onNothing` error "no connection"
      case mconn of 
        Nothing -> return ()
        Just conn -> do
          Closure a b ns <- getIndexData (idConn conn) `onNothing` return (Closure 0 "0" [])
          when (null ns) $ do
            log <- getLog
            tr ("PARSESTRING", "recover", parseString, recover log)
            let end = getEnd $ fulLog log
            tr ("END=", end, fulLog log)
            tr ("setIndexdata", idConn conn, a, b, end)
            setIndexData (idConn conn) (Closure a b end)

            --modifyData' (\log -> log{fromCont=True})  $ error "no log"

            return ()
    -- delState EnterLocal

    return r

-- #ifndef ghcjs_HOST_OS

-- | Run a distributed computation inside the IO monad. Enables asynchronous
-- console input (see 'keep').
runCloudIO :: Typeable a => Cloud a -> IO (Maybe a)
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
-- >       runCloud $ do
-- >               onAll baz
-- >               runAt node ....
-- > runAt node' .....
--
-- foo bar and baz will e executed locally.
-- But foo will be executed remotely also in node' while foo' bar and baz don't.

--

onAll :: TransIO a -> Cloud a
onAll = Cloud

-- | only executes if the result is demanded. It is useful when the conputation result is only used in
-- the remote node, but it is not serializable. All the state changes executed in the argument with
-- `setData` `setState` etc. are lost
lazy :: TransIO a -> Cloud a
lazy mx = onAll $ do
  st <- get
  return $ fromJust $ unsafePerformIO $ runStateT (runTrans mx) st >>= return . fst

-- | executes a non-serilizable action in the remote node, whose result can be used by subsequent remote invocations
fixRemote mx = do
  r <- lazy mx
  fixClosure
  return r

-- | subsequent remote invocatioms will send logs to this closure. Therefore logs will be shorter.
--
-- Also, non serializable statements before it will not be re-executed
fixClosure = atRemote $ local $ async $ return ()

-- log the result a cloud computation. Like `loogged`, this erases all the log produced by computations
-- inside and substitute it for that single result when the computation is completed.
loggedc :: Loggable a => Cloud a -> Cloud a
loggedc (Cloud mx) = Cloud $ do
  --  closRemote  <- getState <|> return (Closure  0 )
  --  (fixRemote :: Maybe LocalFixData) <- getData
  logged mx -- <*** do setData  closRemote
  --        when (isJust fixRemote) $ setState (fromJust fixRemote)

loggedc' :: Loggable a => Cloud a -> Cloud a
loggedc' (Cloud mx) = Cloud $ logged mx

--  do
--       fixRemote :: Maybe LocalFixData <- getData
--       logged mx <*** (when (isJust fixRemote) $ setState (fromJust fixRemote))

-- | the `Cloud` monad has no `MonadIO` instance since the value must be `Loggable`
-- to work right. `lliftIO= local . liftIO`
lliftIO :: Loggable a => IO a -> Cloud a
lliftIO = local . liftIO

-- |  `localIO = lliftIO`
localIO :: Loggable a => IO a -> Cloud a
localIO = lliftIO

-- | continue the execution in another node
beamTo :: Node -> Cloud ()
beamTo node = wormhole node teleport

-- | execute in the remote node a processMessage with the same execution state
forkTo :: Node -> Cloud ()
forkTo node = beamTo node <|> return ()

-- | open a wormhole to another node and executes an action on it.
-- currently by default it keep open the connection to receive additional requests
-- and responses (streaming)
callTo :: Loggable a => Node -> Cloud a -> Cloud a
callTo node remoteProc = wormhole' node $ atRemote remoteProc

-- #ifndef ghcjs_HOST_OS

-- -- | A connectionless version of callTo for long running remote calls
-- callTo' :: (Show a, Read a, Typeable a) => Node -> Cloud a -> Cloud a
-- callTo' node remoteProc = do
--   mynode <- local $ getNodes >>= return . Prelude.head
--   beamTo node
--   r <- remoteProc
--   beamTo mynode
--   return r
-- #endif

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
-- >     bat t                      -- in the original node
atRemote :: Loggable a => Cloud a -> Cloud a
atRemote proc = loggedc' $ do
  --modify $ \s -> s{execMode=Parallel}
  teleport --  !> "teleport 1111"
  modify $ \s -> s {execMode = if execMode s == Parallel then Parallel else Serial} 
  r <- loggedc $ proc <** modify (\s -> s {execMode = Remote}) 
  teleport -- !> "teleport 2222"
  return r


-- | open a wormhole to another node and executes an action on it.
-- currently by default it keep open the connection to receive additional requests
-- and responses (streaming)
runAt :: Loggable a => Node -> Cloud a -> Cloud a
runAt node remoteProc = wormhole' node $ atRemote remoteProc

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
  id <- liftIO $ f `seq` makeStableName f >>= return . hashStableName

  case M.lookup id mapth of
    Just tv -> liftIO $ killBranch' tv
    Nothing -> return ()

  tv <- get
  f <** do
    id <- liftIO $ makeStableName f >>= return . hashStableName
    liftIO $ modifyIORef rmap $ \mapth -> M.insert id tv mapth

-- | run an unique continuation for each connection in that place of the computation. The first thread that execute `unique` is
-- executed for that connection. The rest are ignored.
unique :: TransIO a -> TransIO a
unique f = do
  Connection {closChildren = rmap} <- getSData <|> error "unique: only works within a connection. Use wormhole"
  mapth <- liftIO $ readIORef rmap
  id <- liftIO $ f `seq` makeStableName f >>= return . hashStableName

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
wormhole node comp = do
  onAll $
    onException $ \(e@(ConnectionError "no connection" nodeerr)) ->
      if nodeerr == node then do runCloud $ findRelay node; continue else return ()
  wormhole' node comp
  where
    findRelay node = do
      relaynode <- exploreNetUntil $ do
        nodes <- local getNodes
        let thenode = filter (== node) nodes
        if not (null thenode) && isJust (connection $ Prelude.head thenode) then return $ Prelude.head nodes else empty
      local $ addNodes [node {nodeServices = nodeServices node ++ [[("relay", show (nodeHost (relaynode :: Node), nodePort relaynode))]]}]

-- when the first teleport has been sent within a wormhole, the
-- log sent should be the segment not send in the previous teleport
-- newtype DialogInWormholeInitiated= DialogInWormholeInitiated Bool

-- | wormhole without searching for relay nodes.
wormhole' :: Loggable a => Node -> Cloud a -> Cloud a
wormhole' node (Cloud comp) = local $
  Transient $ do
    moldconn <- getData :: StateIO (Maybe Connection)
    --  mclosure <- getData :: StateIO (Maybe (M.Map Int Closure))
    --  mdialog  <- getData :: StateIO (Maybe ( Ref DialogInWormholeInitiated))

    tr "wormhole"
    labelState "wormhole" -- <> BC.pack (show node)
    log <- getLog

    if not $ recover log
      then runTrans $ (do
       my <- getMyNode
       if node== my then do
              let conn = fromMaybe (error "wormhole: no connection") moldconn
              rself <- liftIO $ newIORef  $ Just Self
              liftIO $ writeIORef (remoteNode conn) $ Just node
              setData conn{connData=   rself} 
              comp
        else do
              tr "befor mconnect"
              conn <- mconnect node
              tr "wormhole after connect"

              liftIO $ writeIORef (remoteNode conn) $ Just node
              setData conn {synchronous = maybe False id $ fmap synchronous moldconn, calling = True}

              tr "before comp"
              comp
          )
            <*** do
              when (isJust moldconn) . setData $ fromJust moldconn
      else 

      do
        -- tr "YES REC"
        let conn = fromMaybe (error "wormhole: no connection in remote node") moldconn
        setData $ conn {calling = False}
        runTrans $ comp




data CloudException = CloudException Node SessionId IdClosure String deriving (Typeable, Show, Read)

instance Exception CloudException

-- | set remote invocations synchronous
-- this is necessary when data is transfered very fast from node to node in a stream non-deterministically
-- in order to keep the continuation of the calling node unchanged until the arrival of the response
-- since all the calls share a single continuation in the calling node.
--
-- If there is no response from the remote node, the streaming is interrupted
--
-- > main= keep $ initNode $  onBrowser $  do
-- >  local $ setSynchronous True
-- >  line  <- local $  threads 0 $ choose[1..10::Int]
-- >  localIO $ print ("1",line)
-- >  atRemote $ localIO $ print line
-- >  localIO $ print ("2", line)
setSynchronous :: Bool -> TransIO ()
setSynchronous sync = do
  modifyData' (\con -> con {synchronous = sync}) (error "setSynchronous: no communication data")
  return ()

-- set synchronous mode for remote calls within a cloud computation and also avoid unnecessary
-- thread creation
syncStream :: Cloud a -> Cloud a
syncStream proc = do
  sync <- local $ do
    Connection {synchronous = synchronous} <- modifyData' (\con -> con {synchronous = True}) err
    return synchronous
  Cloud $ threads 0 $ runCloud proc <*** modifyData' (\con -> con {synchronous = sync}) err
  where
    err = error "syncStream: no connection data"


{-
teleport :: Cloud ()
teleport = do
  modify $ \s -> s {execMode = if execMode s == Remote then Remote else Parallel}
  loggedc $ do
      idSession <- onAll $ fromIntegral <$> genPersistId

      tr "TELEPORTTT2"
      conn@Connection {idConn = idConn, connData = contype, synchronous = synchronous} <-
        getData
          `onNothing` error "teleport: No connection defined: use wormhole"

      --  labelState  "teleport"

      log <- getLog

      if not $ recover log
        then do
          -- when a node call itself, there is no need for socket communications
          ty <- onAll $ liftIO $ readIORef contype
          case ty of
            Just Self -> onAll $ do
              modify $ \s -> s {execMode = Parallel} -- setData  Parallel
              abduce -- !> "SELF" -- call himself
              tr "SELF"
              liftIO $ do
                remote <- readIORef $ remoteNode conn
                writeIORef (myNode conn) $ fromMaybe (error "teleport: no connection?") remote
            _ -> do
              local $ do
                tr ("teleport remote call", idConn)
                (Closure sess closRemote n) <- getIndexData idConn `onNothing` return (Closure 0 "0" [])
                tr ("getIndexData", idConn, sess, closRemote, n)
                let fragment = dropFromIndex n $ fulLog log
                let tosend = if null n then toPath $ LD fragment else toPathFragment fragment -- if a fragment, avoid the LX LX
                tr ("MSEND END", getEnd $ fulLog log, fulLog log, "n=", n)
                tr ("idconn", idConn, "REMOTE CLOSURE", closRemote, "FULLLOG", fulLog log, n, "CUT FULLOG", fragment, tosend)

                let closLocal = BC.pack $show $ hashClosure log

                msend conn $ toLazyByteString $ serialize $ SMore $ ClosureData closRemote sess closLocal idSession tosend
              receive  conn Nothing idSession
          return  ()
        else  return  ()
-}



teleport :: Cloud ()
teleport = do
  modify $ \s -> s {execMode = if execMode s == Remote then Remote else Parallel}
  local $ do
    idSession <- fromIntegral <$> genPersistId

    tr "TELEPORTTT2"
    conn@Connection {idConn = idConn, connData = contype, synchronous = synchronous} <-
      getData
        `onNothing` error "teleport: No connection defined: use wormhole"

    Transient $ do
      --  labelState  "teleport"

      log <- getLog

      if not $ recover log
        then do
          -- when a node call itself, there is no need for socket communications
          ty <- liftIO $ readIORef contype
          case ty of
            Just Self -> runTrans $ do
              modify $ \s -> s {execMode = Parallel} -- setData  Parallel
              abduce -- !> "SELF" -- call himself
              tr "SELF"
              liftIO $ do
                remote <- readIORef $ remoteNode conn
                writeIORef (myNode conn) $ fromMaybe (error "teleport: no connection?") remote
            _ -> do
              tr ("teleport remote call", idConn)
              (Closure sess closRemote n) <- getIndexData idConn `onNothing` return (Closure 0 "0" [])
              tr ("getIndexData", idConn, sess, closRemote, n)
              let fragment = dropFromIndex n $ fulLog log
              let tosend = if null n then toPath $ LD fragment else toPathFragment fragment -- if a fragment, avoid the LX LX
              tr ("MSEND END", getEnd $ fulLog log, fulLog log, "n=", n)
              tr ("idconn", idConn, "REMOTE CLOSURE", closRemote, "FULLLOG", fulLog log, n, "CUT FULLOG", fragment, tosend)

              let closLocal = BC.pack $show $ hashClosure log

              runTrans $ do
                msend conn $ toLazyByteString $ serialize $ SMore $ ClosureData closRemote sess closLocal idSession tosend
                
                receive conn Nothing idSession
        else -- return Nothing

          return $ Just ()

newtype PrevClos = PrevClos {unPrevClos :: DBRef LocalClosure}



receive conn clos idSession = do
  tr ("RECEIVE",clos, idSession)
  (lc, log) <- setCont clos idSession
  s <- giveParseString
  -- tr ("receive PARSESTRING",s,"LOG",toPath $ fulLog log)
  if recover log && not (BS.null s)
    then (abduce >> receive1 lc) <|> return() -- watch this event var and continue restoring
    else  receive1 lc
  
  where
  receive1 lc= do
      when (synchronous conn) $ liftIO $ takeMVar $ localMvar lc
      tr ("EVAR waiting in", localCon lc, localClos lc)
      mr@(Right (a, b, c, _)) <- readEVar $ fromJust $ localEvar lc

      tr ("RECEIVED", (a, b, c))

      case mr of
        Right (SDone, _, _, _)    -> empty
        Right (SError e, _, _, _) -> error $ show("receive:",e)
        Right (SLast log, s2, closr, conn') -> do
          cdata <- liftIO $ readIORef $ connData conn' -- connection may have been changed
          liftIO $ writeIORef (connData conn) cdata
          -- setData conn'
          tr ("RECEIVED -------> SLAST", log)
          setLog (idConn conn) log s2 closr
        Right (SMore log, s2, closr, conn') -> do
          cdata <- liftIO $ readIORef $ connData conn'
          liftIO $ writeIORef (connData conn) cdata
          -- setData conn'
          tr ("RECEIVED -------> SMORE", log, closr)
          setLog (idConn conn) log s2 closr
        Left except -> do
          throwt except
          empty

firstCont = do
  cont <- get
  log <- getLog
  let rthis = getDBRef "0-0" -- TC.key this
  tr ("assign", log)
  when (not $ recover log) $ do
    ev <- newEVar
    mv <- liftIO $ newMVar ()

    let this =
          LocalClosure
            { localCon = 0,
              prevClos = rthis,
              localLog = fulLog log, -- codificar en flow.hs
              localClos = "0", -- hashClosure log,
              localEnd = getEnd $ fulLog log, -- codificar en flow.hs
              localEvar = Just ev,
              localMvar = mv,
              localCont = Just cont
            }

    tr ("end", localEnd this, fulLog log)
    -- n <- getMyNode
    -- let url= str "http://" <> str (nodeHost n) <> str "/" <> intt (nodePort n) <>"/0/0/0/0/"

    -- liftIO $ print url
    liftIO $ atomically $ writeDBRef rthis this
  setState $ PrevClos rthis
  

-- setCont mclos idSession = do
--   (mclos,idSession) <- local $ return (mclos,idSession)
--   onAll $ setContT mclos idSession

-- | store the program state. if the state is saved, and the program restarted `restoreClosure` with the same parameters will rerun the program with this state
setCont mclos idSession = do
  mprev <- getData

  closLocal <- case mclos of Just cls -> return cls; _ -> BC.pack <$> show <$> hashClosure <$> getLog
  let dblocalclos = getDBRef $ kLocalClos idSession closLocal :: DBRef LocalClosure

  setState $ PrevClos dblocalclos

  cont <- get

  log <- getLog

  -- setData $ log{fromCont=True}

  tr ("SETCONT", toPathLon $ fulLog log, "recover", recover log)
  ev <- newEVar

  tr "newevar"
  mr <- liftIO $ atomically $ readDBRef dblocalclos
  pair <- case mr of
    Just (locClos@LocalClosure {..}) -> do
      tr "found dblocalclos"
      return locClos {localEvar = Just ev, localCont = Just cont} -- localCont=Just cont} -- (localClos,localMVar,ev,cont)
    _ -> do
      mv <- liftIO $ newEmptyMVar
      mprevClosData <- if isJust mprev then liftIO $ atomically $ readDBRef $ fromJust $ fmap unPrevClos mprev else return Nothing
      -- mprevClosData <- liftIO $ atomically $ readDBRef  prev -- `onNothing` error "no previous session data"

      let ns = if isJust mprevClosData then localEnd (fromJust mprevClosData) else []
      let end = getEnd $ fulLog log
      tr ("END",closLocal,log,end)
      let lc =
            LocalClosure
              { localCon = idSession,
                prevClos = fromMaybe dblocalclos $ fmap unPrevClos mprev,
                localLog = LD $ dropFromIndex ns $ fulLog log,
                localClos = closLocal,
                localEnd = end,
                localEvar = Just ev,
                localMvar = mv,
                localCont = Just cont -- (closRemote',mv,ev,cont)
                -- setState $ PrevClos dblocalclos
              }

      tr $ let drop = dropFromIndex ns $ fulLog log in ("DROP", fulLog log, ns, drop, toPathLon $ LD drop)
      return lc

  -- liftIO $ modifyMVar_ localClosures $ \map ->  return $ M.insert closLocal pair map
  liftIO $ atomically $ writeDBRef dblocalclos pair

  tr ("writing closure", dblocalclos, prevClos pair)

  return (pair, log)

-- instance Show a => Show (IORef a) where
--     show r= show $ unsafePerformIO $ readIORef r

-- | forward exceptions back to the calling node
reportBack :: TransIO ()
reportBack = onException $ \(e :: SomeException) -> do
  conn <- getData `onNothing` error "reportBack: No connection defined: use wormhole"
  (Closure sess closRemote _) <- getIndexData (idConn conn) `onNothing` error "teleport: no closRemote"
  node <- getMyNode
  let msg = SError $ toException $ ErrorCall $ show $ show $ CloudException node sess closRemote $ show e
  msend conn $ toLazyByteString $ serialize (msg :: StreamData NodeMSG) -- !> "MSEND"

-- | copy a session data variable from the local to the remote node.
-- If there is none set in the local node, The parameter is the default value.
-- In this case, the default value is also set in the local node.
copyData def = do
  r <- local getSData <|> return def
  onAll $ setData r
  return r

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
clustered proc = callNodes (<|>) empty proc

-- A variant of `clustered` that wait for all the responses and `mappend` them
mclustered :: (Monoid a, Loggable a) => Cloud a -> Cloud a
mclustered proc = callNodes (<>) mempty proc

callNodes op init proc = loggedc' $ do
  nodes <- local getEqualNodes
  callNodes' nodes op init proc

callNodes' nodes op init proc = loggedc' $ Prelude.foldr op init $ Prelude.map (\node -> runAt node proc) nodes

-----
#ifndef ghcjs_HOST_OS
sendRawRecover con r =
  do
    c <- liftIO $ readIORef $ connData con
    tr ("CONDATA2",isJust c)
    
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
    `whileException` \(SomeException e) ->do
      liftIO $ print e; empty -- liftIO $ writeIORef (connData con) Nothing

sendRaw con r = do
  let blocked = isBlocked con
  c <- liftIO $ readIORef $ connData con
  liftIO $
    modifyMVar_ blocked $
      const $ do
        tr ("sendRaw", r)
        case c of
          Just (Node2Web sconn) -> liftIO $ WS.sendTextData sconn r
          Just (Node2Node _ sock _) ->do
            tr "NODE2NODE"
            SBS.sendMany sock (BL.toChunks r)
          Just (TLSNode2Node ctx) ->
            sendTLSData ctx r
          _ -> error "No connection stablished"
        TOD time _ <- getClockTime
        return $ Just time

{-

sendRaw (Connection _ _ _ (Just (Node2Web  sconn )) _ _ _ _ _ _ _) r=
      liftIO $   WS.sendTextData sconn  r                                --  !> ("NOde2Web",r)

sendRaw (Connection _ _ _ (Just (Node2Node _ sock _)) _ _ blocked _ _ _ _) r=
      liftIO $  withMVar blocked $ const $  SBS.sendMany sock
                                      (BL.toChunks r )                   -- !> ("NOde2Node",r)

sendRaw (Connection _ _ _(Just (TLSNode2Node  ctx )) _ _ blocked _ _ _ _) r=
      liftIO $ withMVar blocked $ const $ sendTLSData ctx  r         !> ("TLNode2Web",r)
-}
#else
sendRaw con r= do
   c <- liftIO $ readIORef $ connData con
   case c of
      Just (Web2Node sconn) ->
              JavaScript.Web.WebSocket.send   r sconn
      _ -> error "No connection stablished"

{-
sendRaw (Connection _ _ _ (Just (Web2Node sconn)) _ _ blocked _  _ _ _) r= liftIO $
   withMVar blocked $ const $ JavaScript.Web.WebSocket.send   r sconn    -- !> "MSEND SOCKET"
-}

#endif

type SessionId = Int

data NodeMSG = ClosureData IdClosure SessionId IdClosure SessionId Builder deriving (Read, Show)

instance Loggable NodeMSG where
  serialize (ClosureData clos s1 clos' s2 build) =
    byteString clos <> "/" <> intDec s1 <> "/"
      <> byteString clos'
      <> "/"
      <> intDec s2
      <> "/"
      <> build

  deserialize =
    ClosureData <$> (BL.toStrict <$> (tTakeWhile (/= '/')) <* tChar '/') <*> (int <* tChar '/')
      <*> (BL.toStrict <$> (tTakeWhile (/= '/')) <* tChar '/')
      <*> (int <* tChar '/')
      <*> restOfIt
    where
      restOfIt = lazyByteString <$> giveParseString

{-
 en msend escribir la longitud del paquete y el paquete
 en mread cojer la longitud y el mensaje

data Packet= Packet Int BS.ByteString deriving (Read,Show)
instance Loggable Packet where
   serialize (Packet len msg) = intDec len <> lazyByteString msg
   deserialize = do
       len <- int
       Packet len <$> tTake (fromIntegral len)

-}

msend :: Connection -> BL.ByteString -> TransIO ()
-- msend (Connection _ _ _ (Just Self) _ _ _ _ _ _ _) r= return ()
#ifndef ghcjs_HOST_OS

msend con bs = do
  ttr ("MSEND", unsafePerformIO $ readIORef $ remoteNode con, idConn con, "--------->------>", bs)
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
    --case r of
    --   Nothing -> error $ "can not reconnect with " ++ show n
    --    Just c -> return c
    Just _ -> return con
  let blocked = isBlocked con'
  c <- liftIO $ readIORef $ connData con'

  do
    --liftIO $ do
    case c of
      Just (TLSNode2Node ctx) -> liftIO $
        modifyMVar_ blocked $
          const $ do
            tr "TLSSSSSSSSSSS SEND"
            sendTLSData ctx $ toLazyByteString $ int64Dec $ BS.length bs
            sendTLSData ctx bs
            TOD time _ <- getClockTime
            return $ Just time
      Just (Node2Node _ sock _) -> liftIO $
        modifyMVar_ blocked $
          const $ do
            tr "NODE2NODE SEND"
            SBSL.send sock $ toLazyByteString $ int64Dec $ BS.length bs
            SBSL.sendAll sock bs
            TOD time _ <- getClockTime
            return $ Just time
      Just (HTTP2Node _ sock _ _) -> liftIO $
        modifyMVar_ blocked $
          const $ do
            tr "HTTP2NODE SEND"
            SBSL.sendAll sock $ bs -- <> "\r\n"
            TOD time _ <- getClockTime
            return $ Just time
      Just (HTTPS2Node ctx) -> liftIO $
        modifyMVar_ blocked $
          const $ do
            tr "HTTPS2NODE SEND"
            sendTLSData ctx $ bs -- <> "\r\n"
            TOD time _ <- getClockTime
            return $ Just time
      Just (Node2Web sconn) -> do
        tr "NODE2WEB"
        -- {-withMVar blocked $ const $ -} WS.sendTextData sconn $ serialize r -- BS.pack (show r)    !> "websockets send"
        liftIO $ do
          -- let bs = toLazyByteString $ serialize r
          -- WS.sendTextData sconn $ toLazyByteString $ int64Dec $ BS.length bs
          tr "ANTES SEND"

          WS.sendTextData sconn bs -- !> ("N2N SEND", bd)
          tr "AFTER SEND"
      Just Self -> return () -- error "connection to the same node shouldn't happen, file  a bug please"
      _ -> error "msend out of connection context: use wormhole to connect"

-- return()

{-
msend (Connection _ _ _ (Just (Node2Node _ sock _)) _ _ blocked _ _ _ _) r=do
   liftIO $ withMVar blocked $ const $  do
      let bs = toLazyByteString $ serialize r
      SBSL.send sock $ toLazyByteString $ int64Dec $ BS.length bs
      SBSL.sendAll sock bs                                          -- !> ("N2N SEND", bd)

msend (Connection _ _ _ (Just (HTTP2Node _ sock _)) _ _ blocked _ _ _ _) r=do
   liftIO $ withMVar blocked $ const $  do
      let bs = toLazyByteString $ serialize r
      let len=  BS.length bs
          lenstr= toLazyByteString $ int64Dec $ len

      SBSL.send sock $ "HTTP/1.0 200 OK\r\nContent-Type: text/html\r\nContent-Length: "
            <> lenstr
           -- <>"\r\n" <> "Set-Cookie:" <> "cookie=" <> cook -- <> "\r\n"
            <>"\r\n\r\n"

      SBSL.sendAll sock bs                                          -- !> ("N2N SEND", bd)

msend (Connection _ _ _ (Just (TLSNode2Node ctx)) _ _ _ _ _ _ _) r= liftIO $ do
        let bs = toLazyByteString $ serialize r
        sendTLSData  ctx $ toLazyByteString $ int64Dec $ BS.length bs
        sendTLSData  ctx bs                             --  !> "TLS SEND"

msend (Connection _ _ _ (Just (Node2Web sconn)) _ _ _ _ _ _ _) r=
 -- {-withMVar blocked $ const $ -} WS.sendTextData sconn $ serialize r -- BS.pack (show r)    !> "websockets send"
   liftIO $   do
      let bs = toLazyByteString $ serialize r
      WS.sendTextData sconn $ toLazyByteString $ int64Dec $ BS.length bs
      WS.sendTextData sconn bs   -- !> ("N2N SEND", bd)

-}

#else
msend con r= do
   tr   ("MSEND --------->------>", r)

   let blocked= isBlocked con
   c <- liftIO $ readIORef $ connData con
   case c of
     Just (Web2Node sconn) -> liftIO $  do
              tr "MSEND BROWSER"
          --modifyMVar_ (isBlocked con) $ const $ do 
              let bs = toLazyByteString $ serialize r
              JavaScript.Web.WebSocket.send  (JS.pack $ BS.unpack bs) sconn   -- TODO OPTIMIZE THAT!
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


#ifdef ghcjs_HOST_OS

mread conn = do
  mread con= do
   labelState "mread"
   sconn <- liftIO $ readIORef $ connData con
   case sconn of
    Just (Web2Node sconn) -> wsRead sconn
    Nothing               -> error "connection not opened"


--mread (Connection _ _ _ (Just (Web2Node sconn)) _ _ _ _  _ _ _)=  wsRead sconn



wsRead :: Loggable a => WebSocket  -> TransIO  a
wsRead ws= do
  dat <- react (hsonmessage ws) (return ())
  tr "received"

  case JM.getData dat of
    JM.StringData ( text)  ->  do
      setParseString $ BS.pack  . JS.unpack $ text    -- TODO OPTIMIZE THAT

      --len <- integer
      tr ("Browser webSocket read", text)  !> "<------<----<----<------"
      deserialize     -- return (read' $ JS.unpack str)
                 
    JM.BlobData   blob -> error " blob"
    JM.ArrayBufferData arrBuffer -> error "arrBuffer"



wsOpen :: JS.JSString -> TransIO WebSocket
wsOpen url= do
   ws <-  liftIO $ js_createDefault url      --  !> ("wsopen",url)
   react (hsopen ws) (return ())             -- !!> "react"
   return ws                                 -- !!> "AFTER ReACT"

foreign import javascript safe
    "window.location.hostname"
   js_hostname ::    JSVal

foreign import javascript safe
   "window.location.pathname"
  js_pathname ::    JSVal

foreign import javascript safe
    "window.location.protocol"
   js_protocol ::    JSVal

foreign import javascript safe
   "(function(){var res=window.location.href.split(':')[2];if (res === undefined){return 80} else return res.split('/')[0];})()"
   js_port ::   JSVal

foreign import javascript safe
    "$1.onmessage =$2;"
   js_onmessage :: WebSocket  -> JSVal  -> IO ()


getWebServerNode :: TransIO Node
getWebServerNode = liftIO $ do
   h <- fromJSValUnchecked js_hostname
   p <- fromIntegral <$> (fromJSValUnchecked js_port :: IO Int)
   createNode h p


hsonmessage ::WebSocket -> (MessageEvent ->IO()) -> IO ()
hsonmessage ws hscb= do
  cb <- makeCallback1 MessageEvent hscb
  js_onmessage ws cb

foreign import javascript safe
             "$1.onopen =$2;"
   js_open :: WebSocket  -> JSVal  -> IO ()

foreign import javascript safe
             "$1.readyState"
  js_readystate ::  WebSocket -> Int

newtype OpenEvent = OpenEvent JSVal deriving Typeable
hsopen ::  WebSocket -> (OpenEvent ->IO()) -> IO ()
hsopen ws hscb= do
   cb <- makeCallback1 OpenEvent hscb
   js_open ws cb

makeCallback1 :: (JSVal -> a) ->  (a -> IO ()) -> IO JSVal

makeCallback1 f g = do
   Callback cb <- CB.syncCallback1 CB.ContinueAsync (g . f)
   return cb

-- makeCallback ::  IO () -> IO ()
makeCallback f  = do
  Callback cb <- CB.syncCallback CB.ContinueAsync  f
  return cb



foreign import javascript safe
   "new WebSocket($1)" js_createDefault :: JS.JSString -> IO WebSocket


#else


mread conn=  do
  cc <- liftIO $ readIORef $ connData conn
  case cc of
    Nothing -> empty
    Just (Node2Node _ _ _) -> parallelReadHandler conn
    Just (TLSNode2Node _) -> parallelReadHandler conn

-- the rest of the cases are managed by listenNew
--  Just (Node2Web sconn ) -> do
--         ss <- parallel $  receiveData' conn sconn
--         case ss of
--           SDone -> empty
--           SMore s -> do
--             tr ("WEBSOCKET RECEIVED", s)
--             setParseString s
--             --integer
--             TOD t _ <- liftIO getClockTime
--             liftIO $ modifyMVar_ (isBlocked conn) $ const  $ Just <$> return t
--             deserialize
-- where
-- perform timeouts and cleanup of the server when connections

receiveData' a b = NWS.receiveData b

-- receiveData' :: Connection -> NWS.Connection -> IO  BS.ByteString
-- receiveData' c conn = do
--     msg <- WS.receive conn
--     tr ("RECEIVED",msg)
--     case msg of
--         NWS.DataMessage _ _ _ am -> return  $  NWS.fromDataMessage am
--         NWS.ControlMessage cm    -> case cm of
--             NWS.Close i closeMsg -> do
--                 hasSentClose <- readIORef $ WS.connectionSentClose conn
--                 unless hasSentClose $ WS.send conn msg
--                 writeIORef (connData c) Nothing
--                 cleanConnectionData c
--                 empty

--             NWS.Pong _    ->  do
--                 TOD t _ <- liftIO getClockTime
--                 liftIO $ modifyMVar_ (isBlocked c) $ const  $ Just <$> return t
--                 receiveData' c conn
--                 --NWS.connectionOnPong (WS.connectionOptions conn)
--                 --NWS.receiveDataMessage conn
--             NWS.Ping pl   -> do
--                 TOD t _ <- liftIO getClockTime
--                 liftIO $ modifyMVar_ (isBlocked c) $ const  $ Just <$> return t
--                 WS.send conn (NWS.ControlMessage (NWS.Pong pl))
--                 receiveData' c conn

--                 --WS.receiveDataMessage conn
{-
mread (Connection _ _ _ (Just (Node2Node _ _ _)) _ _ _ _ _ _ _) =  parallelReadHandler -- !> "mread"

mread (Connection _ _ _ (Just (TLSNode2Node _ )) _ _ _ _ _ _ _) =  parallelReadHandler
--        parallel $ do
--            s <- recvTLSData  ctx
--            return . read' $  BC.unpack s

mread (Connection _ _ _  (Just (Node2Web sconn )) _ _ _ _ _ _ _)= do

        s <- waitEvents $  WS.receiveData sconn
        setParseString s
        integer
        deserialize
{-
        parallel $ do
            s <- WS.receiveData sconn
            return . read' $  BS.unpack s
                !>  ("WS MREAD RECEIVED ----<----<------<--------", s)
-}

-}

--  parallel many, used for parsing
parMany p = do
  d <- isDone
  -- tr("parmany",d)
  if d then empty else p <|> parMany p

parallelReadHandler :: Loggable a => Connection -> TransIO (StreamData a)
parallelReadHandler conn = do
  onException $ \(e :: IOError) -> empty
  parMany extractPacket
  where
    nomore = (do s <- getParseBuffer; if BS.null s then empty else error $ show $ ("malformed data received: expected Int, received: ", BS.take 10 s))

    extractPacket = do
      -- tr "extractPacket"
      len <- integer <|> nomore
      str <- tTake (fromIntegral len)
      tr ("MREAD  <-------<-------", str)
      TOD t _ <- liftIO $ getClockTime
      liftIO $ modifyMVar_ (isBlocked conn) $ const $ Just <$> return t

      abduce
      -- st <- getCont
      -- th <- liftIO myThreadId
      -- tr("extractpacket this parent",th, threadId $ fromJust $ unsafePerformIO $ readIORef $ parent st)
      -- topState >>= showThreads
      setParseString str
      deserialize

{-
parallelReadHandler= do
      str <- giveParseString :: TransIO BS.ByteString

      r <- choose $ readStream  str

      return  r
                   !> ("parallel read handler read",  r)
                   !> "<-------<----------<--------<----------"
    where
    readStream :: (Typeable a, Read a) =>  BS.ByteString -> [StreamData a]
    readStream s=  readStream1 $ BS.unpack s
     where

     readStream1 s=
       let [(x,r)] = reads  s
       in  x : readStream1 r

-}

getWebServerNode :: TransIO Node
getWebServerNode = getNodes >>= return . Prelude.head
#endif

mclose :: MonadIO m => Connection -> m ()
#ifndef ghcjs_HOST_OS

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
  cleanConnectionData con

{-
mclose (Connection _ _ _
   (Just (Node2Node _  sock _ )) _ _ _ _ _ _ _)= liftIO $ NS.close sock

mclose (Connection _ _ _
   (Just (Node2Web sconn ))
   _ _ _ _  _ _ _)=
    liftIO $ WS.sendClose sconn ("closemsg" :: BS.ByteString)
-}

#else

mclose con= do
   --c <- liftIO $ readIORef $ connData con
   c <- liftIO $ atomicModifyIORef (connData con) $ \c  -> (Nothing,c)

   case c of
     Just (Web2Node sconn)->
        liftIO $ JavaScript.Web.WebSocket.close Nothing Nothing sconn
{-
mclose (Connection _ _ _ (Just (Web2Node sconn)) _ _ blocked _ _ _ _)=
    liftIO $ JavaScript.Web.WebSocket.close Nothing Nothing sconn
-}
#endif

#ifndef ghcjs_HOST_OS
-- connection cookie
rcookie= unsafePerformIO $ newIORef $ BS.pack "cookie1"
#endif

conSection = unsafePerformIO $ newMVar ()

exclusiveCon mx = do
  liftIO $ takeMVar conSection
  r <- mx
  liftIO $ putMVar conSection ()
  return r

-- check for cached connection and return it, otherwise tries to connect with connect1 without cookie check
mconnect' :: Node -> TransIO Connection
mconnect' node' = exclusiveCon $ do
  tr ("MCONNECT",node')
  conn <- do
    node <- fixNode node'
    nodes <- getNodes

    let fnode = filter (== node) nodes
    case fnode of
      [] -> mconnect1 node -- !> "NO NODE"
      ((Node _ _ pool _) : _) -> do
        plist <- liftIO $ readMVar $ fromJust pool
        case plist of -- !>  ("length", length plist,nodePort node) of
          (handle : _) -> do
            c <- liftIO $ readIORef $ connData handle
            if isNothing c -- was closed by timeout
              then mconnect1 node
              else return handle
          -- !>  ("REUSED!", nodeHost node, nodePort node)
          _ -> do
            delNodes [node]
            r <- mconnect1 node
            tr "after mconnect1"
            return r

  setState conn

  return conn



#ifndef ghcjs_HOST_OS
-- effective connect trough different methods
mconnect1 (node@(Node host port _ services)) = do
  --  return ()  !> ("MCONNECT1",host,port,isTLSIncluded)
  {-
  onException $ \(ConnectionError msg node) -> do
              liftIO $ do
                  putStr  msg
                  putStr " connecting "
                  print node
              continue
              empty
     -}
  let types = mapMaybe (lookup "type") services -- need to look in all services
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

  tr ("NEED TLS", needTLS)
  (conn, parseContext) <-   -- fromJust <$> (connectNode2Node host port needTLS)
    checkSelf node
      <|> timeout 1000000 (connectNode2Node host port needTLS)
      <|> timeout 1000000 (connectWebSockets host port needTLS)
      <|> timeout 1000000 (checkRelay needTLS)
      <|> throw (ConnectionError "no connection" node)

  tr "before end connection"

  setState conn

  modify $ \s -> s {execMode = Serial, parseContext = parseContext}

  -- "write node connected in the connection"
  liftIO $ writeIORef (remoteNode conn) $ Just node
  -- "write connection in the node"
  liftIO $ modifyMVar_ (fromJust $ connection node) . const $ return [conn]
  addNodes [node]



  return conn
  where
    checkSelf node = do
      tr "CHECKSELF"
      node' <- getMyNodeMaybe
      guard $ isJust (connection node')
      v <- liftIO $ readMVar (fromJust $ connection node') -- to force connection in case of calling a service of itself
      tr "IN CHECKSELF"
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

    timeout t proc = do
      tr "init timeout"
      r <- sync $ collect' 1 t proc
      tr ("timeout", length r)
      case r of
        [] -> tr "TIMEOUT EMPTY" >> empty -- !> "TIMEOUT EMPTY"
        mr : _ -> case mr of
          Nothing -> throw $ ConnectionError "Bad cookie" node
          Just r -> return r

    checkRelay needTLS = do
      case lookup "relay" $ map head (nodeServices node) of
        Nothing -> empty -- !> "NO RELAY"
        Just relayinfo -> do
          let (h, p) = read relayinfo
          connectWebSockets1 h p ("/relay/" ++ h ++ "/" ++ show p ++ "/") needTLS

    connectSockTLS host (port :: Int) needTLS = do
      -- return ()                                         !> "connectSockTLS"

      let size = 8192
      c@Connection {myNode = my, connData = rcdata} <- getSData <|> defConnection
      tr "BEFORE HANDSHAKE"

      sock <- liftIO $ connectTo' size host $ show port
      let cdata = (Node2Node undefined sock (error $ "addr: outgoing connection"))
      cdata' <- liftIO $ readIORef rcdata

      --input <-  liftIO $ SBSL.getContents sock
      -- let pcontext= ParseContext (do mclose c; return SDone) input (unsafePerformIO $ newIORef False)

      pcontext <- makeParseContext $ SBSL.recv sock 4096

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
      tr "BEFORE HANDSHAKE"
      when (isTLSIncluded && needTLS) $ maybeClientTLSHandshake host sock mempty
      tr "AFTER HNDSHAKE"

    connectNode2Node host port needTLS = localExceptionHandlers $ do
      onException $ \(e :: SomeException) -> do
            liftIO $ putStrLn $ "Connection error: Can not connect to "<> show host <> ":" <> show port
            throw  $ ConnectionError (show e) node

      tr "NODE 2 NODE"
      mproxy <- getHTTProxyParams needTLS
      let (upass, h', p) = case (mproxy) of
            Just p -> p
            _ -> ("", BS.pack host, port)
          h = BS.unpack h'

      if (isLocal host || h == host && p == port)
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

      conn <- getSData <|> error "mconnect: no connection data"

      --mynode <- getMyNode
      parseContext <- gets parseContext
      tr "CONNECTNODE2NODE"
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
        conn <- getSData
        cleanConnectionData conn
        -- throw $ ConnectionError (BS.unpack msg) node
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
parseBody headers = case lookup "Transfer-Encoding" headers of
  Just "chunked" ->  dechunk |-  deserialize
  _ -> case fmap (read . BC.unpack) $ lookup "Content-Length" headers of
    Just length -> do
      msg <- tTake length
      tr ("GOT", length)
      withParseString msg deserialize
    _ -> do
      str <- notParsed -- TODO: must be strict to avoid premature close
      BS.length str `seq` withParseString str deserialize

dechunk =
  do
    n <- numChars
    tr("dechunk",n)
    if n == 0
      then do
         string "\r\n"
         tr "RETURN SDONE"
         return SDone
      else do
        r <- tTake $ fromIntegral n -- !> ("numChars",n)
        --tr ("message", r)
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

makeParseContext rec = liftIO $ do
  done <- newIORef False
  let receive = liftIO $ do
        tr "receive"
        d <- readIORef done
        tr ("receive done", d)
        if d
          then return SDone
          else
            ( do
                r <- rec
                tr ("receive, r=", r)
                if BS.null r
                  then liftIO $ do writeIORef done True; return SDone
                  else return $ SMore r
            )
              `catch` \(SomeException e) -> do
                liftIO $ writeIORef done True
                putStr "Parse: "
                print e
                return SDone

  return $ ParseContext receive mempty done
#else
  
mconnect1 (node@(Node host port (Just pool) _))= do
     conn <- getSData <|> error "connect: listen not set for this node"
     if nodeHost node== "webnode"
      then  do
                        liftIO $ writeIORef (connData conn)  $ Just Self
                        return  conn
      else do
        ws <- connectToWS host $ PortNumber $ fromIntegral port
--                                                           !> "CONNECTWS"
        liftIO $ writeIORef (connData conn)  $ Just (Web2Node ws)

--                                                           !>  ("websocker CONNECION")
        let parseContext =
                      ParseContext (error "parsecontext not available in the browser")
                        "" (unsafePerformIO $ newIORef False)

        chs <- liftIO $ newIORef M.empty
        let conn'= conn{closChildren= chs}
        liftIO $ modifyMVar_ pool $  \plist -> return $ conn':plist
 
        return  conn'
#endif



data ConnectionError = ConnectionError String Node deriving (Show, Read)

instance Exception ConnectionError

-- check for cached connect, if not, it connects and check cookie with mconnect2
mconnect node' = do
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
        --  !>  ("REUSED!", node)
        _ -> do
          tr "mconnect2 2"
          delNodes [node]
          r <- mconnect2 node
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
#ifndef ghcjs_HOST_OS
        Just Self -> return ()
        Just (TLSNode2Node _) -> do
          checkCookie conn
          watchConnection conn node
        Just (Node2Node _ _ _) -> do
          checkCookie conn
          watchConnection conn node
        _ -> watchConnection conn node

#endif
      tr "before mconnect2 return"
      return conn
#ifndef ghcjs_HOST_OS   
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

      case r of
        "OK" -> tr "OK received" -- return ()
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
        gets parseContext :: -- getSData <|> error "NO PARSE CONTEXT"
          TransIO ParseContext
      chs <- liftIO $ newIORef M.empty
      --whls <- liftIO $ newIORef []
      let conn' = conn {closChildren = chs} --, wormholes= whls}
      -- liftIO $ modifyMVar_ (fromJust pool) $  \plist -> do
      --                  if not (null plist) then print "DUPLICATE" else return ()
      --                  return $ conn':plist    -- !> (node,"ADDED TO POOL")

      -- tell listenResponses to watch incoming responses
      putMailbox ((conn', parseContext, node) :: (Connection, ParseContext, Node))
      liftIO $ threadDelay 100000 -- give time to initialize listenResponses
      tr "after watchConnection"


#ifndef ghcjs_HOST_OS


connectTo' :: Int -> NS.HostName -> NS.ServiceName -> IO NS.Socket
connectTo' bufSize host port = do
  tr ("HOSTPORT", host, port)
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
   protocol <- liftIO $ fromJSValUnchecked js_protocol
   pathname <- liftIO $ fromJSValUnchecked js_pathname
   tr ("PAHT",pathname)
   let ps = case (protocol :: JS.JSString)of "http:" -> "ws://"; "https:" -> "wss://"
   wsOpen $ JS.pack $ ps++ h++ ":"++ show p ++ pathname
#endif

-- last usage+ blocking semantics for sending
type Blocked = MVar (Maybe Integer)

type BuffSize = Int

type PortID = Int

data ConnectionData
#ifndef ghcjs_HOST_OS
  = Node2Node
      { port :: NS.ServiceName,
        socket :: NS.Socket,
        sockAddr :: NS.SockAddr
      }
  | TLSNode2Node {tlscontext :: SData}
  | HTTPS2Node {tlscontext :: SData}
  | Node2Web {webSocket :: WS.Connection}
  | HTTP2Node
      { port :: NS.ServiceName,
        socket :: NS.Socket,
        sockAddr :: NS.SockAddr,
        headers:: HTTPHeaders
      }
  | Self
#else
  Self
  | Web2Node{webSocket :: WebSocket}
#endif
  deriving (Show)

instance Show WS.Connection where
  show _ = "WS"

data HTTPHeaders = HTTPHeaders (BS.ByteString, B.ByteString, BS.ByteString) [(CI BC.ByteString, BC.ByteString)] deriving (Show)

newtype PersistId = PersistId Integer deriving (Read, Show, Typeable)

instance TC.Indexable PersistId where key _ = "persistId"

instance (Show a, Read a) => TC.Serializable a where
  serialize = BS.pack . show
  deserialize = read . BS.unpack

persistDBRef = getDBRef "persistId" :: DBRef PersistId

genPersistId = liftIO $
  atomically $ do
    PersistId n <- readDBRef persistDBRef `onNothing` return (PersistId 0)
    writeDBRef persistDBRef $ PersistId $ n + 1
    return n

data LocalClosure = LocalClosure
  { localCon :: Int,
    prevClos :: DBRef LocalClosure,
    localLog :: LogData,
    localEnd :: [Int],
    localClos :: IdClosure,
    localMvar :: MVar (),
    localEvar :: Maybe (EVar (Either CloudException (StreamData Builder, SessionId, IdClosure, Connection))),
    localCont :: Maybe EventF
  }

instance TC.Indexable LocalClosure where
  key LocalClosure {..} = kLocalClos localCon localClos

kLocalClos idCon clos = BC.unpack clos <> "-" <> show idCon

instance TC.Serializable LocalClosure where
  serialize LocalClosure {..} = TC.serialize (localCon, prevClos, localLog, localEnd, localClos)
  deserialize str =
    let (localCon, prevClos, localLog, localEnd, localClos) = TC.deserialize str
        block = unsafePerformIO $ newMVar ()
     in LocalClosure localCon prevClos localLog localEnd localClos block Nothing Nothing


data Connection = Connection
  { idConn :: Int,
    myNode :: IORef Node,
    remoteNode :: IORef (Maybe Node),
    connData :: IORef (Maybe ConnectionData),
    istream :: IORef ParseContext,
    bufferSize :: BuffSize,
    -- multiple wormhole/teleport use the same connection concurrently
    isBlocked :: Blocked,
    calling :: Bool,
    synchronous :: Bool,
    -- local localClosures with his continuation and a blocking MVar
    -- another MVar with the children created by the closure
    -- also has the id of the remote closure connected with
    --  ,localClosures   :: MVar (M.Map IdClosure(
    --                             IdClosure,
    --                             MVar (),
    --                             EVar(Either
    --                                         CloudException
    --                                         (StreamData Builder, IdClosure,Connection)),
    --                             EventF))

    -- for each remote closure that points to local closure 0,
    -- a new container of child processMessagees
    -- in order to treat them separately
    -- so that 'killChilds' do not kill unrelated processMessagees
    -- used by `single` and `unique`
    closChildren :: IORef (M.Map Int EventF)
  }
  deriving (Typeable)

connectionList :: IORef [Connection]
connectionList = unsafePerformIO $ newIORef []

defConnection :: TransIO Connection

noParseContext =
  let err = error "parseContext not set"
   in ParseContext err err err

-- #ifndef ghcjs_HOST_OS
defConnection = do
  idc <-   genPersistId
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

#ifndef ghcjs_HOST_OS

setBuffSize :: Int -> TransIO ()
setBuffSize size = do
  conn <- getData `onNothing` defConnection -- !> "DEFF3")
  setData $ conn {bufferSize = size}

getBuffSize =
  (do getSData >>= return . bufferSize) <|> return 8192

-- | Setup the node to start listening for incoming connections.
listen :: Node -> Cloud ()
listen (node@(Node _ port _ _)) = onAll $ do
  labelState "listen"

  onException $ \(ConnectionError msg node) -> empty

  --addThreads 2
  --  fork connectionTimeouts
  --  fork loopClosures

  setData $ Log {recover = False, fulLog = mempty, hashClosure = 0 {-,fromCont=False -}}

  conn' <- getSData <|> defConnection
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
  --   ttr "ONEXcepTION1"
  --   msend conn $ chunked "404: not found" <> endChunk
  --   -- case cdata of 
  --   --   Just(HTTP2Node _ _ _ _) -> msend conn $ "\r\n" <> chunked "404: not found" <> endChunk
  --   --   Just (HTTPS2Node _)     -> msend conn $ "\r\n" <> chunked "404: not found" <> endChunk
  --   --   _ -> msend conn $ BS.pack $ show e
  --   empty

  liftIO $ modifyMVar_ (fromJust $ connection node') $ const $ return [conn]

  addNodes [node']
  setRState (JobGroup M.empty) --used by resetRemote
  ex <- exceptionPoint :: TransIO (BackPoint SomeException)
  setData ex

  mlog <- listenNew (show port) conn <|> listenResponses :: TransIO (StreamData NodeMSG)
  execLog mlog
  
chunked tosend= do
    let l= fromIntegral $ BS.length tosend
    toHex l <> "\r\n" <> tosend <> "\r\n"

endChunk= "0\r\n\r\n"

toHex 0 = mempty
toHex l =
  let (q, r) = quotRem l 16
    in toHex q <> (BS.singleton $ if r <= 9 then toEnum (fromEnum '0' + r) else toEnum (fromEnum 'A' + r -10))

--  onFinish $ const $ do
--               liftIO $ print "FINISH IN CLOSURE 0"
-- msend conn $ SLast (ClosureData closRemote 0  mempty)
-- dat <- liftIO $ readIORef (connData conn)
-- case dat of
--   Just (HTTP2Node _ sock _) -> mclose conn    -- to simulate HTTP 1.0
--   _ -> return()
{-
  como hacer que el envie SLast cuando está esperando en otro telepor posterior.
  cuando ese thread este en el siguiente teleport, enviar SLast
  pu
  readEVar ev
-}
--  tr "AFTER EXECLOG"
--showNext "after listen" 10
--  tr "END LISTEN"

-- listen incoming requests

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

listenNew port conn' = do
  sock <- liftIO $ listenOn port
  tr "LISTEN ON"
  liftIO $ do
    let bufSize = bufferSize conn'
    NS.setSocketOption sock NS.RecvBuffer bufSize
    NS.setSocketOption sock NS.SendBuffer bufSize

  -- wait for connections. One thread per connection
  liftIO $ do putStr "Connected to port: "; print port
  (sock, addr) <- waitEvents $ NS.accept sock
  tr "LISTENNEW"
  --  loc <- liftIO $ readMVar $ localClosures conn'
  --  tr ("LEN LOC",M.size loc)
  chs <- liftIO $ newIORef M.empty
  --   case addr of
  --     NS.SockAddrInet port host -> liftIO $ print("connection from", port, host)
  --     NS.SockAddrInet6  a b c d -> liftIO $ print("connection from", a, b,c,d)
  noNode <- liftIO $ newIORef Nothing
  id1 <- genPersistId
  tr ("idConn", id1)
  --  cls <- liftIO $ newMVar M.empty
  let conn = conn' {idConn = fromIntegral id1, closChildren = chs, remoteNode = noNode {-,localClosures=cls-}}

  input <- liftIO $ SBSL.getContents sock
  tr "INPUT"

  let nod = unsafePerformIO $ liftIO $ createNode "incoming connection" 0
   in modify $ \s ->
        s
          { execMode = Serial,
            parseContext =
              ( ParseContext
                  (liftIO $ NS.close sock >> throw (ConnectionError "connection closed" nod))
                  input
                  (unsafePerformIO $ newIORef False) ::
                  ParseContext
              )
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
      tr "CONNECTING"
      let host = BC.unpack $ fromMaybe (error "no host in header") $ lookup "Host" headers
          port = read $ BC.unpack $ fromMaybe (error "no port in header") $ lookup "Port" headers
      remNode' <- liftIO $ createNode host port

      rc <- liftIO $ newMVar [conn]
      let remNode = remNode' {connection = Just rc}
      liftIO $ writeIORef (remoteNode conn) $ Just remNode
      tr ("ADDED NODE", remNode)
      addNodes [remNode]
      myCookie <- liftIO $ readIORef rcookie
      if BS.toStrict myCookie /= hisCookie
        then do
          sendRaw conn "NOK"
          mclose conn
          error "connection attempt with bad cookie"
        else do
          sendRaw conn "OK" --    !> "CLOS detected"
          mread conn
    _ -> do
      -- it is a HTTP request
      -- processMessage the current request in his own thread and then (<|>) any other request that arrive in the same connection
      -- first@(method,uri, vers) <-cutBody firstLine headers <|> parMany cutHTTPRequest
      httpHeaders@(HTTPHeaders (first@(method,uri, vers)) headers) <- cutBody firstLine headers <|> parMany cutHTTPRequest


      let uri' = BC.tail $ uriPath uri -- !> uriPath uri
      tr ("uri'", uri')

      case BC.span (/= '/') uri' of
        ("api", _) -> do
          let log = "e/" <> (lazyByteString method <> byteString "/" <> byteString (BC.drop 4 uri'))

          maybeSetHost headers
          tr ("HEADERS", headers)
          str <- giveParseString <|> error "no api data"
          if lookup "Transfer-Encoding" headers == Just "chunked"
            then error $ "chunked not supported"
            else do
              len <-
                ( read <$> BC.unpack
                    <$> (Transient $ return (lookup "Content-Length" headers))
                  )
                  <|> return 0
              log' <- case lookup "Content-Type" headers of
                Just "application/json" -> do
                  let toDecode = BS.take len str
                  -- tr ("TO DECODE", log <> lazyByteString toDecode)

                  setParseString $ BS.take len str
                  return $ log <> "/" <> lazyByteString toDecode -- [(Var $ IDynamic json)]    -- TODO hande this serialization
                Just "application/x-www-form-urlencoded" -> do
                  tr ("POST HEADERS=", BS.take len str)

                  setParseString $ BS.take len str
                  return $ log <> lazyByteString (BS.take len str) -- [(Var . IDynamic $ postParams)]  TODO: solve deserialization
                Just x -> do
                  tr ("POST HEADERS=", BS.take len str)
                  let str = BS.take len str
                  return $ log <> lazyByteString str --  ++ [Var $ IDynamic  str]
                _ -> return $ log
              --  let build= toPath log'
              setParseString $ toLazyByteString log'
              return $ SMore $ ClosureData "0" 0 "0" 0 log' -- !> ("APIIIII", log')
        
        ("relay", _) -> proxy sock method vers uri'

        (h, rest) -> do
          if BC.null rest || h == "file"
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
                  tr ("WEBSOCKET RECEIVED <-----------", s)
                  -- integer
                  deserialize
                    -- a void message is sent to the application signaling the beginning of a connection
                    <|> (return $ SMore (ClosureData "0" 0 "0" 0 (toPath $ exec << lazyByteString s)))
            else do
              -- let uri'' = if not $ isNumber $ BS.head uri'
              --               then
              --                  M.lookup uri' rpaths
              --               else uri'
              let uriparsed = BS.pack $ unEscapeString $ BC.unpack uri'
              body <- if method == "POST" then  (<>) <$> "/" <*> giveParseString else return mempty
              setParseString $ uriparsed  <> body
              remoteClosure <- BL.toStrict <$> tTakeWhile' (/= '/') 

              -- for different formats of URLs
              (s1,thisClosure,s2 ) <- try allParClosParams <|> shortWithIdParam <|> shortClosParams body
                                      


              tr (s1, uri, uri', uriparsed, remoteClosure, s2, thisClosure)

              --cdata <- liftIO $ newIORef $ Just (HTTP2Node (PortNumber port) sock addr)
              conn <- getSData
              liftIO $
                atomicModifyIORef' (connData conn) $ \cdata -> case cdata of
                  Just (Node2Node port sock addr) -> (Just $ HTTP2Node port sock addr httpHeaders, ())
                  Just (HTTP2Node port sock addr _) -> (Just $ HTTP2Node port sock addr httpHeaders, ())
                  Just (TLSNode2Node ctx) -> (Just $ HTTPS2Node ctx, ())
                  Just (HTTPS2Node ctx) -> (Just $ HTTPS2Node ctx, ())
                  _ -> error $ "line 2258: " <> show (cdata)
              pool <- liftIO $ newMVar [conn]
              let node = Node "httpnode" 0 (Just pool) [[("httpnode", "")]]
              addNodes [node]
              liftIO $ writeIORef (remoteNode conn) $ Just node
              --setState conn{connData=cdata}
              s <- giveParseString
              -- cook <- liftIO $ readIORef rcookie



              liftIO $ SBSL.sendAll sock $ "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n"
              -- httpreq :: HTTPHeaders <- getState <|> error "no state"
              tr headers
              return $ SLast $ ClosureData remoteClosure s1 thisClosure s2 $ lazyByteString s
  where
    
    shortClosParams body= do
        tChar 'S'
        s1 <-   deserialize   :: TransIO Int
        restline <- giveParseString
        setParseString $ BS.pack (show s1) <> restline  -- add a extra parameter sessionid for minput
        return (s1,"0",0)

    shortWithIdParam = do
        tChar 'T'
        s1 <-  deserialize   :: TransIO Int
        -- id <-  deserialize   :: TransIO Int
        -- setParseString $ BS.pack (show id) <> "/" <> body -- add a extra parameter sessionid for minput
        return (s1,"0",0)

    allParClosParams= do
      -- liftIO $ print "allParClosParams"
      s1 <- deserialize
      tChar '/'
      thisClosure <- BL.toStrict <$> tTakeWhile' (/= '/') -- deserialize      :: TransIO BC.ByteString
      s2 <- deserialize
      tChar '/'
      return (s1,thisClosure,s2)

    u = unsafePerformIO
    cutHTTPRequest = do
      -- tr "cutHTTPRequest"
      first@(method, _, _) <- getFirstLine
      -- tr ("first",first)
      -- tr ("after getfirstLine", method, uri, vers)
      headers <- getHeaders
      -- setState $ HTTPHeaders first headers
      cutBody first headers

    cutBody (first@(method, _, _)) headers = do
      -- tr "cutBody"
      let ret=  HTTPHeaders first headers
      -- tr("headers",headers)
      if method == "POST"
        then case fmap (read . BC.unpack) $ lookup "Content-Length" headers of
          Nothing -> return ret -- most likely chunked encoding, processed in the same thread
          Just len -> do
            str <- tTake (fromIntegral len)
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
      -- Connection{connData=Just (Node2Node _ sclient _)} <- getState <|> error "proxy: no connection"

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
          conn <- getState
          liftIO $ writeIORef (myNode conn) $fromJust mnode
        liftIO $ writeIORef rsetHost False -- !> "HOSt SET"

rcookies= unsafePerformIO $ newIORef []  -- HTTP cookies

{-# NOINLINE rsetHost #-}
rsetHost = unsafePerformIO $ newIORef True

--instance Read PortNumber where
--  readsPrec n str= let [(n,s)]=   readsPrec n str in [(fromIntegral n,s)]

--deriving instance Read PortID
--deriving instance Typeable PortID

-- | filter out HTTP requests
noHTTP = onAll $ do
  conn <- getState
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

{-
-- filter out WebSockets connections(usually coming from a web node)
noWebSockets= onAll $ do
    conn <- getState
    cdata <- liftIO $ readIORef $ connData conn
    case cdata of
      Just (Web2Node _) -> empty
      _ -> return()
-}
#endif

listenResponses :: Loggable a => TransIO (StreamData a)
listenResponses = do
  labelState "listen responses"
  (conn, parsecontext, node) <- getMailbox :: TransIO (Connection, ParseContext, Node)
  labelState . fromString $ "listen from: " ++ show node
  setData conn

  tr ("CONNECTION RECEIVED", "listen from: " ++ show node)
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

type IdClosure = BC.ByteString

-- The remote closure ids for each node connection
data Closure = Closure SessionId IdClosure [Int] deriving (Read, Show, Typeable)

type RemoteClosure = (Node, IdClosure)

newtype JobGroup = JobGroup (M.Map BC.ByteString RemoteClosure) deriving (Typeable)

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

    (Closure _ closr _) <-
      getIndexData (idConn conn) `onNothing` error "stopRemoteJob: Connection not set, use wormhole"
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
        com <- getState
        -- mcont <- liftIO $ modifyMVar localClosures $ \map -> return ( M.delete closr map,  M.lookup closr map)
        mlc <- liftIO $ atomically $ readDBRef $ getDBRef $ kLocalClos (idConn com) (closr)
        let mcont = fmap localCont mlc
        case mcont of
          Nothing -> error $ "closure not found: " ++ show closr
          Just Nothing -> error $ "closure not found: " ++ show closr
          Just (Just cont) -> do
            -- topState >>= showThreads
            liftIO $ killBranch' cont
            return ()

execLog :: StreamData NodeMSG -> TransIO ()
execLog mlog = Transient $ do
  tr "EXECLOG"
  st <- get
  tr ("execlog", threadId $ fromJust $ unsafePerformIO $ readIORef $ parent st)
  case mlog of
    SError e -> do
      tr ("SERROR", e)
      case fromException e of
        Just (ErrorCall str) -> do
          case read str of
            (e@(CloudException _ s1 closl err)) -> do
              processMessage s1 closl (error "session: should not be used") (error "closr: should not be used") (Left e) True
    SDone -> runTrans (back $ ErrorCall "SDone") >> return Nothing -- TODO remove closure?
    SMore (ClosureData s1 closl s2 closr log) -> processMessage closl s1 closr s2 (Right log) False
    SLast (ClosureData s1 closl s2 closr log) -> processMessage closl s1 closr s2 (Right log) True
  
processMessage :: SessionId -> IdClosure -> SessionId -> IdClosure -> (Either CloudException Builder) -> Bool -> StateIO (Maybe ())
processMessage s1 closl s2 closr mlog deleteClosure = do
      -- tr("processMessage",closl,closr,deleteClosure)
      conn <- getData `onNothing` error "Listen: myNode not set"
      -- if closl== 0 then do
      -- --  if deleteClosure then return False else do
      --     case mlog of
      --       Left except -> do
      --         setData emptyLog
      --         tr "Exception received from network 1"
      --         runTrans $ throwt except
      --         empty
      --       Right log -> do
      --         tr ("CLOSURE 0",log)
      --         -- full'= dropEnd mempty 0 0 $  toLazyByteString log
      --         setData Log{recover= True,  fulLog= LD[LE log],  hashClosure= 0} --Log True [] []

      --         -- setState $ Closure  closr
      --         conn <- getData `onNothing` error "no connection"
      --         let idata = getEnd $ LD[LE log]

      --         setIndexData (idConn conn) (Closure s2 closr,idata :: [Int])

      --         -- setRState $ DialogInWormholeInitiated True
      --         return $ Just()
      --  else do
      --  mcont <- liftIO $ modifyMVar localClosures
      --                  $ \map -> return (if  deleteClosure then
      --                                    M.delete closl map
      --                                  else map, M.lookup closl map)

      let dbref = getDBRef $ kLocalClos s1 closl
      tr ("lookup", dbref)
      mcont <- liftIO $ atomically $ readDBRef dbref
      -- when deleteClosure $ liftIO $ atomically $ flushDBRef dbref
      case mcont of
        Nothing -> do
          cdata <- liftIO $ readIORef $ connData conn 
          case cdata of 
            Just(HTTP2Node _ _ _ _) -> runTrans $ msend conn $ "\r\n" <> chunked   "404: not found"  <> endChunk
            Just (HTTPS2Node _)     -> runTrans $ msend conn $ "\r\n" <> chunked   "404: not found"  <> endChunk
            _ -> do
              node <- liftIO $ readIORef (remoteNode conn) `onNothing` error "mconnect: no remote node?"
              let e = "request received for non existent closure: " ++ show dbref
              let err = CloudException node s1 closl $ show e

              throw err
          return Nothing
        Just LocalClosure {localCont = Nothing} -> do
          tr "RESTORECLOSuRE"
          restoreClosure s1 closl
          tr "AFTER RESTORECLOS"
          processMessage s1 closl s2 closr mlog deleteClosure

        -- execute the closure
        Just LocalClosure {localClos = closLocal, localMvar = mv, localEvar = Just ev, localCont = Just cont} -> do
          when (synchronous conn) $ liftIO $ tryPutMVar mv () >> return () -- for syncronous streaming
          case mlog of
            Right log -> do
              tr ("WRITEEVAR", s2, closl)
              
              -- conn <- getData `onNothing` error "no connection" :: StateIO Connection
              runTrans $
                if deleteClosure
                  then writeEVar ev $ Right (SLast log, s2, closr, conn)
                  else writeEVar ev $ Right (SMore log, s2, closr, conn)
            Left except -> do
              runTrans $ writeEVar ev $ Left except
              empty

          -- void $ liftIO $ runStateT (case mlog of
          --   Right log -> do

          --     -- Log _ _ fulLog hashClosure <- getData `onNothing` return (Log True [] [] 0)
          --     Log{fulLog=fulLog, hashClosure=hashClosure} <- getLog
          --     -- return() !> ("fullog in execlog", reverse fulLog)

          --     let nlog= fulLog <> log    -- let nlog= reverse log ++ fulLog
          --     setData $ Log{recover= True, buildLog=  mempty, fulLog= nlog, lengthFull=error "lengthFull TODO", hashClosure= hashClosure}  -- TODO hashClosure must change?
          --     setState $ Closure  closr
          --     setRState $ DialogInWormholeInitiated True
          --     setParseString $ toLazyByteString log

          --     -- put cont'
          --     runContinuation cont ()

          --   Left except -> do
          --     setData emptyLog
          --     tr ("Exception received from the network", except)
          --     runTrans $ throwt except) cont

          return Nothing

{-
setLog idConn log s2 closr= do
  Log{fulLog=fulLog, hashClosure=hashClosure} <- getLog
  tr("SETLOG",toPath fulLog,log)
  let nlog=  fulLog <> LD[LE log ]
  setData $ Log{fromCont=False,recover= True,  fulLog= nlog,  hashClosure= hashClosure}  -- TODO hashClosure must change?
  tr("NLOG", nlog,toPath nlog)
  let idata = getEnd nlog

  setIndexData idConn (Closure s2 closr,   idata:: [Int])
  tr ("SEtTING RREMOTE CLOSURE",idConn,closr,nlog,idata)
  setParseString $ toLazyByteString log
-}

setLog idConn log sessionId closr = do
  -- Log{fulLog=fulLog, hashClosure=hashClosure} <- getLog
  -- tr("SETLOG",toPath fulLog,log)
  -- let nlog=  fulLog <> LD[LE log ]
  -- setData $ Log{fromCont=False,recover= True,  fulLog= nlog,  hashClosure= hashClosure}  -- TODO hashClosure must change?
  -- tr("NLOG", nlog,toPath nlog)
  -- let idata = getEnd nlog

  -- hay que posponer y pasar setIndexData a logged, solo hacer setParseString aqui
  -- añadir a Log idConn y idata
  -- la primera vez que parsestring= null poner el idata en el indexData
  --         campo indexData :: [Int]
  --      if parseString== mempty && pendingSetIndexData log then do
  --        conn <- getData `onNothing` error "no connection"
  --        hacer withIndexData (idConn conn) $ \(clos,_) ->(clos,indexData log))
  -- hacer el getEnd continuamente.

  {-
     si exe, añadir un nivel. si no añadir uno al ultimo.
     setIndexData idConn idsession closr Nothing
  -}
  setIndexData idConn (Closure sessionId closr [])
  setParseString $ toLazyByteString log
  tr ("setLog", idConn, Closure sessionId closr [], log)

  modifyData' (\log -> log {recover = True}) (error "setLog no log")

  tr "SETLOG recover= True"
  return ()

#ifdef ghcjs_HOST_OS
listen node = onAll $ do
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

type Pool = [Connection]
type SKey = String
type SValue = String
type Service = [(SKey, SValue)]

instance Default Service where
  def=  [("service","$serviceName")
        ,("executable", "$execName")
        ,("package","$gitRepo")]

instance Default [Service] where
  def= [def]


lookup2 key doubleList =
  let r = mapMaybe (lookup key) doubleList
   in if null r then Nothing else Just $ head r

filter2 key doubleList = mapMaybe (lookup key) doubleList

--------------------------------------------
#ifndef ghcjs_HOST_OS



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

servePage (method, uri, headers) = do
  --   return ()                        !> ("HTTP request",method,uri, headers)
  conn <- getSData <|> error " servePageMode: no connection"

  if isWebSocketsReq headers
    then return ()    -- Not elegant, but it works
    else do
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
          (Just <$> BL.readFile ("./static/out.jsexe/" ++ dropWhile (== '.') (BC.unpack file)))
            `catch` (\(e :: SomeException) -> return Nothing)

      --                                    return  "Not found file: index.html<br/> please compile with ghcjs<br/> ghcjs program.hs -o static/out")
      case mcontent of
        Just content -> do
          let mime = defaultMimeLookup $ decodeUtf8 file
          cook <- liftIO $ readIORef rcookie
          liftIO $
            sendRaw conn $
              "HTTP/1.0 200 OK\r\nContent-Type: " <> BL.fromStrict mime <> "\r\nConnection: close\r\nContent-Length: "
                <> BS.pack (show $ BL.length content)
                <> "\r\n"
                <> "Set-Cookie:"
                <> "cookie="
                <> cook -- <> "\r\n"
                <> "\r\n\r\n"
                <> content
        Nothing ->
          liftIO $
            sendRaw conn $
              BS.pack $
                "HTTP/1.0 404 Not Found\nContent-Length: 13\r\nConnection: close\r\n\r\nNot Found 404"
      empty

api :: TransIO BS.ByteString -> Cloud ()
api w = Cloud $ do
  log <- getLog
  if not $ recover log
    then empty
    else do
      -- HTTPHeaders (_, _, vers) hdrs <- getState <|> error "api: no HTTP headers???"
      conn <- getState <|> error "api: Need a connection opened with initNode, listen, simpleWebApp"
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
    . filter ((== mk "Sec-WebSocket-Key") . fst)

data HTTPMethod = GET | POST deriving (Read, Show, Typeable, Eq,Generic)

instance Loggable HTTPMethod

instance ToJSON HTTPMethod

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

--  line= do
--   dropSpaces
--   tTakeWhile (not . endline)

type PostParams = [(BS.ByteString, String)]

parsePostUrlEncoded :: TransIO PostParams
parsePostUrlEncoded = do
  dropSpaces
  many $ (,) <$> param <*> value
  where
    param = tTakeWhile' (/= '=') -- !> "param"
    value = unEscapeString <$> BS.unpack <$> tTakeWhile' (/= '&')

getHeaders = manyTill paramPair (string "\r\n\r\n") -- !>  (method, uri, vers)
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
#ifdef ghcjs_HOST_OS
isBrowserInstance= True
api _= empty
#else
-- | Returns 'True' if we are running in the browser.
isBrowserInstance= False

#endif

{-# NOINLINE emptyPool #-}
emptyPool :: MonadIO m => m (MVar Pool)
emptyPool = liftIO $ newMVar []

-- | Create a node from a hostname (or IP address), port number and a list of
-- services.
createNodeServ :: NS.HostName -> Int -> [Service] -> IO Node
createNodeServ h p svs = return $ Node h p Nothing svs

createNode :: NS.HostName -> Int -> IO Node
createNode h p = createNodeServ h p []

createWebNode :: IO Node
createWebNode = do
  pool <- emptyPool
  port <- randomIO
  return $ Node "webnode" port (Just pool) [[("webnode", "")]]

instance Eq Node where
  Node h p _ _ == Node h' p' _ _ = h == h' && p == p'

instance Show Node where
  show (Node h p _ servs) = show (h, p, servs)

instance Read Node where
  readsPrec n s =
    let r = readsPrec n s
     in case r of
          [] -> []
          [((h, p, ss), s')] -> [(Node h p Nothing ss, s')]

nodeList :: TVar [Node]
nodeList = unsafePerformIO $ newTVarIO []

--myNode :: Int -> DBRef  MyNode
--myNode= getDBRef $ key $ MyNode undefined

errorMyNode f = error $ f ++ ": Node not set. initialize it with connect, listen, initNode..."

-- | Return the local node i.e. the node where this computation is running.
getMyNode :: TransIO Node
getMyNode = do
  Connection {myNode = node} <- getSData <|> errorMyNode "getMyNode" :: TransIO Connection
  liftIO $ readIORef node

-- | empty if the node is not set
getMyNodeMaybe = do
  Connection {myNode = node} <- getSData
  liftIO $ readIORef node

-- | Return the list of nodes in the cluster.
getNodes :: MonadIO m => m [Node]
getNodes = liftIO $ atomically $ readTVar nodeList

-- | get the nodes that have the same service definition that the calling node
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

matchNodes f = do
  nodes <- getNodes
  return $ Prelude.map (\n -> filter f $ nodeServices n) nodes

-- | Add a list of nodes to the list of existing nodes know locally.
-- If the node is already present, It add his services to the already present node
-- services which have the first element equal (usually the "name" field) will be substituted if the match
addNodes :: [Node] -> TransIO ()
addNodes nodes = liftIO $ do
  -- the local node should be the first
  nodes' <- mapM fixNode nodes
  atomically $ mapM_ insert nodes'
  where
    insert node = do
      prevnodes <- readTVar nodeList -- !> ("ADDNODES", nodes)
      let mn = filter (== node) prevnodes

      case mn of
        [] -> do tr "NUEVO NODO"; writeTVar nodeList $ (prevnodes) ++ [node]
        [n] -> do
          let nservices = nubBy (\s s' -> head s == head s') $ nodeServices node ++ nodeServices n
          writeTVar nodeList $ ((prevnodes) \\ [node]) ++ [n {nodeServices = nservices}]
          unsafeIOToSTM $ do
            cs' <- if isJust (connection node) then readMVar $ fromJust $ connection node else return []
            modifyMVar (fromJust $ connection n) $ \cs -> return (cs' ++ cs, ())
        _ -> error $ "duplicated node: " ++ show node

--writeTVar nodeList $  (prevnodes \\ nodes') ++ nodes'

delNodes nodes = liftIO $
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
  nodes' <- mapM fixNode nodes
  atomically $ writeTVar nodeList nodes'

-- | Shuffle the list of cluster nodes and return the shuffled list.
shuffleNodes :: MonadIO m => m [Node]
shuffleNodes = liftIO . atomically $ do
  nodes <- readTVar nodeList
  let nodes' = Prelude.tail nodes ++ [Prelude.head nodes]
  writeTVar nodeList nodes'
  return nodes'

--getInterfaces :: TransIO TransIO HostName
--getInterfaces= do
--   host <- logged $ do
--      ifs <- liftIO $ getNetworkInterfaces
--      liftIO $ mapM_ (\(i,n) ->putStrLn $ show i ++ "\t"++  show (ipv4 n) ++ "\t"++name n)$ zip [0..] ifs
--      liftIO $ putStrLn "Select one: "
--      ind <-  input ( < length ifs)
--      return $ show . ipv4 $ ifs !! ind

-- #ifndef ghcjs_HOST_OS
--instance Read NS.SockAddr where
--    readsPrec _ ('[':s)=
--       let (s',r1)= span (/=']')  s
--           [(port,r)]= readsPrec 0 $ tail $ tail r1
--       in [(NS.SockAddrInet6 port 0 (IP.toHostAddress6 $  read s') 0, r)]
--    readsPrec _ s=
--       let (s',r1)= span(/= ':') s
--           [(port,r)]= readsPrec 0 $ tail r1
--       in [(NS.SockAddrInet port (IP.toHostAddress $  read s'),r)]
-- #endif

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
  conn <- getState <|> error "addThisNodeToRemote: connection not found"
  ref <- liftIO $ newMVar [conn]
  return node {connection = Just ref}

-- | Add a node (first parameter) to the cluster using a node that is already
-- part of the cluster (second parameter).  The added node starts listening for
-- incoming connections and the rest of the computation is executed on this
-- newly added node.
connect :: Node -> Node -> Cloud ()
#ifndef ghcjs_HOST_OS
connect node remotenode = do
  listen node <|> return ()
  connect' remotenode

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
  callNodes' nodes (<>) mempty $
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
      local $ tr "EXPLORENETTTTTTTTTTTT"
      action `op` otherNodes
      where
        otherNodes = do
          node <- local getMyNode
          nodes <- local getNodes'
          tr ("NODES to explore", nodes)
          let nodesToExplore = Prelude.tail nodes \\ (node : nodesexclude)
          callNodes' nodesToExplore op init $
            exploreNetExclude (union (node : nodesexclude) nodes)

        getNodes' = getEqualNodes -- if isBrowserInstance then  return <$>getMyNode  -- getEqualNodes
        -- else (++) <$>  getEqualNodes <*> getWebNodes

exploreNet :: (Loggable a, Monoid a) => Cloud a -> Cloud a
exploreNet = foldNet mappend mempty

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

delta = 60 -- 3*60

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

cleanConnectionData c = liftIO $ do
  -- reset the remote accessible closures
  -- modifyMVar_ (localClosures c) $ const $ return M.empty
  rs <- atomically $ localCon .==. idConn c
  atomically $ mapM flushDBRef rs -- (\r -> do reg <- readDBRef r;writeDBRef r reg{localCont=Nothing}) rs
  return ()

{-
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

-- | restore the continuation recursively from older
getClosureLog :: Int -> BC.ByteString -> StateIO (LogData, LogData, EventF)
getClosureLog idConn "0" = do
  tr ("getClosureLog", idConn, 0)

  clos <- liftIO $ atomically $ (readDBRef $ getDBRef $ kLocalClos 0 "0") `onNothing` error "closure 0 not found in DB"
  let cont = fromMaybe (error "please run flowAssign before") $localCont clos
  return (localLog clos, mempty, cont)
getClosureLog idConn clos = do
  tr ("getClosureLog", idConn, clos)
  clos <- liftIO $ atomically $ (readDBRef $ getDBRef $ kLocalClos idConn clos) `onNothing` error ("closure not found in DB:" <> show (idConn,clos))

  prev <- liftIO $ atomically $ readDBRef (prevClos clos) `onNothing` error "prevClos not found"
  case localCont clos of
    Nothing -> do
      (baselog, prevLog, cont) <- getClosureLog (localCon prev) (localClos prev)
      let locallogclos = localLog clos
      tr ("PREVLOG", prevLog)
      tr ("LOCALLOG", locallogclos)
      tr ("SUM", prevLog `joinlog` locallogclos)
      return (baselog, prevLog `joinlog` locallogclos, cont)
    Just cont -> return (localLog clos, mempty, cont)

-- | cold restore  of the closure from the log drom data stored in permanent storage, and run form that point on
restoreClosure _ "0" = return ()
restoreClosure idConn (clos :: BC.ByteString) = do
  tr ("restoreclosure", idConn, clos)
  (_, LD log, cont) <- getClosureLog idConn clos
  -- cont is the nearest continuation above which is loaded and running
  -- log contains what is necessary to recover to get the continuation that we want to restore
  let mf = mfData cont
  let logbase = fromMaybe emptyLog $ unsafeCoerce $ M.lookup (typeOf emptyLog) mf
      LD lb = fulLog logbase
  -- let log'=  LD $ lb <> log

  -- tr ("TOTAL LOG", log')

  let mf' = M.insert (typeOf emptyLog) (unsafeCoerce $ logbase {recover = True {-,fromCont=False -}}) mf

  let parses = toLazyByteString $ toPathLon $ LD log
  let cont' = cont {parseContext = (parseContext cont) {buffer = parses}, mfData = mf'}
  tr ("SET parseString", toPathLon $ LD log, "short", toPath $ LD log)
  modify (\s -> s{execMode=Remote})
  void $ liftIO $ do
    --  (_,cont'') <-
     runStateT (runCont cont') cont' `catch` exceptBack cont'
    --  liftIO $ print "RUNSTATEEEE"
    --  exceptBackg cont''  $ Finish $ "job " <> show (unsafePerformIO myThreadId)
    --  liftIO $ print "RUNSTATEEEE2222"

