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
{-# LANGUAGE DeriveDataTypeable , ExistentialQuantification, OverloadedStrings,FlexibleInstances, UndecidableInstances
    ,ScopedTypeVariables, StandaloneDeriving, RecordWildCards, FlexibleContexts, CPP
    ,GeneralizedNewtypeDeriving #-}
module Transient.Move.Internals where

import Prelude hiding(drop,length)

import Transient.Internals
import Transient.Parse
import Transient.Logged
import Transient.Indeterminism
import Transient.Mailboxes
import Transient.EVars


import Data.Typeable
import Control.Applicative
import System.Random
import Data.String
import qualified Data.ByteString.Char8                  as BC
import qualified Data.ByteString.Lazy.Char8             as BS

import System.Time
import Data.ByteString.Builder


#ifndef ghcjs_HOST_OS
import Network
--- import Network.Info
import Network.URI
--import qualified Data.IP                              as IP
import qualified Network.Socket                         as NS
import qualified Network.BSD                            as BSD
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
import           Data.JSString  (JSString(..), pack,drop,length)

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
import Data.List (partition,union,(\\),length) -- (nub,(\\),intersperse, find, union, length, partition)
--import qualified Data.List(length)
import Data.IORef

import Control.Concurrent

import System.Mem.StableName
import Unsafe.Coerce
import System.Mem.StableName

{- TODO
  timeout for closures: little smaller in sender than in receiver
-}

--import System.Random

#ifdef ghcjs_HOST_OS
type HostName  = String
newtype PortID = PortNumber Int deriving (Read, Show, Eq, Typeable)
#endif

data Node= Node{ nodeHost   :: HostName
               , nodePort   :: Int
               , connection :: Maybe (MVar Pool)
               , nodeServices   :: Service
               }

         deriving (Typeable)

instance Loggable Node

instance Ord Node where
   compare node1 node2= compare (nodeHost node1,nodePort node1)(nodeHost node2,nodePort node2)


-- The cloud monad is a thin layer over Transient in order to make sure that the type system
-- forces the logging of intermediate results
newtype Cloud a= Cloud {runCloud' ::TransIO a} deriving (AdditionalOperators,Functor,
#if MIN_VERSION_base(4,11,0)
                   Semigroup,
#endif
                   Monoid ,Applicative, Alternative,MonadFail, Monad, Num, Fractional, MonadState EventF)

{-
instance Applicative Cloud where
  pure a  = Cloud $ return  a

  Cloud mf <*> Cloud mx = do
    -- bp <- getData `onNothing` error "no backpoint"
    -- local $ onExceptionPoint bp $ \(CloudException _ _ _) -> continue
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



-- | Execute a distributed computation inside a TransIO computation.
-- All the  computations in the TransIO monad that enclose the cloud computation must be `logged`
runCloud :: Cloud a -> TransIO a

runCloud x= do
       closRemote  <- getRState <|> return (Closure  0)
       runCloud' x <*** setData  closRemote


--instance Monoid a => Monoid (Cloud a) where
--  f mappend x y = mappend <$> x <*> y
--   mempty= return mempty

#ifndef ghcjs_HOST_OS

--- empty Hooks for TLS

{-# NOINLINE tlsHooks #-}
tlsHooks ::IORef (SData -> BS.ByteString -> IO ()
                 ,SData -> IO B.ByteString
                 ,NS.Socket -> BS.ByteString -> TransIO ()
                 ,String -> NS.Socket -> BS.ByteString -> TransIO ()
                 ,SData -> IO ())
tlsHooks= unsafePerformIO $ newIORef
                 ( notneeded
                 , notneeded
                 , \_ i ->  tlsNotSupported i
                 , \_ _ _->  return()
                 , \_ -> return())

  where
  notneeded= error "TLS hook function called"



  tlsNotSupported input = do
     if ((not $ BL.null input) && BL.head input  == 0x16)
       then  do
         conn <- getSData
         sendRaw conn $ BS.pack $ "HTTP/1.0 525 SSL Handshake Failed\r\nContent-Length: 0\nConnection: close\r\n\r\n"
       else return ()

(sendTLSData,recvTLSData,maybeTLSServerHandshake,maybeClientTLSHandshake,tlsClose)= unsafePerformIO $ readIORef tlsHooks


#endif

-- | Means that this computation will be executed in the current node. the result will be logged
-- so the closure will be recovered if the computation is translated to other node by means of
-- primitives like `beamTo`, `forkTo`, `runAt`, `teleport`, `clustered`, `mclustered` etc
local :: Loggable a => TransIO a -> Cloud a
local =  Cloud . logged

--stream :: Loggable a => TransIO a -> Cloud (StreamVar a)
--stream= Cloud . transport

-- #ifndef ghcjs_HOST_OS
-- | Run a distributed computation inside the IO monad. Enables asynchronous
-- console input (see 'keep').
runCloudIO :: Typeable a =>  Cloud a -> IO (Maybe a)
runCloudIO (Cloud mx)= keep mx

-- | Run a distributed computation inside the IO monad with no console input.
runCloudIO' :: Typeable a =>  Cloud a -> IO (Maybe a)
runCloudIO' (Cloud mx)=  keep' mx

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

--

onAll ::  TransIO a -> Cloud a
onAll =  Cloud

-- | only executes if the result is demanded. It is useful when the conputation result is only used in
-- the remote node, but it is not serializable. All the state changes executed in the argument with
-- `setData` `setState` etc. are lost
lazy :: TransIO a -> Cloud a
lazy mx= onAll $ do
        st <- get
        return $ fromJust $ unsafePerformIO $ runStateT (runTrans mx) st >>=  return .fst


-- | executes a non-serilizable action in the remote node, whose result can be used by subsequent remote invocations
fixRemote mx= do
             r <- lazy mx
             fixClosure
             return r

-- | subsequent remote invocatioms will send logs to this closure. Therefore logs will be shorter.
--
-- Also, non serializable statements before it will not be re-executed
fixClosure= atRemote $ local $  async $ return ()

-- log the result a cloud computation. Like `loogged`, this erases all the log produced by computations
-- inside and substitute it for that single result when the computation is completed.
loggedc :: Loggable a => Cloud a -> Cloud a
loggedc (Cloud mx)= Cloud $ do
     closRemote  <- getRState <|> return (Closure  0 )
     (fixRemote :: Maybe LocalFixData) <- getData
     logged mx <*** do setData  closRemote
                       when (isJust fixRemote) $ setState (fromJust fixRemote)



loggedc' :: Loggable a => Cloud a -> Cloud a
loggedc' (Cloud mx)= Cloud $ do
      fixRemote :: Maybe LocalFixData <- getData
      logged mx <*** (when (isJust fixRemote) $ setState (fromJust fixRemote))




-- | the `Cloud` monad has no `MonadIO` instance. `lliftIO= local . liftIO`
lliftIO :: Loggable a => IO a -> Cloud a
lliftIO= local . liftIO

-- |  `localIO = lliftIO`
localIO :: Loggable a => IO a -> Cloud a
localIO= lliftIO



-- | continue the execution in a new node
beamTo :: Node -> Cloud ()
beamTo node =  wormhole node teleport


-- | execute in the remote node a process with the same execution state
forkTo  :: Node -> Cloud ()
forkTo node= beamTo node <|> return()

-- | open a wormhole to another node and executes an action on it.
-- currently by default it keep open the connection to receive additional requests
-- and responses (streaming)
callTo :: Loggable a => Node -> Cloud a -> Cloud a
callTo node  remoteProc= wormhole' node $ atRemote remoteProc


#ifndef ghcjs_HOST_OS
-- | A connectionless version of callTo for long running remote calls
callTo' :: (Show a, Read a,Typeable a) => Node -> Cloud a -> Cloud a
callTo' node remoteProc=  do
    mynode <-  local $ getNodes >>= return . Prelude.head
    beamTo node
    r <-  remoteProc
    beamTo mynode
    return r
#endif

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
atRemote proc=  loggedc' $ do
     --modify $ \s -> s{execMode=Parallel}
     teleport                                             --  !> "teleport 1111"

     modify $ \s -> s{execMode= if execMode s== Parallel then Parallel else Serial}   -- modifyData' f1 Serial
     {-
     local $ noTrans $ do
        cont <- get

        let loop=do
            chs <- liftIO $ readMVar $ children $ fromJust $ parent cont

            return () !> ("THREADS ***************", length chs)
            threadDelay 1000000
            loop

        liftIO $ forkIO loop

        return()
     -}
     r <-  loggedc $ proc  <** modify (\s -> s{execMode= Remote}) -- setData Remote

     teleport                                              -- !> "teleport 2222"

     return r


-- | Execute a computation in the node that initiated the connection.
--
-- if the sequence of connections is  n1 -> n2 -> n3 then  `atCallingNode $ atCallingNode foo` in n3
-- would execute `foo` in n1, -- while `atRemote $ atRemote foo` would execute it in n3
-- atCallingNode :: Loggable a => Cloud a -> Cloud a
-- atCallingNode proc=  connectCaller $ atRemote proc

-- | synonymous of `callTo`
runAt :: Loggable a => Node -> Cloud a -> Cloud a
runAt= callTo


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
single f= do
   cutExceptions
   Connection{closChildren=rmap} <- getSData <|> error "single: only works within a connection"
   mapth <- liftIO $ readIORef rmap
   id <- liftIO $ f `seq` makeStableName f >>= return .  hashStableName


   case  M.lookup id mapth of
          Just tv -> liftIO $ killBranch'  tv
          Nothing ->  return ()


   tv <- get
   f <** do
          id <- liftIO $ makeStableName f >>= return . hashStableName
          liftIO $ modifyIORef rmap $ \mapth -> M.insert id tv mapth


-- | run an unique continuation for each connection. The first thread that execute `unique` is
-- executed for that connection. The rest are ignored.
unique :: TransIO a -> TransIO a
unique f= do
   Connection{closChildren=rmap} <- getSData <|> error "unique: only works within a connection. Use wormhole"
   mapth <- liftIO $ readIORef rmap
   id <- liftIO $ f `seq` makeStableName f >>= return .  hashStableName

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
wormhole node comp=  do
    onAll $ onException $ \(e@(ConnectionError "no connection" nodeerr)) ->
                   if nodeerr== node then do runCloud' $ findRelay node ; continue else return ()
    wormhole' node comp


    where
    findRelay node = do
       relaynode <- exploreNetUntil $ do
                  nodes <- local getNodes
                  let thenode= filter (== node) nodes
                  if not (null  thenode) && isJust(connection $ Prelude.head thenode )  then return $ Prelude.head nodes else empty
       local $ addNodes [node{nodeServices= nodeServices node ++ [("relay", show (nodeHost (relaynode :: Node),nodePort relaynode ))]}]


-- | wormhole without searching for relay nodes.
wormhole' :: Loggable a => Node -> Cloud a -> Cloud a
wormhole' node (Cloud comp) = local $ Transient $ do

   moldconn <- getData :: StateIO (Maybe Connection)
   mclosure <- getData :: StateIO (Maybe (Ref Closure))
      -- when (isJust moldconn) . setState $ ParentConnection (fromJust moldconn) mclosure

   labelState $ "wormhole" <> BC.pack (show node)
   log <- getLog
  
   if not $ recover log
            then runTrans $ (do
                    conn <-  mconnect node
                    
                    liftIO $ writeIORef (remoteNode conn) $ Just node
                    setData  conn{synchronous= maybe False id $ fmap synchronous moldconn, calling= True}


                    ref <- newRState  $ Closure 0
                    --lhls <- liftIO $ atomicModifyIORef (wormholes conn) $ \hls -> ((ref:hls),length  hls)
                    --return () !> ("LENGTH HLS",lhls)


                    comp )
                  <*** do
                       when (isJust moldconn) . setData $ fromJust moldconn
                       when (isJust mclosure) . setData $ fromJust mclosure
                    -- <** is not enough since comp may be reactive
            else do
                    -- return () !> "YES REC"
                    let conn = fromMaybe (error "wormhole: no connection in remote node") moldconn
                    setData $ conn{calling= False}
                    runTrans $ comp
                             <***  do when (isJust mclosure) . setData $ fromJust mclosure



-- #ifndef ghcjs_HOST_OS
-- type JSString= String
-- pack= id
-- #endif

data CloudException = CloudException Node IdClosure   String deriving (Typeable, Show, Read)

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
setSynchronous sync= do
   modifyData'(\con -> con{synchronous=sync}) (error "setSynchronous: no communication data")
   return ()

-- set synchronous mode for remote calls within a cloud computation and also avoid unnecessary
-- thread creation
syncStream :: Cloud a -> Cloud a
syncStream proc=  do
    sync <- local $ do
      Connection{synchronous= synchronous} <- modifyData'(\con -> con{synchronous=True}) err
      return synchronous
    Cloud $ threads 0 $ runCloud' proc <***  modifyData'(\con -> con{synchronous=sync})  err
    where err= error "syncStream: no communication data"



teleport :: Cloud ()
teleport  =  do

  modify $ \s -> s{execMode=if execMode s == Remote then Remote else Parallel}
  local $ do
    conn@Connection{connData=contype, synchronous=synchronous, localClosures= localClosures,calling= calling} <- getData
                             `onNothing` error "teleport: No connection defined: use wormhole"
    onException $ \(e :: IOException ) -> do
         return () !> ("teleport:", e)    -- should be three tries at most
         liftIO $ writeIORef contype Nothing
         mclose conn  -- msend will open a new connection. move that open here?

         continue

    Transient $ do
     labelState  "teleport"

     cont <- get

     log <- getLog


     if not $ recover log   -- !> ("teleport rec,loc fulLog=",rec,log,fulLog)
                  -- if is not recovering in the remote node then it is active

      then  do



        -- when a node call itself, there is no need of socket communications
        ty <- liftIO $ readIORef contype
        case ty of
         Just Self -> runTrans $ do
               modify $ \s -> s{execMode= Parallel}  -- setData  Parallel
               abduce    -- !> "SELF" -- call himself
               liftIO $ do
                  remote <- readIORef $ remoteNode conn
                  writeIORef (myNode conn) $ fromMaybe (error "teleport: no connection?") remote


         _ -> do


         --read this Closure
          Closure closRemote <- getRData `onNothing`  return (Closure 0 )
          return ()  !>  ("REMOTE CLOSURE",closRemote)
          (closRemote',tosend) <- if closRemote /= 0 -- && isJust ty
                      -- for localFix
                then return (closRemote, buildLog log)
                else do
                  mfix <-  getData  -- mirar  globalFix
                  return () !> ("mfix", mfix)
                  let droplog  Nothing= return (0, fulLog log)
                      droplog  (Just localfix)= do
                        sent  <- liftIO $ atomicModifyIORef' (fixedConnections localfix) $ \list -> do
                                        let n= idConn conn
                                        if n `Prelude.elem` list
                                                  then  (list, True)
                                                  else  (n:list,False)


                        return () !> ("LOCALFIXXXXXXXXXX",localfix)
                        let dropped= lazyByteString $ BS.drop (fromIntegral $ lengthFix localfix) $ toLazyByteString $  fulLog log
                        if sent then return (closure localfix, dropped)
                        else if isService localfix then return (0,  dropped)
                        else droplog  $ prevFix localfix -- look for other previous closure sent


                  droplog  mfix


          let closLocal= hashClosure log
          map <- liftIO  $  readMVar localClosures
          let mr = M.lookup closLocal map
          pair <- case mr of
              -- for synchronous streaming
              Just (chs,clos,mvar,_) -> do
                 when synchronous $ liftIO $ takeMVar mvar
                 return()  !> ("TELEPORT removing", (length $unsafePerformIO $  readMVar chs)-1)
                 --ths <- liftIO $  readMVar (children cont)
                 --liftIO $ when (length ths > 1)$  mapM_ (killChildren . children) $ tail ths
                 --runTrans  $  msend conn $ SLast (ClosureData closRemote' closLocal  mempty)
                --no se llama  se hace asincronamente en el  blucle loopclosures
                 return (children ${- fromJust $ parent -} cont,clos,mvar,cont)

              _ -> liftIO  $  do mv <- newEmptyMVar; return ( children $ fromJust $ parent cont,closRemote',mv,cont)

          liftIO $ modifyMVar_ localClosures $ \map ->  return $ M.insert closLocal pair map


          -- The log sent is in the order of execution. log is in reverse order

          -- send log with closure ids at head
          --return () !> ("MSEND --------->------>", SMore (unsafePerformIO $ readIORef $ remoteNode conn,closRemote',closLocal,toLazyByteString tosend))
          runTrans $ msend conn $ SMore $ ClosureData closRemote' closLocal tosend


          return Nothing

      else return $ Just ()






{- |
One problem of forwarding closures for streaming is that it could transport not only the data but extra information that reconstruct the closure in the destination node. In a single in-single out interaction It may not be a problem, but think, for example, when I have to synchronize N editors by forwarding small modifications, or worst of all, when transmitting packets of audio or video. But the size of the closure, that is, the amount of variables that I have to transport increases when the code is more complex. But transient build closures upon closures, so It has to send only what has changed since the last interaction.

In one-to-one interactions whithin a wormhole, this is automatic, but when there are different wormholes involved, it is necessary
to tell explicitly what is the closure that will continue the execution. this is what `localFix` does. otherwise it will use the closure 0.

> main= do
>      filename <- local input
>      source <- atServer $ local $ readFile filename
>      local $ render source inEditor
>     --  send upto here one single time please,  so I only stream the deltas
>      localFix
>      delta <- react  onEachChange
>      forallNodes $ update delta

if forwardChanges send to all the nodes editing the document, the data necessary to reconstruct the
closure would include even the source code of the file on EACH change.
Fortunately it is possible to fix a closure that will not change in all the remote nodes so after that,
I only have to send the only necessary variable, the delta. This is as efficient as an hand-made
socket write/forkThread/readSocket loop for each node.
-}
localFix=  localFixServ False False
type ConnectionId= Int
type HasClosed= Bool
-- for each connection, the list of closures fixed and the list of connections which created that closure in the remote node
-- unificar para todas las conexiones
-- pero como se sabe si una closure global aplica a un envio despues de una desconexion?
-- el programa tiene que pasar por esa globalClosure,
-- si solo se ha perdido la conexión, tiene estado y puede utilizarla
-- si ha rearrancado, ha ejecutado hasta ahi y tiene que reconstruir su estado de localFix

globalFix = unsafePerformIO $ newIORef (M.empty :: M.Map ConnectionId (HasClosed,[(IdClosure, IORef [ConnectionId ])]))
-- how to signal that was closed?

data LocalFixData= LocalFixData{ isService :: Bool
                                , lengthFix :: Int
                                , closure :: Int
                                , fixedConnections :: IORef [ConnectionId] -- List of connections that created
                                                                  -- that closure in the remote node

                                , prevFix :: Maybe LocalFixData} deriving Show

instance Show a => Show (IORef a) where
    show r= show $ unsafePerformIO $ readIORef r

-- data LocalFixData=  LocalFixData Bool Int Int (IORef (M.Map Int Int))

-- first flag=True assumes that the localFix closure has been created otherwise
-- the first request invoke closure 0 and create the localFix closure
-- further request will invoque this closure
--
-- the second flag creates a closure that is invoked ever, even if  localfix is re-executed.
--If this second flag is false,
-- a reexecution of localFix will recreate the remote closure, perhaps with different  variables.
localFixServ isService isGlobal= Cloud $ noTrans $ do
   log <- getLog
   Connection{..} <- getData `onNothing` error "teleport: No connection set: use initNode"

   if recover log
     then do
         cont <- get
         mv <- liftIO  newEmptyMVar
         liftIO $ modifyMVar_ localClosures $ \map ->  return $ M.insert (hashClosure log) ( children $ fromJust $ parent cont,0,mv,cont) map

     else do

         mprevFix <- getData


         ref <- liftIO $ if not $ isGlobal then newIORef [] else do
                  map <- readIORef globalFix
                  return $ do
                      (_,l) <- M.lookup idConn map
                      lookup (hashClosure log) l

              `onNothing` do
                  ref <- newIORef []
                  modifyIORef globalFix $ \map ->
                       let (closed,l)=  fromMaybe (False,[]) $ M.lookup idConn map
                       in  M.insert idConn  (closed,(hashClosure log, ref):l) map
                  return ref
         mmprevFix <- liftIO $ readIORef ref >>= \l -> return $ if Prelude.null l then  Nothing else mprevFix
         let newfix =LocalFixData{ isService =        isService
                                 , lengthFix =        fromIntegral $ BS.length $ toLazyByteString $ fulLog log
                                 , closure =          hashClosure log
                                 , fixedConnections = ref
                                 , prevFix =          mmprevFix}
         setState newfix


           !> ("SET LOCALFIX", newfix )


-- | forward exceptions back to the calling node
reportBack :: TransIO ()
reportBack= onException $ \(e :: SomeException) -> do
    conn <- getData `onNothing` error "reportBack: No connection defined: use wormhole"
    Closure closRemote <- getRData `onNothing` error "teleport: no closRemote"
    node <- getMyNode
    let msg= SError $ toException $ ErrorCall $  show $ show $ CloudException node closRemote $ show e
    msend conn msg  !> "MSEND"



-- | copy a session data variable from the local to the remote node.
-- If there is none set in the local node, The parameter is the default value.
-- In this case, the default value is also set in the local node.
copyData def = do
  r <- local getSData <|> return def
  onAll $ setData r
  return r


-- | execute a Transient action in each of the nodes connected.
--
-- The response of each node is received by the invoking node and processed by the rest of the procedure.
-- By default, each response is processed in a new thread. To restrict the number of threads
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
clustered :: Loggable a  => Cloud a -> Cloud a
clustered proc= callNodes (<|>) empty proc


-- A variant of `clustered` that wait for all the responses and `mappend` them
mclustered :: (Monoid a, Loggable a)  => Cloud a -> Cloud a
mclustered proc= callNodes (<>) mempty proc


callNodes op init proc= loggedc' $ do
    nodes <-  local getEqualNodes
    callNodes' nodes op init proc


callNodes' nodes op init proc= loggedc' $ Prelude.foldr op init $ Prelude.map (\node -> runAt node proc) nodes
-----
#ifndef ghcjs_HOST_OS
sendRaw con r= do
   let blocked= isBlocked con
   c <- liftIO $ readIORef $ connData con
   liftIO $   modifyMVar_ blocked $ const $ do
    case c of
      Just (Node2Web  sconn )   -> liftIO $  WS.sendTextData sconn  r
      Just (Node2Node _ sock _) ->
                            SBS.sendMany sock (BL.toChunks r )

      Just (TLSNode2Node  ctx ) ->
                            sendTLSData ctx  r
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




data NodeMSG= ClosureData IdClosure IdClosure  Builder    deriving (Read, Show)


instance Loggable NodeMSG where
   serialize (ClosureData clos clos' build)= intDec clos <> "/" <> intDec clos' <> "/" <> build
   deserialize= ClosureData <$> (int <* tChar '/') <*> (int <* tChar '/') <*> restOfIt
      where
      restOfIt= lazyByteString <$> giveParseString

instance Show Builder where
   show b= BS.unpack $ toLazyByteString b

instance Read Builder where
   readsPrec _ str= [(lazyByteString $ BS.pack $ read str,"")]


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


msend ::  Connection -> StreamData NodeMSG -> TransIO ()

-- msend (Connection _ _ _ (Just Self) _ _ _ _ _ _ _) r= return ()

#ifndef ghcjs_HOST_OS

msend con r=  do
  return () !> ("MSEND --------->------>", r)
  c <- liftIO $ readIORef $ connData con
  con' <- case c of
     Nothing -> do
         return () !> "CLOSED CON"
         n <- liftIO $ readIORef $ remoteNode con
         case n of
          Nothing -> error "connection closed by caller"
          Just node ->  do
            r <- mconnect node
            -- setRState $ Closure 0

            return r
            --case r of
            --   Nothing -> error $ "can not reconnect with " ++ show n
            --    Just c -> return c
     Just _ -> return con
  let blocked= isBlocked con'
  c <- liftIO $ readIORef $ connData con'
  let bs = toLazyByteString $ serialize r

  liftIO $ modifyMVar_ blocked $ const $ do

    case c of

      Just (TLSNode2Node ctx) -> do
              return () !> "TLSSSSSSSSSSS SEND"
              sendTLSData  ctx $ toLazyByteString $ int64Dec $ BS.length bs
              sendTLSData  ctx bs
      Just (Node2Node _ sock _) -> do
              return () !> "NODE2NODE SEND"
              SBSL.send sock $ toLazyByteString $ int64Dec $ BS.length bs
              SBSL.sendAll sock bs

      Just (HTTP2Node _ sock _)  -> do
              return () !> "HTTP2NODE SEND"
              SBSL.sendAll sock $ bs <> "\r\n"

      Just (HTTPS2Node ctx)  -> do
              return () !> "HTTPS2NODE SEND"
              sendTLSData  ctx $ bs <> "\r\n"

      Just (Node2Web sconn) -> do
         -- {-withMVar blocked $ const $ -} WS.sendTextData sconn $ serialize r -- BS.pack (show r)    !> "websockets send"
           liftIO $   do
              let bs = toLazyByteString $ serialize r
              WS.sendTextData sconn $ toLazyByteString $ int64Dec $ BS.length bs
              WS.sendTextData sconn bs   -- !> ("N2N SEND", bd)

      _ -> error "msend out of connection context: use wormhole to connect"

    TOD time _ <- getClockTime
    return $ Just time


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
   let blocked= isBlocked con
   c <- liftIO $ readIORef $ connData con
   case c of
     Just (Web2Node sconn) -> liftIO $  do
          modifyMVar_ (isBlocked con) $ const $ do -- JavaScript.Web.WebSocket.send (serialize r) sconn -- (JS.pack $ show r) sconn    !> "MSEND SOCKET"
              let bs = toLazyByteString $ serialize r
              JavaScript.Web.WebSocket.send  (pack $ show $ BS.length bs) sconn
              JavaScript.Web.WebSocket.send  ( pack $ show bs) sconn   -- TODO OPTIMIZE THAT!

              TOD time _ <- getClockTime
              return $ Just time



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
  case JM.getData dat of
    JM.StringData ( text)  ->  do
      setParseString $ BS.pack  . JS.unpack $ text    -- TODO OPTIMIZE THAT

      len <- integer

      deserialize     -- return (read' $ JS.unpack str)
                 !> ("Browser webSocket read", text)  !> "<------<----<----<------"
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
     Just (Node2Node _ _ _) -> parallelReadHandler conn
     Just (TLSNode2Node _ ) -> parallelReadHandler conn
     Just (Node2Web sconn ) -> do
            ss <- parallel $  receiveData' conn sconn
            case ss of
              SDone -> empty
              SMore s -> do
                setParseString s
                integer
                TOD t _ <- liftIO getClockTime
                liftIO $ modifyMVar_ (isBlocked conn) $ const  $ Just <$> return t
                deserialize
  where
  -- perform timeouts and cleanup of the server when connections close
  receiveData' :: Connection -> NWS.Connection -> IO (StreamData BS.ByteString)
  receiveData' c conn = do
    msg <- WS.receive conn
    case msg of
        NWS.DataMessage _ _ _ am -> return  $ SMore $ NWS.fromDataMessage am
        NWS.ControlMessage cm    -> case cm of
            NWS.Close i closeMsg -> do
                hasSentClose <- readIORef $ WS.connectionSentClose conn
                unless hasSentClose $ WS.send conn msg
                writeIORef (connData c) Nothing
                cleanConnectionData c
                return SDone

            NWS.Pong _    ->  do
                TOD t _ <- liftIO getClockTime
                liftIO $ modifyMVar_ (isBlocked c) $ const  $ Just <$> return t
                receiveData' c conn
                --NWS.connectionOnPong (WS.connectionOptions conn)
                --NWS.receiveDataMessage conn
            NWS.Ping pl   -> do
                TOD t _ <- liftIO getClockTime
                liftIO $ modifyMVar_ (isBlocked c) $ const  $ Just <$> return t
                WS.send conn (NWS.ControlMessage (NWS.Pong pl))
                receiveData' c conn
                --WS.receiveDataMessage conn
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

many' p= p <|> many' p

parallelReadHandler :: Loggable a => Connection -> TransIO (StreamData a)
parallelReadHandler conn= do
    onException $ \(e:: IOError) -> empty
    many' extractPacket
    where
    extractPacket= do
        len <- integer <|> (do s <- getParseBuffer; error $ show $ ("malformed data received: expected Int, received: ", BS.take 5 s))
        str <- tTake (fromIntegral len)
        return () !> ("MREAD  <-------<-------",str)
        TOD t _ <- liftIO $ getClockTime
        liftIO $ modifyMVar_ (isBlocked conn) $ const  $ Just <$> return t

        abduce
        --topState >>= showThreads

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

mclose con= do
   --c <- liftIO $ readIORef $ connData con
   c <- liftIO $ atomicModifyIORef (connData con) $ \c  -> (Nothing,c)

   case c of
      Just (TLSNode2Node ctx) -> liftIO $ withMVar (isBlocked con) $ const $ liftIO $ tlsClose ctx
      Just (Node2Node _  sock _ ) -> liftIO $ withMVar (isBlocked con) $ const $ liftIO $ NS.close sock !> "SOCKET CLOSE"

      Just (Node2Web sconn ) -> liftIO $ WS.sendClose sconn ("closemsg" :: BS.ByteString) !> "WEBSOCkET CLOSE"
      _ -> return()
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
   c <- atomicModifyIORef (connData con) $ \c  -> (Nothing,c)

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

conSection= unsafePerformIO $ newMVar ()
exclusiveCon mx=  do
   liftIO $ takeMVar conSection
   r <- mx
   liftIO $ putMVar conSection ()
   return r

mconnect' :: Node -> TransIO  Connection
mconnect'  node'=  exclusiveCon $ do
  conn <- do    
      node <-  fixNode node'
      nodes <- getNodes

      let fnode =  filter (==node)  nodes
      case fnode of
        [] -> mconnect1 node                                   -- !> "NO NODE"
        [node'@(Node _ _ pool _)] -> do
            plist <- liftIO $  readMVar $ fromJust pool
            case plist   of                                       -- !>  ("length", length plist,nodePort node) of
              (handle:_) -> do

                    c <- liftIO $ readIORef $ connData handle
                    if isNothing c  -- was closed by timeout
                      then mconnect1 node
                      else return  handle
                                                                !>  ("REUSED!", node)
              _ -> do
                  delNodes [node]
                  mconnect1 node
  -- ctx <- liftIO $ readIORef $ istream conn
  -- modify $ \s -> s{parseContext= ctx}
  -- liftIO $ print  "SET PARSECONTEXT"
  return conn



#ifndef ghcjs_HOST_OS
mconnect1 (node@(Node host port _ _))= do

     return ()  !> ("MCONNECT1",host,port,nodeServices node)
     {-
     onException $ \(ConnectionError msg node) -> do
                 liftIO $ do
                     putStr  msg
                     putStr " connecting "
                     print node
                 continue
                 empty
        -}
     (conn,parseContext) <- checkSelf node                                 <|>
                            timeout 1000000 (connectNode2Node host port)   <|>
                            timeout 1000000 (connectWebSockets host port)  <|>
                            timeout 1000000 checkRelay                     <|>
                            (throw $ ConnectionError "no connection" node)

     setState conn
     modify $ \s -> s{execMode=Serial,parseContext= parseContext}

     --liftIO $ do
     --          whls <- readIORef $ wormholes conn
     --          return () !> ("lenght whls",Data.List.length whls)
     --          mapM (\ref -> writeIORef ref $ Closure 0) whls

     -- "write node connected in the connection"
     liftIO $ writeIORef (remoteNode conn) $ Just node
     -- "write connection in the node"
     liftIO $ modifyMVar_ (fromJust $ connection node) . const $ return [conn]

     addNodes [node]
     
     return  conn


    where
    checkSelf node= do
      -- return () !> "CHECKSELF"
      node' <- getMyNodeMaybe 
      v <- liftIO $ readMVar (fromJust $ connection  node') -- to force connection in case of calling a service of itself
      if node /= node' ||   null v
        then  empty
        else do
          conn<- case connection node of
             Nothing    -> error "checkSelf error"
             Just ref   ->  do
                 rnode  <- liftIO $ newIORef node'
                 cdata <- liftIO $ newIORef $ Just Self
                 conn   <- defConnection >>= \c -> return c{myNode= rnode, connData= cdata}
                 liftIO $ withMVar ref $ const $ return [conn]
                 return conn

          return (conn, noParseContext)

    timeout t proc=  do
       r <- collect' 1 t $ do
          onException $ \(e:: SomeException) -> empty
          proc
       case r of
          []  -> empty         !> "TIMEOUT EMPTY"
          mr:_ -> case mr of
             Nothing -> throw $ ConnectionError "Bad cookie" node
             Just r -> return r

    checkRelay= do
        case lookup "relay" $ nodeServices node of
                    Nothing -> empty  -- !> "NO RELAY"
                    Just relayinfo -> do
                       let (h,p)= read relayinfo
                       connectWebSockets1  h p $  "/relay/"  ++  h  ++ "/" ++ show p ++ "/"


    connectSockTLS host port= do
        return ()                                         !> "connectSockTLS"

        let size=8192
        c@Connection{myNode=my,connData=rcdata} <- getSData <|> defConnection 
        return () !> "BEFORE HANDSHAKE"

        sock  <- liftIO $ connectTo'  size  host $ PortNumber $ fromIntegral port
        let cdata= (Node2Node u  sock (error $ "addr: outgoing connection"))
        cdata' <- liftIO $ readIORef rcdata

        input <-  liftIO $ SBSL.getContents sock
        let pcontext= ParseContext (do mclose c; return SDone) input (unsafePerformIO $ newIORef False)
        conn' <- if isNothing cdata'    -- lost connection, reconnect
          
           then do 
                liftIO $ writeIORef rcdata $  Just cdata
                liftIO $ writeIORef (istream c) pcontext
                return c !> "RECONNECT"
           else do
                c <- defConnection
                rcdata' <- liftIO $ newIORef $ Just cdata
                liftIO $ writeIORef (istream c) pcontext

                return c{myNode=my,connData= rcdata'}  !> "CONNECT"

        setData conn'

        --modify $ \s ->s{parseContext=ParseContext (do NS.close sock ; return SDone) input} --throw $ ConnectionError "connection closed" node) input}
        modify $ \s ->s{execMode=Serial,parseContext=pcontext}
        --modify $ \s ->s{execMode=Serial,parseContext=ParseContext (SMore . BL.fromStrict <$> recv sock 1000) mempty}

        maybeClientTLSHandshake host sock input




    connectNode2Node host port= do
        -- onException $ \(e :: SomeException) -> empty
        return () !> "NODE 2 NODE"
        connectSockTLS host port


        conn <- getSData <|> error "mconnect: no connection data"
        --mynode <- getMyNode
        parseContext <- gets parseContext
        return $ Just(conn,parseContext)
        

    connectWebSockets host port = connectWebSockets1 host port "/"
    connectWebSockets1 host port verb= do
         -- onException $ \(e :: SomeException) -> empty
         return () !> "WEBSOCKETS"
         connectSockTLS host port  -- a new connection

         never  <- liftIO $ newEmptyMVar :: TransIO (MVar ())
         conn   <- getSData <|> error "connectWebSockets: no connection"

         stream <- liftIO $ makeWSStreamFromConn conn
         co <- liftIO $ readIORef rcookie
         let hostport= host++(':': show port)
             headers= [("cookie", "cookie=" <> BS.toStrict co)] -- if verb =="/" then [("Host",fromString hostport)] else []


         onException $ \(NWS.CloseRequest code msg)  -> do
                conn  <- getSData
                cleanConnectionData conn
                -- throw $ ConnectionError (BS.unpack msg) node
                empty

         wscon  <- react (NWS.runClientWithStream stream hostport verb
                                    WS.defaultConnectionOptions headers)
                         (takeMVar never)


         msg <- liftIO $ WS.receiveData wscon
         case msg of


           ("OK" :: BS.ByteString) -> do
              return () !> "return connectWebSockets"
              cdata <- liftIO $ newIORef $ Just $ (Node2Web wscon)
              return $ Just (conn{connData=  cdata}, noParseContext)

           _ -> do return () !> "RECEIVED CLOSE"; liftIO $ WS.sendClose wscon ("" ::BS.ByteString); return Nothing


    
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
                        ""

        chs <- liftIO $ newIORef M.empty
        let conn'= conn{closChildren= chs}
        liftIO $ modifyMVar_ pool $  \plist -> return $ conn':plist
        putMailbox  (conn',parseContext,node)  -- tell listenResponses to watch incoming responses
        --delRData $ Closure undefined
        return  conn'
#endif

u= undefined

data ConnectionError= ConnectionError String Node deriving (Show , Read)

instance Exception ConnectionError

mconnect node'= do
  node <-  fixNode node'
  nodes <- getNodes

  let fnode =  filter (==node)  nodes
  case fnode of
    [] -> mconnect2 node                                   -- !> "NO NODE"
    [node'@(Node _ _ pool _)] -> do
        plist <- liftIO $  readMVar $ fromJust pool
        case plist   of                                       -- !>  ("length", length plist,nodePort node) of
          (handle:_) -> do

                c <- liftIO $ readIORef $ connData handle
                if isNothing c  -- was closed by timeout
                  then mconnect2 node
                  else return  handle
                                                          --  !>  ("REUSED!", node)
          _ -> do
              delNodes [node]
              mconnect2 node
  where
  mconnect2 node= do
    conn <- mconnect1 node
--  `catcht` \(e :: SomeException) -> empty
    cd <- liftIO $ readIORef $ connData conn
    case cd of
        Just Self -> return()
        Just (Node2Node _ _ _) -> do
                  checkCookie conn
                  watchConnection conn node

        _         -> watchConnection conn node
    return conn
   
  checkCookie conn= do 
      cookie <- liftIO $ readIORef rcookie
      mynode <- getMyNode
      sendRaw conn $ "CLOS " <> cookie  <> --" b \r\nField: value\r\n\r\n"  -- TODO put it standard: Set-Cookie:...
          " b \r\nHost: " <> BS.pack (nodeHost mynode) <> "\r\nPort: " <> BS.pack (show $ nodePort mynode) <> "\r\n\r\n"

      r <- liftIO $ readFrom conn

      case r of
        "OK" ->  return ()
        
        _    ->  do
              let Connection{connData=rcdata}= conn
              cdata <- liftIO $ readIORef rcdata
              case cdata of
                    Just(Node2Node _ s _) ->  liftIO $ NS.close s -- since the HTTP firewall closes the connection
                    Just(TLSNode2Node c) -> liftIO $ tlsClose c
              empty

  watchConnection conn node= do
        liftIO $ atomicModifyIORef connectionList $ \m -> (conn:m,())

        parseContext <- gets parseContext -- getSData <|> error "NO PARSE CONTEXT"
                         :: TransIO ParseContext
        chs <- liftIO $ newIORef M.empty
        --whls <- liftIO $ newIORef []
        let conn'= conn{closChildren= chs} --, wormholes= whls}
        -- liftIO $ modifyMVar_ (fromJust pool) $  \plist -> do
        --                  if not (null plist) then print "DUPLICATE" else return ()
        --                  return $ conn':plist    -- !> (node,"ADDED TO POOL")

        -- tell listenResponses to watch incoming responses
        putMailbox  ((conn',parseContext,node) :: (Connection,ParseContext,Node))
        liftIO $ threadDelay 100000  -- give time to initialize listenResponses





#ifndef ghcjs_HOST_OS
close1 sock= do

  NS.setSocketOption sock NS.Linger 0
  NS.close sock

connectTo' bufSize hostname (PortNumber port) =  do
        proto <- BSD.getProtocolNumber "tcp"
        bracketOnError
            (NS.socket NS.AF_INET NS.Stream proto)
            (NS.close)  -- only done if there's an error
            (\sock -> do
              NS.setSocketOption sock NS.RecvBuffer bufSize
              NS.setSocketOption sock NS.SendBuffer bufSize



--              NS.setSocketOption sock NS.SendTimeOut 1000000  !> ("CONNECT",port)

              he <- BSD.getHostByName hostname

              NS.connect sock (NS.SockAddrInet port (BSD.hostAddress he))

              return sock)

#else
connectToWS  h (PortNumber p) = do
   protocol <- liftIO $ fromJSValUnchecked js_protocol
   pathname <- liftIO $ fromJSValUnchecked js_pathname
   return () !> ("PAHT",pathname)
   let ps = case (protocol :: JSString)of "http:" -> "ws://"; "https:" -> "wss://"
   wsOpen $ JS.pack $ ps++ h++ ":"++ show p ++ pathname
#endif


-- last usage+ blocking semantics for sending
type Blocked= MVar (Maybe Integer)
type BuffSize = Int
data ConnectionData=
#ifndef ghcjs_HOST_OS
                   Node2Node{port :: PortID
                            ,socket ::Socket
                            ,sockAddr :: NS.SockAddr
                             }
                   | TLSNode2Node{tlscontext :: SData}
                   | HTTPS2Node{tlscontext :: SData}
                   | Node2Web{webSocket :: WS.Connection}
                   | HTTP2Node{port :: PortID
                            ,socket ::Socket
                            ,sockAddr :: NS.SockAddr}
                   | Self

#else
                   Self
                   | Web2Node{webSocket :: WebSocket}
#endif
   --   deriving (Eq,Ord)



data Connection= Connection{idConn     :: Int
                           ,myNode     :: IORef Node
                           ,remoteNode :: IORef (Maybe Node)
                           ,connData   :: IORef (Maybe ConnectionData)
                           ,istream    :: IORef ParseContext
                           ,bufferSize :: BuffSize
                           -- multiple wormhole/teleport use the same connection concurrently
                           ,isBlocked  :: Blocked
                           ,calling    :: Bool
                           ,synchronous :: Bool
                           -- local localClosures with his continuation and a blocking MVar
                           -- another MVar with the children created by the closure
                           -- also has the id of the remote closure connected with
                           ,localClosures   :: MVar (M.Map IdClosure  (MVar[EventF],IdClosure,  MVar (),EventF))

                           -- for each remote closure that points to local closure 0,
                           -- a new container of child processes
                           -- in order to treat them separately
                           -- so that 'killChilds' do not kill unrelated processes
                           -- used by `single` and `unique`
                           ,closChildren :: IORef (M.Map Int EventF)}
                           --,wormholes :: IORef [IORef Closure]}

                  deriving Typeable

connectionList :: IORef [Connection]
connectionList= unsafePerformIO $ newIORef []





defConnection :: TransIO Connection

noParseContext=  let err= error "parseContext not set" in
   ParseContext err err err 

-- #ifndef ghcjs_HOST_OS
defConnection =  do
  idc <- genGlobalId
  liftIO $ do
    my <- newIORef (error "node in default connection")
    x <- newMVar Nothing
    y <- newMVar M.empty
    ref <- newIORef Nothing
    z <-   newIORef M.empty
    noconn <- newIORef Nothing
    np <-  newIORef noParseContext
    -- whls <- newIORef []
    return $ Connection idc my ref noconn  np  8192
                  --(error "defConnection: accessing network events out of listen")
                  x  False False y z -- whls


#ifndef ghcjs_HOST_OS

setBuffSize :: Int -> TransIO ()
setBuffSize size= do
   conn<- getData `onNothing`  (defConnection !> "DEFF3")
   setData $ conn{bufferSize= size}


getBuffSize=
  (do getSData >>= return . bufferSize) <|> return  8192


-- | Setup the node to start listening for incoming connections.
--
listen ::  Node ->  Cloud ()
listen  (node@(Node _ port _ _ )) = onAll $ do
   labelState "listen"
   {-
   st <- get
   onException $ \(e :: SomeException) -> do
         case fromException e of
           Just (CloudException _ _ _) -> return()
           _ -> do
                      cutExceptions
                      liftIO $ print "EXCEPTION: KILLING"
                      topState >>= showThreads
                      -- liftIO $ killBranch'  st
                      -- Closure closRemote <- getData `onNothing` error "teleport: no closRemote"
                      -- conn <- getData `onNothing` error "reportBack: No connection defined: use wormhole"
                      -- liftIO $ putStrLn "Closing connection"
                      -- mclose conn
                      -- msend conn  $ SError $ toException $ ErrorCall $ show $ show $ CloudException node closRemote $ show e
                      empty
     -}
   -- ex <- exceptionPoint :: TransIO (BackPoint SomeException)
   -- setData ex
   onException $ \(ConnectionError msg node) -> empty

   --addThreads 2
   fork connectionTimeouts
   fork loopClosures

   setData $ Log{recover=False, buildLog= mempty, fulLog= mempty, lengthFull= 0, hashClosure= 0}

   conn' <- getSData <|> defConnection
   chs   <- liftIO $ newIORef M.empty
   cdata <- liftIO $ newIORef $ Just Self
   let conn= conn'{connData=cdata,closChildren=chs}
   pool <- liftIO $ newMVar [conn]

   let node'= node{connection=Just pool}
   liftIO $ writeIORef (myNode conn) node'
   setData conn

   liftIO $ modifyMVar_ (fromJust $ connection node') $ const $ return [conn]

   addNodes [node']
   setRState(JobGroup M.empty)   --used by resetRemote

   ex <- exceptionPoint :: TransIO (BackPoint SomeException)
   setData ex

   mlog <- listenNew (fromIntegral port) conn   <|> listenResponses :: TransIO (StreamData NodeMSG)
   execLog mlog

-- listen incoming requests

listenNew port conn'=  do
   sock <- liftIO $ listenOn $ PortNumber port

   liftIO $ do
      let bufSize= bufferSize conn'
      NS.setSocketOption sock NS.RecvBuffer bufSize
      NS.setSocketOption sock NS.SendBuffer bufSize

   -- wait for connections. One thread per connection
   liftIO $ do putStr "Connected to port: "; print port
   (sock,addr) <- waitEvents $ NS.accept sock

   chs <- liftIO $ newIORef M.empty
--   case addr of
--     NS.SockAddrInet port host -> liftIO $ print("connection from", port, host)
--     NS.SockAddrInet6  a b c d -> liftIO $ print("connection from", a, b,c,d)
   noNode <- liftIO $ newIORef Nothing
   id1 <- genGlobalId
   let conn= conn'{idConn=id1,closChildren=chs, remoteNode= noNode}

   --liftIO $ atomicModifyIORef connectionList $ \m -> (conn: m,()) -- TODO

   input <-  liftIO $ SBSL.getContents sock
   --return () !> "SOME INPUT"
   -- cutExceptions

  --  onException $ \(e :: IOException) ->
  --         when (ioeGetLocation e=="Network.Socket.recvBuf") $ do
  --            liftIO $ putStr "listen: " >> print e

  --            let Connection{remoteNode=rnode,localClosures=localClosures,closChildren= rmap} = conn
  --            mnode <- liftIO $ readIORef rnode
  --            case mnode of
  --              Nothing -> return ()
  --              Just node  -> do
  --                            liftIO $ putStr "removing1 node: " >> print node
  --                            nodes <- getNodes
  --                            setNodes $ nodes \\ [node]
  --            liftIO $ do
  --                 modifyMVar_ localClosures $ const $ return M.empty
  --                 writeIORef rmap M.empty
  --            -- topState >>= showThreads

  --            killBranch


   let nod = unsafePerformIO $ liftIO $ createNode "incoming connection"  0 in
     modify $ \s -> s{execMode=Serial,parseContext= (ParseContext 
                    (liftIO $ NS.close sock >> throw (ConnectionError "connection closed" nod)) 
                    input (unsafePerformIO $ newIORef False)
             ::ParseContext )}
   cdata <- liftIO $ newIORef $ Just (Node2Node (PortNumber port) sock addr)
   let conn'= conn{connData=cdata}
   setState conn'
   liftIO $ atomicModifyIORef connectionList $ \m -> (conn': m,()) -- TODO

   return () !> "BEFORE HANDSHAKE"
   maybeTLSServerHandshake sock input



   -- (method,uri, headers) <- receiveHTTPHead

   firstLine@(method, uri, vers) <- getFirstLine


   -- return () !> ("after getfirstLine", method, uri, vers)

   headers <- getHeaders
   setState $ HTTPHeaders firstLine headers
   -- return () !> ("HEADERS", headers)
   -- string "\r\n\r\n"
   -- return () !> (method, uri,vers)
   case (method, uri) of

     ("CLOS", hisCookie) -> do

           conn <- getSData
           return () !> "CONNECTING"
           let host = BC.unpack $ fromMaybe (error "no host in header")$ lookup "Host" headers
               port = read $ BC.unpack $ fromMaybe (error "no port in header")$ lookup "Port" headers
           remNode' <- liftIO $ createNode host  port


           rc <- liftIO $ newMVar  [conn]
           let remNode= remNode'{connection= Just rc}
           liftIO $ writeIORef (remoteNode conn) $ Just remNode
           return () !> ("ADDED NODE", remNode)
           addNodes [remNode]
           myCookie <- liftIO $ readIORef rcookie
           if BS.toStrict myCookie /=  hisCookie
            then do
              sendRaw conn "NOK"

              mclose conn
              error "connection attempt with bad cookie"
            else do

               sendRaw conn "OK"                               --    !> "CLOS detected"
               --async (return (SMore $ ClosureData 0 0[Exec])) <|> mread conn

               mread conn

     _ -> do
           -- it is a HTTP request
           -- process the current request in his own thread and then (<|>) any other request that arrive in the same connection
           cutBody method headers  <|> many' cutHTTPRequest

           HTTPHeaders (method,uri,vers) headers <- getState <|>  error "HTTP: no headers?"

           let uri'= BC.tail $ uriPath uri !> uriPath uri
           return () !>  ("uri'", uri')

           case BC.span (/= '/') uri' of

            ("api",_) -> do
           -- if  "api" `BC.isPrefixOf` uri'
             --then do

               --log <- return $ Exec:Exec: (Var $ IDyns $ up method):(map (Var . IDyns ) $ split $ BC.unpack $ BC.drop 4 uri')

               let log=  exec <> lazyByteString  method <> byteString "/" <>  byteString  (BC.drop 4 uri')



               maybeSetHost headers
               tr ("HEADERS", headers)
               str <-  giveParseString  <|> error "no api data"
               if  lookup "Transfer-Encoding" headers == Just "chunked" then error $ "chunked not supported" else do

                   len <- (read <$> BC.unpack
                                <$> (Transient $ return (lookup "Content-Length" headers)))
                                <|> return 0
                   log' <- case lookup "Content-Type" headers of

                           Just "application/json" -> do

                                let toDecode= BS.take len str
                                -- return () !> ("TO DECODE", log <> lazyByteString toDecode)

                                setParseString $ BS.take len str
                                return $ log <> "/" <> lazyByteString toDecode -- [(Var $ IDynamic json)]    -- TODO hande this serialization

                           Just "application/x-www-form-urlencoded" -> do

                                return () !> ("POST HEADERS=", BS.take len str)

                                setParseString $ BS.take len str
                                --postParams <- parsePostUrlEncoded  <|> return []
                                return $ log <>  lazyByteString ( BS.take len str) -- [(Var . IDynamic $ postParams)]  TODO: solve deserialization

                           Just x -> do
                                return () !> ("POST HEADERS=", BS.take len str)
                                let str= BS.take len str
                                return $ log <> lazyByteString str --  ++ [Var $ IDynamic  str]

                           _ -> return $ log

                   setParseString $ toLazyByteString log'
                   return $ SMore $ ClosureData 0 0  log' !> ("APIIIII", log')

             --else if "relay"  `BC.isPrefixOf` uri' then proxy sock method vers uri'
            ("relay",_) ->  proxy sock method vers uri'

            (h,rest) -> do
              if   BC.null rest  ||  h== "file" then do
                --headers <- getHeaders
                maybeSetHost headers
                let uri= if BC.null h || BC.null rest then  uri' else  BC.tail rest
                return () !> (method,uri)
                -- stay serving pages until a websocket request is received
                servePages (method, uri, headers)

                -- when servePages finish, is because a websocket request has arrived
                conn <- getSData
                sconn <- makeWebsocketConnection conn uri headers

                -- websockets mode
                -- para qué reiniciarlo todo????
                rem <- liftIO $ newIORef Nothing
                chs <- liftIO $ newIORef M.empty
                cls <- liftIO $ newMVar M.empty
                cme <- liftIO $ newIORef M.empty
                cdata <- liftIO $ newIORef $ Just (Node2Web sconn)
                let conn'= conn{connData= cdata
                          , closChildren=chs,localClosures=cls, remoteNode=rem} --,comEvent=cme}
                setState conn'    !> "WEBSOCKETS CONNECTION"

                co <- liftIO $ readIORef rcookie

                let receivedCookie= lookup "cookie" headers


                return () !> ("cookie", receivedCookie)
                rcookie <- case receivedCookie of
                  Just str-> Just <$> do
                              withParseString (BS.fromStrict str) $ do
                                  tDropUntilToken "cookie="
                                  tTakeWhile (not . isSpace)
                  Nothing -> return Nothing
                return () !> ("RCOOKIE", rcookie)
                if rcookie /= Nothing && rcookie /= Just  co
                  then do
                    node  <- getMyNode
                    --let msg= SError $ toException $ ErrorCall $  show $ show $ CloudException node 0 $ show $ ConnectionError "bad cookie" node
                    return () !> "SENDINg"

                    -- liftIO $ WS.sendClose  sconn $  ("ERROR" :: BS.ByteString)

                    liftIO $ WS.sendClose sconn ("Bad Cookie" :: BS.ByteString)  !> "SendClose Bad cookie"
                    empty

                  else do

                    liftIO $ WS.sendTextData sconn ("OK" :: BS.ByteString)



                    -- a void message is sent to the application signaling the beginning of a connection
                    -- async (return (SMore $ ClosureData 0 0[Exec])) <|> do

                    do
                      return ()                  !> "WEBSOCKET"
                      --  onException $ \(e :: SomeException) -> do
                      --     liftIO $ putStr "listen websocket:" >> print e
                      --     -- liftIO $ mclose conn'
                      --     -- killBranch
                      --     -- empty


                      s <- waitEvents $ WS.receiveData sconn :: TransIO BS.ByteString
                      setParseString s
                      integer
                      deserialize <|> (return $ SMore (ClosureData 0 0  (exec <> lazyByteString s)))
              else  do
                let uriparsed=  BS.pack $ unEscapeString $ BC.unpack uri'
                setParseString uriparsed !> ("uriparsed",uriparsed)
                remoteClosure <- deserialize    :: TransIO Int
                tChar '/'
                thisClosure <- deserialize      :: TransIO Int
                tChar '/'
                --cdata <- liftIO $ newIORef $ Just (HTTP2Node (PortNumber port) sock addr)
                conn <- getSData
                liftIO $ atomicModifyIORef' (connData conn) $ \cdata -> case cdata of
                         Just(Node2Node  port sock addr) -> (Just $ HTTP2Node port sock addr,())
                         Just(TLSNode2Node ctx) -> (Just $ HTTPS2Node ctx,())

                --setState conn{connData=cdata}
                s <- giveParseString
                cook <- liftIO $ readIORef rcookie

                liftIO $ SBSL.sendAll sock $  "HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\n\r\n"
                return $ SMore $ ClosureData remoteClosure thisClosure  $ lazyByteString  s





     where
      cutHTTPRequest = do
          first@(method,_,_) <- getFirstLine
          -- return () !> ("after getfirstLine", method, uri, vers)
          headers <- getHeaders
          setState $ HTTPHeaders first headers
          cutBody method headers



      cutBody method headers= do
          if method == "POST" then
              case fmap (read . BC.unpack) $ lookup "Content-Length" headers of
                Nothing -> return () -- most likely chunked encoding
                Just len -> do
                  str <- tTake (fromIntegral len)
                  abduce
                  setParseString str
            else abduce


      uriPath = BC.dropWhile (/= '/')
      split []= []
      split ('/':r)= split r
      split s=
          let (h,t) = Prelude.span (/= '/') s
          in h: split  t

      -- reverse proxy for urls that look like http://host:port/relay/otherhost/otherport/
      proxy sclient method vers uri' = do
        let (host:port:_)=  split $ BC.unpack $ BC.drop 6 uri'
        return () !> ("RELAY TO",host, port)
        --liftIO $ threadDelay 1000000
        sserver <- liftIO $ connectTo' 4096 host $ PortNumber $ fromIntegral $ read port
        return () !> "CONNECTED"
        rawHeaders <- getRawHeaders
        return () !>  ("RAWHEADERS",rawHeaders)
        let uri= BS.fromStrict $ let d x= BC.tail $ BC.dropWhile (/= '/') x in d . d $ d uri'

        let sent=   method <> BS.pack " /"
                           <> uri
                           <> BS.cons ' ' vers
                           <> BS.pack "\r\n"
                           <> rawHeaders <> BS.pack "\r\n\r\n"
        return () !> ("SENT",sent)
        liftIO $ SBSL.send  sserver sent
          -- Connection{connData=Just (Node2Node _ sclient _)} <- getState <|> error "proxy: no connection"


        (send sclient sserver <|> send sserver sclient)
            `catcht` \(e:: SomeException ) -> liftIO $ do
                            putStr "Proxy: " >> print e
                            NS.close sserver
                            NS.close sclient
                            empty

        empty
        where
        send f t= async $ mapData f t
        mapData from to = do
            content <- recv from 4096
            return () !> (" proxy received ", content)
            if not $ BC.null content
              then sendAll to content >> mapData from to
              else finish
            where
            finish=  NS.close from >> NS.close to
           -- throw $ Finish "finish"


      maybeSetHost headers= do
        setHost <- liftIO $ readIORef rsetHost
        when setHost $ do

          mnode <- liftIO $ do
           let mhost= lookup "Host" headers
           case mhost of
              Nothing -> return Nothing
              Just host -> atomically $ do
                   -- set the first node (local node) as is called from outside
                     nodes <- readTVar  nodeList
                     let (host1,port)= BC.span (/= ':') host
                         hostnode= (Prelude.head nodes){nodeHost=  BC.unpack host1
                                           ,nodePort= if BC.null port then 80
                                            else read $ BC.unpack $ BC.tail port}
                     writeTVar nodeList $ hostnode : Prelude.tail nodes
                     return $ Just  hostnode  -- !> (host1,port)

          when (isJust mnode) $ do
            conn <- getState
            liftIO $ writeIORef (myNode conn) $fromJust mnode
          liftIO $ writeIORef rsetHost False  -- !> "HOSt SET"

{-#NOINLINE rsetHost #-}
rsetHost= unsafePerformIO $ newIORef True



--instance Read PortNumber where
--  readsPrec n str= let [(n,s)]=   readsPrec n str in [(fromIntegral n,s)]


--deriving instance Read PortID
--deriving instance Typeable PortID

-- | filter out HTTP requests
noHTTP= onAll $ do
    conn <- getState
    cdata <- liftIO $ readIORef $ connData conn
    case cdata of
      Just (HTTPS2Node ctx) -> do
        liftIO $ sendTLSData ctx $  "HTTP/1.1 403 Forbidden\r\nConnection: close\r\nContent-Length: 11\r\n\r\nForbidden\r\n"
        liftIO $ tlsClose ctx
      Just (HTTP2Node _ sock _) -> do
        liftIO $ SBSL.sendAll sock $  "HTTP/1.1 403 Forbidden\r\nConnection: close\r\nContent-Length: 11\r\n\r\nForbidden\r\n"
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
listenResponses= do
      labelState  "listen responses"

      (conn, parsecontext, node) <- getMailbox   :: TransIO (Connection,ParseContext,Node)
      labelState . fromString $ "listen from: "++ show node

      setData conn

      modify $ \s-> s{execMode=Serial,parseContext = parsecontext}

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




type IdClosure= Int

-- The remote closure ids for each node connection
newtype Closure= Closure  IdClosure  deriving (Read,Show,Typeable)





type RemoteClosure=  (Node, IdClosure)


newtype JobGroup= JobGroup  (M.Map BC.ByteString RemoteClosure) deriving Typeable

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

stopRemoteJob ident =  do
    resetRemote ident
    Closure closr <- local $ getRData `onNothing` error "stopRemoteJob: Connection not set, use wormhole"
    return () !> ("CLOSRRRRRRRR", closr)
    fixClosure
    local $ do
      Closure closr <- getData `onNothing` error "stopRemoteJob: Connection not set, use wormhole"
      conn <- getData `onNothing` error "stopRemoteJob: Connection not set, use wormhole"
      remote <- liftIO $ readIORef $ remoteNode conn
      return (remote,closr) !> ("REMOTE",remote)

      JobGroup map  <- getRState <|> return (JobGroup M.empty)
      setRState $ JobGroup $ M.insert ident (fromJust remote,closr) map



-- |kill the remote job. Usually, before starting a new one.
resetRemote :: BC.ByteString -> Cloud ()
resetRemote ident =   do
    mj <- local $  do
      JobGroup map <- getRState <|> return (JobGroup M.empty)
      return $ M.lookup ident map

    when (isJust mj) $  do
        let (remote,closr)= fromJust mj
        --do   -- when (closr /= 0) $ do
        runAt remote $ local $ do
              conn@Connection {localClosures=localClosures} <- getData `onNothing` error "Listen: myNode not set"
              mcont <- liftIO $ modifyMVar localClosures $ \map -> return ( M.delete closr map,  M.lookup closr map)
              case mcont of
                Nothing -> error $ "closure not found: " ++ show closr
                Just (_,_,_,cont) -> do
                                topState >>= showThreads
                                liftIO $  killBranch' cont
                                return ()



execLog :: StreamData NodeMSG -> TransIO ()
execLog  mlog =Transient $ do
       return () !> "EXECLOG"
       case mlog of
             SError e -> do
               return() !> ("SERROR",e)
               case fromException e of
                 Just (ErrorCall str) -> do

                  case read str of
                    (e@(CloudException  _ closl   err)) -> do

                      process  closl (error "closr: should not be used")  (Left  e) True


             SDone   -> runTrans(back $ ErrorCall "SDone") >> return Nothing   -- TODO remove closure?
             SMore (ClosureData closl closr  log) -> process closl closr  (Right log) False
             SLast (ClosureData closl closr  log) -> process closl closr  (Right log) True
   where
   process :: IdClosure -> IdClosure  -> (Either CloudException Builder) -> Bool -> StateIO (Maybe ())
   process  closl closr  mlog  deleteClosure= do

      conn@Connection {localClosures=localClosures} <- getData `onNothing` error "Listen: myNode not set"
      if closl== 0 then do

       case mlog of
        Left except -> do
          setData emptyLog
          return () !> "Exception received from network 1"
          runTrans $ throwt except
          empty
        Right log -> do
           return () !> "CLOSURE 0"
           setData Log{recover= True, buildLog=  mempty, fulLog= log, lengthFull= 0, hashClosure= 0} --Log True [] []

           setRState $ Closure  closr
           -- setParseString $ toLazyByteString log -- not needed it is has the log from the request, still not parsed


           return $ Just ()                  --  !> "executing top level closure"
       else do
         mcont <- liftIO $ modifyMVar localClosures
                         $ \map -> return (if False then -- deleteClosure then
                                           M.delete closl map
                                         else map, M.lookup closl map)
                                           -- !> ("localClosures=", M.size map)

         case mcont  of
           Nothing -> do
--
--              if closl == 0   -- add what is after execLog as closure 0
--               then do
--                     setData $ Log True log  $ reverse log
--                     setData $ Closure closr
--                     cont <- get    !> ("CLOSL","000000000")
--                     liftIO $ modifyMVar localClosures
--                            $ \map -> return (M.insert closl ([],cont) map,())
--                     return $ Just ()     --exec what is after execLog (closure 0)
--
--               else do
              node <- liftIO $ readIORef (remoteNode conn) `onNothing` error "mconnect: no remote node?"
              let e = "request received for non existent closure. Perhaps the connection was closed by timeout and reopened"
              let err=  CloudException node closl $ show e

              -- runTrans $ msend conn $ SError $ toException $ ErrorCall $  show $ show $ err
                -- to delete the remote closure
              --liftIO $ error ("request received for non existent closure: "
              --                        ++  show closl)
              throw err
           -- execute the closure
           Just (chs,_, mv,cont) -> do
              when deleteClosure $ do
              --  liftIO $ killChildren chs
                empty   -- last message received


              liftIO $ tryPutMVar mv ()
              liftIO $ runStateT (case mlog of
                Right log -> do
                  -- Log _ _ fulLog hashClosure <- getData `onNothing` return (Log True [] [] 0)
                  Log{fulLog=fulLog, hashClosure=hashClosure} <- getLog
                  -- return() !> ("fullog in execlog", reverse fulLog)

                  let nlog= fulLog <> log    -- let nlog= reverse log ++ fulLog
                  setData $ Log{recover= True, buildLog=  mempty, fulLog= nlog, lengthFull=error "lengthFull TODO", hashClosure= hashClosure}  -- TODO hashClosure must change?
                  setRState $ Closure  closr

                  setParseString $ toLazyByteString log
                  --restrs <-  giveParseString
                  --return () !> ("rs' in execlog =", fmap (BS.take 4) restrs)
                  runContinuation cont ()

                Left except -> do
                  setData emptyLog
                  return () !> ("Exception received from the network", except)
                  runTrans $ throwt except) cont

              return Nothing

#ifdef ghcjs_HOST_OS
listen node = onAll $ do
        addNodes [node]
        setRState(JobGroup M.empty)
        -- ex <- exceptionPoint :: TransIO (BackPoint SomeException)
        -- setData ex

        events <- liftIO $ newIORef M.empty
        rnode  <- liftIO $ newIORef node
        conn <-  defConnection >>= \c -> return c{myNode=rnode,comEvent=events}
        liftIO $ atomicModifyIORef connectionList $ \m ->  (conn: m,())

        setData conn
        r <- listenResponses
        execLog  r

#endif

type Pool= [Connection]
type Package= String
type Program= String
type Service= [(Package, Program)]





--------------------------------------------


#ifndef ghcjs_HOST_OS


--    maybeRead line= unsafePerformIO $ do
--         let [(v,left)] = reads  line
----         print v
--         (v   `seq` return [(v,left)])
--                        `catch` (\(e::SomeException) -> do
--                          liftIO $ print  $ "******readStream ERROR in: "++take 100 line
--                          maybeRead left)

{-
readFrom Connection{connData= Just(TLSNode2Node ctx)}= recvTLSData ctx

readFrom Connection{connData= Just(Node2Node _ sock _)} =  toStrict <$> loop

readFrom _ = error "readFrom error"
-}

readFrom con= do
  cd <- readIORef $ connData con
  case cd of
    Just(TLSNode2Node ctx)   -> recvTLSData ctx
    Just(Node2Node _ sock _) -> BS.toStrict  <$> loop sock
    _ -> error "readFrom error"
  where
  bufSize= 4098
  loop sock = loop1
    where
      loop1 :: IO BL.ByteString
      loop1 = unsafeInterleaveIO $ do
        s <- SBS.recv sock bufSize

        if BC.length s < bufSize
          then  return $ BLC.Chunk s mempty
          else BLC.Chunk s `liftM` loop1



-- toStrict= B.concat . BS.toChunks

makeWSStreamFromConn conn= do
  return () !> "WEBSOCKETS request"
  let rec= readFrom conn
      send= sendRaw conn
  makeStream
        (do
            bs <-  rec         -- SBS.recv sock 4098
            return $ if BC.null bs then Nothing else Just  bs)
        (\mbBl -> case mbBl of
            Nothing -> return ()
            Just bl ->  send bl) -- SBS.sendMany sock (BL.toChunks bl) >> return())   -- !!> show ("SOCK RESP",bl)

makeWebsocketConnection conn uri headers= liftIO $ do

  stream <- makeWSStreamFromConn conn
  let
      pc = WS.PendingConnection
        { WS.pendingOptions     = WS.defaultConnectionOptions -- {connectionOnPong=xxx}
        , WS.pendingRequest     = NWS.RequestHead  uri  headers False -- RequestHead (BC.pack $ show uri)
                                              -- (map parseh headers) False
        , WS.pendingOnAccept    = \_ -> return ()
        , WS.pendingStream      = stream
        }

  sconn    <- WS.acceptRequest pc               -- !!> "accept request"
  WS.forkPingThread sconn 30
  return sconn

servePages (method,uri, headers)   = do
--   return ()                        !> ("HTTP request",method,uri, headers)
   conn <- getSData <|> error " servePageMode: no connection"

   if isWebSocketsReq headers
     then  return ()



     else do

        let file= if BC.null uri then "index.html" else uri

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
        mcontent <- liftIO $ (Just <$> BL.readFile ( "./static/out.jsexe/"++ BC.unpack file) )
                                `catch` (\(e:: SomeException) -> return Nothing)

--                                    return  "Not found file: index.html<br/> please compile with ghcjs<br/> ghcjs program.hs -o static/out")
        case mcontent of
          Just content -> do
           cook <- liftIO $ readIORef rcookie
           liftIO $ sendRaw conn $
            "HTTP/1.0 200 OK\r\nContent-Type: text/html\r\nConnection: close\r\nContent-Length: "
            <> BS.pack (show $ BL.length content) <>"\r\n"
            <> "Set-Cookie:" <> "cookie=" <> cook -- <> "\r\n"
            <>"\r\n\r\n" <> content

          Nothing ->liftIO $ sendRaw conn $ BS.pack $
              "HTTP/1.0 404 Not Found\nContent-Length: 13\r\nConnection: close\r\n\r\nNot Found 404"
        empty


-- | forward all the result of the Transient computation to the opened connection
api :: TransIO BS.ByteString -> Cloud ()
api w= Cloud $ do
    log <- getLog
    if not $ recover log then empty else do
       HTTPHeaders (_,_,vers) hdrs <- getState <|> error "api: no HTTP headers???"
       let closeit= lookup "Connection" hdrs == Just "close"
       conn <- getState  <|> error "api: Need a connection opened with initNode, listen, simpleWebApp"
       let send= sendRaw conn

       r <- w
       return () !> ("response",r)
       send r

       return () !> (vers, hdrs)
       when (vers == http10                            ||
             BS.isPrefixOf http10 r                    ||
             lookup "Connection" hdrs == Just "close"  ||
             closeInResponse r)
             $ liftIO $ mclose conn
    where
    closeInResponse r=
       let rest= findSubstring "Connection:" r
           rest' = BS.dropWhile (==' ') rest
       in if BS.isPrefixOf "close" rest' then True else False

       where
       findSubstring sub str
           | BS.null str = str
           | BS.isPrefixOf sub str = BS.drop (BS.length sub) str
           | otherwise= findSubstring sub (BS.tail str)

http10= "HTTP/1.0"





isWebSocketsReq = not  . null
    . filter ( (== mk "Sec-WebSocket-Key") . fst)


data HTTPMethod= GET | POST deriving (Read,Show,Typeable,Eq)

instance Loggable HTTPMethod

getFirstLine=  (,,) <$> getMethod <*> (BS.toStrict <$> getUri) <*> getVers
    where
    getMethod= parseString

    getUri= parseString
    getVers= parseString

getRawHeaders=  dropSpaces >> (withGetParseString $ \s -> return $ scan mempty s)

   where
   scan  res str

       | "\r\n\r\n" `BS.isPrefixOf` str   = (res, BS.drop 4 str)
       | otherwise=  scan ( BS.snoc res $ BS.head str) $ BS.tail str
  --  line= do
  --   dropSpaces
  --   tTakeWhile (not . endline)

type PostParams = [(BS.ByteString, String)]

parsePostUrlEncoded :: TransIO PostParams
parsePostUrlEncoded= do
   dropSpaces
   many $ (,) <$> param  <*> value
   where
   param= tTakeWhile' ( /= '=') !> "param"
   value= unEscapeString <$> BS.unpack <$> tTakeWhile' (/= '&' )




getHeaders =  manyTill paramPair  (string "\r\n\r\n")       -- !>  (method, uri, vers)

  where


  paramPair=  (,) <$> (mk <$> getParam) <*> getParamValue


  getParam= do
      dropSpaces
      r <- tTakeWhile (\x -> x /= ':' && not (endline x))
      if BS.null r || r=="\r"  then  empty  else  anyChar >> return (BS.toStrict r)
      where
      endline c= c== '\r' || c =='\n'

  getParamValue= BS.toStrict <$> ( dropSpaces >> tTakeWhile  (\x -> not (endline x)))
      where
      endline c= c== '\r' || c =='\n'



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
emptyPool= liftIO $ newMVar  []


-- | Create a node from a hostname (or IP address), port number and a list of
-- services.
createNodeServ ::  HostName -> Int -> Service -> IO Node
createNodeServ h p svs=  return $ Node h  p Nothing svs


createNode :: HostName -> Int -> IO Node
createNode h p= createNodeServ h p []

createWebNode :: IO Node
createWebNode= do
  pool <- emptyPool
  port <- randomIO
  return $ Node "webnode"  port (Just pool)  [("webnode","")]


instance Eq Node where
    Node h p _ _ ==Node h' p' _ _= h==h' && p==p'


instance Show Node where
    show (Node h p _ servs )= show (h,p, servs)

instance Read Node where
    readsPrec n s=
          let r= readsPrec n s
          in case r of
            [] -> []
            [((h,p,ss),s')] ->  [(Node h p Nothing ss ,s')]



nodeList :: TVar  [Node]
nodeList = unsafePerformIO $ newTVarIO []

deriving instance Ord PortID

--myNode :: Int -> DBRef  MyNode
--myNode= getDBRef $ key $ MyNode undefined

errorMyNode f= error $ f ++ ": Node not set. initialize it with connect, listen, initNode..."

-- | Return the local node i.e. the node where this computation is running.
getMyNode ::  TransIO Node
getMyNode =  do
    Connection{myNode= node} <- getSData <|> errorMyNode "getMyNode"  :: TransIO Connection
    liftIO $ readIORef node

-- | empty if the node is not set
getMyNodeMaybe= do
    Connection{myNode= node} <- getSData
    liftIO $ readIORef node

-- | Return the list of nodes in the cluster.
getNodes :: MonadIO m => m [Node]
getNodes  = liftIO $ atomically $ readTVar  nodeList


-- | get the nodes that have the same service definition that the calling node
getEqualNodes = do
    nodes <- getNodes

    let srv= nodeServices $ Prelude.head nodes
    case srv of
      [] -> return $ filter (null . nodeServices) nodes

      (srv:_)  -> return $ filter (\n ->  (not $ null $ nodeServices n) && Prelude.head (nodeServices n) == srv  ) nodes

getWebNodes :: MonadIO m => m [Node]
getWebNodes = do
    nodes <- getNodes
    return $ filter ( (==) "webnode" . nodeHost) nodes

matchNodes f = do
      nodes <- getNodes
      return $ Prelude.map (\n -> filter f $ nodeServices n) nodes

-- | Add a list of nodes to the list of existing nodes know locally.
addNodes :: [Node] -> TransIO ()
addNodes   nodes=  do
--  my <- getMyNode    -- mynode must be first
  nodes' <- mapM fixNode nodes
  liftIO . atomically $ do
    prevnodes <- readTVar nodeList  -- !> ("ADDNODES", nodes)
    writeTVar nodeList $  (prevnodes \\ nodes') ++ nodes'

delNodes nodes= liftIO $ atomically $ do
  nodes' <-  readTVar nodeList
  writeTVar nodeList $ nodes' \\ nodes

fixNode n= case connection n of
  Nothing -> do
      pool <- emptyPool
      return n{connection= Just pool}
  Just _ -> return n

-- | set the list of nodes
setNodes nodes= liftIO $ do
     nodes' <- mapM fixNode nodes
     atomically $ writeTVar nodeList  nodes'


-- | Shuffle the list of cluster nodes and return the shuffled list.
shuffleNodes :: MonadIO m => m [Node]
shuffleNodes=  liftIO . atomically $ do
  nodes <- readTVar nodeList
  let nodes'= Prelude.tail nodes ++ [Prelude.head nodes]
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
addThisNodeToRemote= do
    n <- local getMyNode
    atRemote $ local $ do
      n' <- setConnectionIn n
      addNodes [n']

setConnectionIn node=do
    conn <- getState <|> error "addThisNodeToRemote: connection not found"
    ref <- liftIO $ newMVar [conn]
    return node{connection=Just ref}

-- | Add a node (first parameter) to the cluster using a node that is already
-- part of the cluster (second parameter).  The added node starts listening for
-- incoming connections and the rest of the computation is executed on this
-- newly added node.
connect ::  Node ->  Node -> Cloud ()
#ifndef ghcjs_HOST_OS
connect  node  remotenode =   do
    listen node <|> return ()
    connect' remotenode



-- | Reconcile the list of nodes in the cluster using a remote node already
-- part of the cluster. Reconciliation end up in each node in the cluster
-- having  the same list of nodes.
connect' :: Node -> Cloud ()
connect'  remotenode= loggedc $ do
    nodes <- local getNodes
    localIO $ putStr "connecting to: " >> print remotenode

    newNodes <- runAt remotenode $ interchange  nodes

    --return ()                                                              !> "interchange finish"

    -- add the new  nodes to the local nodes in all the nodes connected previously

    let toAdd=remotenode:Prelude.tail newNodes
    callNodes' nodes  (<>) mempty $ local $ do
           liftIO $ putStr  "New nodes: " >> print toAdd !> "NEWNODES"
           addNodes toAdd

    where
    -- receive new nodes and send their own
    interchange  nodes=
        do
           newNodes <- local $ do

              conn@Connection{remoteNode=rnode} <- getSData <|>
               error ("connect': need to be connected to a node: use wormhole/connect/listen")


              -- if is a websockets node, add only this node
              -- let newNodes = case  cdata of
              --                  Node2Web _ -> [(head nodes){nodeServices=[("relay",show remotenode)]}]
              --                  _ ->  nodes

              let newNodes=  nodes -- map (\n -> n{nodeServices= nodeServices n ++ [("relay",show (remotenode,n))]}) nodes

              callingNode<- fixNode $ Prelude.head newNodes

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
                liftIO $ putStrLn  "New nodes: " >> print newNodes

                addNodes newNodes

           localIO $ atomically $ do
                  -- set the first node (local node) as is called from outside
--                     return () !> "HOST2 set"
                     nodes <- readTVar  nodeList
                     let nodes'= (Prelude.head nodes){nodeHost=nodeHost remotenode
                                             ,nodePort=nodePort remotenode}:Prelude.tail nodes
                     writeTVar nodeList nodes'


           return oldNodes

#else
connect _ _= empty
connect' _ = empty
#endif


#ifndef ghcjs_HOST_OS
-------------------------------  HTTP client ---------------


instance {-# Overlapping #-}  Loggable Value where
   serialize= return . lazyByteString =<< encode
   deserialize =  decodeIt
    where
        jsElem :: TransIO BS.ByteString  -- just delimites the json string, do not parse it
        jsElem=   dropSpaces >> (jsonObject <|> array <|> atom)
        atom=     elemString
        array=      (brackets $ return "[" <> return "{}" <> chainSepBy mappend (return "," <> jsElem)  (tChar ','))  <> return "]"
        jsonObject= (braces $ return "{" <> chainMany mappend jsElem) <> return "}"
        elemString= do
            dropSpaces
            tTakeWhile (\c -> c /= '}' && c /= ']' )



        decodeIt= do
            s <- jsElem
            return () !> ("decode",s)

            case eitherDecode s !> "DECODE" of
              Right x -> return x
              Left err      -> empty





data HTTPHeaders= HTTPHeaders  (BS.ByteString, B.ByteString, BS.ByteString) [(CI BC.ByteString,BC.ByteString)] deriving Show



rawHTTP :: Loggable a => Node -> String -> TransIO  a
rawHTTP node restmsg = do
  abduce   -- is a parallel operation
  tr ("***********************rawHTTP",nodeHost node, restmsg)
  liftIO $ putStrLn restmsg

  --sock <- liftIO $ connectTo' 8192 (nodeHost node) (PortNumber $ fromIntegral $ nodePort node)
  mcon <- getData :: TransIO (Maybe Connection)
  c <- mconnect' node
  --sn <- liftIO $ makeStableName c
  --liftIO $ print $ hashStableName $ sn `seq` sn
  sendRaw c  $ BS.pack $ restmsg
  
  let blocked= isBlocked c
  
  liftIO $ takeMVar blocked

  ctx <- liftIO $ readIORef $ istream c

  liftIO $ writeIORef (done ctx) False
  modify $ \s -> s{parseContext= ctx}  -- actualize the parse context
  --SET PARSECONTEXT2
  tr "after send"
  modify $ \s -> s{execMode=Serial}
  --try (do r <-tTake 10;liftIO  $ print "NOTPARSED"; liftIO $ print  r; empty) <|> return()
  first@(vers,code,_) <- getFirstLineResp
  tr ("FIRST line",first)
  headers <- getHeaders
  let hdrs= HTTPHeaders first headers
  setState hdrs

  tr ("HEADERS", first, headers)
  
  guard (BC.head code== '2') 
     <|> do Raw body <- parseBody headers
            error $ show (hdrs,body) -- TODO decode the body and print
  
  result <- parseBody headers

  
  

  
  
  
  tr ("result", result)
  
  
  
  
  --when (not $ null rest)  $ error "THERE WERE SOME REST"
  ctx <- gets parseContext
  -- "SET PARSECONTEXT PREVIOUS"
  liftIO $ writeIORef (istream c) ctx 
  
  

  TOD t _ <- liftIO $ getClockTime
  -- ("PUTMVAR",nodeHost node)
  liftIO $ putMVar blocked  $ Just t

  when (vers == http10                       ||
    --    BS.isPrefixOf http10 str             ||
        lookup "Connection" headers == Just "close" )
        $ liftIO $ mclose c
  
  if (isJust mcon) then setData (fromJust mcon) else delData c
  return result
  where
  
  parseBody headers= case lookup "Transfer-Encoding" headers of
          Just "chunked" -> dechunk |- deserialize

          _ ->  case fmap (read . BC.unpack) $ lookup "Content-Length" headers  of

                Just length -> do
                      msg <- tTake length
                      tr ("GOT", length)
                      withParseString msg deserialize
                _ -> deserialize
  getFirstLineResp= do

      -- showNext "getFirstLineResp" 20
      (,,) <$> httpVers <*> (BS.toStrict <$> getCode) <*> getMessage
    where
    httpVers= tTakeUntil (BS.isPrefixOf "HTTP" ) >> parseString
    getCode= parseString
    getMessage= tTakeUntilToken ("\r\n")
  --con<- getState <|> error "rawHTTP: no connection?"
  --mclose con xxx
  --maybeClose vers headers c str

lprint x= tr x

dechunk=  do

           n<- numChars
           if n== 0 then do  showNext  "CHUNK 0" 2; string "\r\n";    return SDone else do
               r <- tTake $ fromIntegral n   !> ("numChars",n)
               --return () !> ("message", r)
               trycrlf
               return () !> "SMORE1"
               return $ SMore r

     <|>   return SDone !> "SDone in dechunk"
 
    where
    trycrlf= try (string "\r\n" >> return()) <|> return ()
    numChars= do l <- hex ; tDrop 2 >> return l

#endif


-- | crawl the nodes executing the same action in each node and accumulate the results using a binary operator

foldNet :: Loggable a => (Cloud a -> Cloud a -> Cloud a) -> Cloud a -> Cloud a -> Cloud a
foldNet op init action = atServer $ do
    ref <- onAll $ liftIO $ newIORef Nothing -- eliminate additional results doe to unneded parallelism when using (<|>)
    r <- exploreNetExclude []
    v <-localIO $ atomicModifyIORef ref $ \v -> (Just r, v)
    case v of
       Nothing -> return r
       Just _  -> empty
    where
    exploreNetExclude nodesexclude = loggedc $ do
       local $ return () !> "EXPLORENETTTTTTTTTTTT"
       action  `op` otherNodes
       where
       otherNodes= do
             node <- local getMyNode
             nodes <- local getNodes'
             return () !> ("NODES to explore",nodes)
             let nodesToExplore= Prelude.tail nodes \\ (node:nodesexclude)
             callNodes' nodesToExplore op init $
                          exploreNetExclude (union (node:nodesexclude) nodes)

       getNodes'= getEqualNodes -- if isBrowserInstance then  return <$>getMyNode  -- getEqualNodes
                     -- else (++) <$>  getEqualNodes <*> getWebNodes


exploreNet :: (Loggable a,Monoid a) => Cloud a -> Cloud a
exploreNet = foldNet mappend  mempty

exploreNetUntil ::  (Loggable a) => Cloud a -> Cloud  a
exploreNetUntil = foldNet (<|>) empty


-- | only execute if the the program is executing in the browser. The code inside can contain calls to the server.
-- Otherwise return empty (so it stop the computation and may execute alternative computations).
onBrowser :: Cloud a -> Cloud a
onBrowser x= do
     r <- local $  return isBrowserInstance
     if r then x else empty

-- | only executes the computaion if it is in the server, but the computation can call the browser. Otherwise return empty
onServer :: Cloud a -> Cloud a
onServer x= do
     r <- local $  return isBrowserInstance
     if not r then x else empty


-- | If the computation is running in the server, translates i to the browser and return back.
-- If it is already in the browser, just execute it
atBrowser :: Loggable a => Cloud a -> Cloud a
atBrowser x= do
        r <- local $  return isBrowserInstance
        if r then x else atRemote x

-- | If the computation is running in the browser, translates i to the server and return back.
-- If it is already in the server, just execute it
atServer :: Loggable a => Cloud a -> Cloud a
atServer x= do
        r <- local $  return isBrowserInstance
        return () !> ("AT SERVER",r)
        if not r then x else atRemote x

------------------- timeouts -----------------------
-- delete connections.
-- delete receiving closures before sending closures

delta= 60 -- 3*60
connectionTimeouts  :: TransIO ()
connectionTimeouts=  do
    labelState "loop connections"

    threads 0 $ waitEvents $ return ()    --loop
    liftIO $ threadDelay 10000000
    -- return () !> "timeouts"
    TOD time _ <- liftIO $  getClockTime
    toClose <- liftIO $  atomicModifyIORef connectionList $ \ cons ->
        Data.List.partition (\con ->
            let mc= unsafePerformIO $ readMVar $ isBlocked con

            in   isNothing mc || -- check that is not doing some IO
              ((time - fromJust mc) < delta) ) cons  -- !> Data.List.length cons
        -- time etc are in a IORef
    forM_ toClose $ \c -> liftIO $ do

      return () !> "close "
      return () !> idConn c
      mclose c;
      cleanConnectionData  c    -- websocket connections close everithing on  timeout

cleanConnectionData c= liftIO $ do
  -- reset the remote accessible closures
  modifyIORef globalFix $ \m -> M.insert (idConn c) (False,[]) m
  modifyMVar_ (localClosures c) $ const $ return M.empty
  modifyIORef globalFix $ \m -> M.insert (idConn c) (True,[]) m

loopClosures= do
  labelState  "loop closures"

  threads 0 $ do                              -- in the current thread
        waitEvents $ threadDelay 5000000      -- every 5 seconds

        nodes <- getNodes                                             -- get the nodes known
        node <- choose $ tail nodes                                   -- walk trough them, except my own node
        when (isJust $ connection node) $ do                          -- when a node has connections
          nc <- liftIO $ readMVar $ fromJust (connection node)          -- get them
          conn <- choose nc                                             -- and walk trough them
          lcs <- liftIO $ readMVar $ localClosures conn                 -- get the local endpoints of this node for that connection
          (closLocal,(mv,clos,_,cont)) <- choose $ M.toList lcs         -- walk trough them
          chs <- liftIO $ readMVar $ children $ fromJust $ parent cont  -- get the threads spawned by requests to this endpoint
          return()
          --return ("NUMBER=",length chs)
          
          when (null chs) $ do                                          -- when there is no activity
               return () !> ("REMOVING", closLocal)
               liftIO $ modifyMVar (localClosures conn) $ \lcs -> return $ (M.delete closLocal lcs,())  -- remove the closure
               msend conn $ SLast $ ClosureData clos closLocal mempty                                   -- notify the remote node

         -- return () !> ("THREADS ***************", length chs)



