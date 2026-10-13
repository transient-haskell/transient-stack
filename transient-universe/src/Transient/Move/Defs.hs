{-#Language RecordWildCards,DeriveGeneric,CPP, UndecidableInstances
, OverlappingInstances,FlexibleInstances,GeneralizedNewtypeDeriving, OverloadedStrings #-}
{-# LANGUAGE InstanceSigs,ScopedTypeVariables,StandaloneDeriving #-}

-- Dedicado a Jesucristo, mi salvador
-- Y a mi hija

module Transient.Move.Defs (module Transient.Move.Defs, Log(..), LogSeg(..), LogB(..), FragmentType(..), ClosureKey, emptyLog, hashStep, hashExec, hashDone, hashWait, hashApp, hashTerm, hashNode) where

import Transient.Internals
import Transient.EVars
import Transient.Loggable
import Transient.Parse
import {-# SOURCE #-} Transient.Move.Logged (endpoint, noExState)
import Data.ByteString.Builder
import qualified Data.ByteString.Builder.Internal as BI
import Data.String (IsString(..))
import qualified Data.TCache.DefaultPersistence as TC
import Data.TCache  hiding (onNothing)

import GHC.Generics
import Data.Coerce

import qualified Network.Socket                         as NS
import qualified Network.WebSockets.Connection          as WS
import qualified Network.WebSockets                     as NWS



import Data.Typeable
import Data.Default
import Control.Exception
import System.IO.Unsafe

import qualified Data.ByteString.Char8                  as BC
import qualified Data.ByteString.Lazy.Char8             as BL
import qualified Data.ByteString                        as B(ByteString)
import qualified Data.ByteString.Char8                  as BS
import qualified Data.Text                              as TE
import qualified Data.Text.Encoding                     as TE

import Control.Concurrent.MVar
import Data.IORef
import Data.Aeson
import qualified Data.Map                               as M
import qualified Data.Vector                            as V
import Control.Monad
import Control.Monad.State
import Control.Applicative


-- | The cloud monad: a thin layer over 'TransIO' that forces the type system to
-- require 'Loggable' constraints on distributed results, ensuring every
-- intermediate value can be checkpointed and replayed across restarts.
--
-- All the instances are derived from 'TransIO', including the ones that are defined with its applicative
-- (@Semigroup@, @Monoid@, @Num@...). The applicative of 'TransIO' puts in the log the result of both terms of a
-- distributed applicative ('apTransIO' in "Transient.LEngine"), so the distributed conjunctions made with any of them
-- are resolved as the ones made with @<*>@, and a new binary operator defined for 'TransIO' does not have to be
-- defined again for 'Cloud'.
newtype Cloud a = Cloud {unCloud :: TransIO a}
  deriving
    ( AdditionalOperators,
      Functor,
      Semigroup, Monoid,
      Alternative,
      Applicative,
      MonadFail,
      Monad,
      Num,
      Fractional,
      MonadState TranShip
    )



--       --  prevc@(PrevClos{isApplicative= mode}) <- getState
--        log <- getLog
--        isapp <- gets isApplicative
--       --  when (isapp == AppFirst) $ do modify $ \s ->s{isApplicative= AppSecond}; endpoint Nothing <|> guard (not $ recover log)

--       --  setState prevc{isApplicative= True}
--       --  modify $ \s ->s{isApplicative= True}
--        ttr "APPLICATIVE SET"
--        r <- (a <*> b)  <|> (do modify $ \s ->s{isApplicative= isapp} ; empty)
--       --  void $ modifyState' (\prev -> prev{isApplicative = mode}) $ error "Cloud Applicative: state not found"
--        modify $ \s ->s{isApplicative= isapp}
--        return r

-- instance Monoid a => Monoid (Cloud a) where
--   mempty      = return mempty
--   mappend  = (<>)

-- instance (Monoid a) => Semigroup (Cloud a) where
--   (<>)=  mappendt


instance ToJSON B.ByteString where
  toJSON = Data.Aeson.String . TE.decodeUtf8

instance FromJSON B.ByteString where
  parseJSON = Data.Aeson.withText "ByteString" $ \t ->
    return (TE.encodeUtf8 t)

instance ToJSON BL.ByteString where
  toJSON = toJSON . BL.toStrict

instance FromJSON BL.ByteString where
  parseJSON v = BL.fromStrict <$> parseJSON v

-- | Identifies a specific checkpoint closure within a session.
newtype ClosureId = ClosureId BC.ByteString deriving (Typeable,Read,Show,Eq,Ord,Generic,FromJSON,ToJSON)
-- | Identifies a browser/client session.
newtype SessionId = SessionId BC.ByteString deriving (Typeable,Read,Show,Eq,Ord,Generic,FromJSON,ToJSON)

instance Loggable ClosureId where
  serialize (ClosureId i)= serialize i
  deserialize= ClosureId <$> deserialize

instance Loggable SessionId where
  serialize (SessionId s)= serialize s
  deserialize = SessionId <$> deserialize



-- | previous local checkpointed closure in the execution flow
data PrevClos = PrevClos{ prevDBRef     :: DBRef LocalClosure
                        , pnewSession   :: Maybe SessionId
                        , preservePath  :: Bool
                        , isApplicativ :: Bool
                        , isCollect     :: Bool
                        } deriving Show

instance Default PrevClos where 
  def= PrevClos dbClos0 Nothing False False False

-- | last remote closure in a teleport waiting for responses in the execution flow
newtype ClosToRespond= ClosToRespond (DBRef LocalClosure) -- {remSession :: SessionId, remClosure :: ClosureId}

-- data ConcurrentClosure= ConcurrentClosure (DBRef LocalClosure)


-- | Broadcast message: a node signals it is ready to resume unfinished jobs.
newtype Ping = Ping Node

-- | A cluster node identified by host and port, with an optional connection pool
-- and the list of services it advertises.
data Node = Node
  { nodeHost :: NS.HostName,
    nodePort :: Int,
    connection :: Maybe (MVar Pool),
    nodeServices :: [Service]
  }
  deriving (Typeable,Generic)

instance FromJSON Node

instance ToJSON Node

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

instance ToJSON (MVar a) where
  toJSON mv= Null

instance FromJSON (MVar a) where
  parseJSON _= return (unsafePerformIO  newEmptyMVar)






instance Loggable Node

instance Ord Node where
  compare node1 node2 = compare (nodeHost node1, nodePort node1) (nodeHost node2, nodePort node2)



data CloudException = CloudException Node SessionId ClosureId String deriving (Typeable, Show, Read)

instance Exception CloudException

-- | An open connection to another node.  Shared by concurrent wormhole\/teleport calls
-- via the 'isBlocked' semaphore.  'connData' holds the transport-specific handle
-- (TCP socket, TLS context, WebSocket, or 'Self').
data Connection = Connection
  { idConn :: Int,
    myNode :: IORef Node,
    remoteNode :: IORef (Maybe Node),
    connData :: IORef (Maybe ConnectionData),
    istream :: IORef ParseContext,
    bufferSize :: BuffSize,
    isBlocked :: Blocked,           -- ^ serialises concurrent senders
    calling :: Bool,
    synchronous :: Bool,
    closChildren :: IORef (M.Map Int TranShip)  -- ^ per-closure child states for 'single'\/'unique'
  }
  deriving (Typeable)

instance Show Connection where
  show x= show $ lazy $ readIORef $ remoteNode x

-- last usage+ blocking semantics for sending
type Blocked = MVar (Maybe Integer)

type BuffSize = Int

-- | Parsed HTTP request line (version, status\/method, path) plus the raw header list.
data HTTPHeaders = HTTPHeaders (BL.ByteString, B.ByteString, BL.ByteString) NWS.Headers deriving (Show)
emptyHeaders= HTTPHeaders (mempty,mempty,mempty)[]

instance Show WS.Connection where
  show _ = "WS"

-- | The transport-specific handle stored inside a 'Connection'.
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

type IsFromRemoteNode= Bool

-- | A TCache-persisted closure record.  Stored under key @\<closureId\>-\<sessionId\>@.
-- 'localLog' is the serialised log fragment; 'localEvar' is the live EVar that
-- 'receive1' writes to when a remote response arrives.
data LocalClosure = LocalClosure
  { localClos     :: ClosureId,
    localSession  :: SessionId,
    prevClos      :: DBRef LocalClosure,
    localLog      :: FragmentType,
    localMvar     :: MVar (),
    localEvar     :: Maybe (EVar (Either CloudException (StreamData [FragmentType], SessionId, ClosureId, PolyMap,IsFromRemoteNode))),
    localCont     :: Maybe TranShip,
    -- | The node that called this node when this closure was created by the arrival of a request (the first teleport
    -- of a runAt, in the called side). It is persisted. When this node is recovered by a job after a restart, the
    -- connection to the caller does not exist: the second teleport opens it with this node. The closure to respond to
    -- ('ClosToRespond') has the same key as this closure, since the names of the endpoints are the same in all the nodes.
    localCaller   :: Maybe Node
  }

instance Show LocalClosure where show lc= keyResource lc

-- | A log segment: either immutable or a mutable hole.
--
-- Mutable holes solve the problem of the logs of the applicative with asynchronous terms
-- (see the documentation of 'logged' and 'apTransIO'). In @f \<*> x@, @fparallel@
-- executes @f@ and @xparallel@ executes @x@ ('Transient.LEngine'). When the first term is
-- asynchronous, the two branches continue in different threads with different logs, and the one
-- that completes the applicative takes the value of the other term from memory, not from the log.
-- A remote node (or a restart) that replays that log could not resolve the applicative.
-- The holes put the value of the other term in the log as soon as it is known, so any log
-- serialised afterwards carries both values.
-- (the declarations of 'LogSeg', 'LogB', 'FragmentType' and 'Log' are in Transient.LEngine)

instance Semigroup LogB where
  LogB xs <> LogB ys = LogB (xs ++ ys)   -- segments are not merged: 'deltaLog' relies on prefixes

instance Monoid LogB where
  mempty = LogB []

instance IsString LogB where
  fromString = fixed . fromString

instance Show LogB where
  showsPrec d = showsPrec d . renderLog

instance Read LogB where
  readsPrec d s = [(fixed b, r) | (b, r) <- readsPrec d s]

instance Loggable LogB where
  serialize = renderLog
  deserialize = fixed <$> deserialize

-- | Immutable log segment.
fixed :: Builder -> LogB
fixed b = LogB [Fixed b]

-- | 'Wait' segment: the value of an applicative term (initially @w\/@).
waitSeg :: IORef Builder -> LogB
waitSeg w = LogB [Wait w]

-- | The segments that the second log adds to the first one, which is a prefix of it.
deltaLog :: LogB -> LogB -> LogB
deltaLog (LogB initial) (LogB after) = LogB (drop (length initial) after)

-- | Convert to 'Builder'. Holes are read each time the builder is run,
-- not when it is built, so the current content is always serialised.
renderLog :: LogB -> Builder
renderLog (LogB segs) = foldMap seg segs
  where
  seg (Fixed b) = b
  seg (Wait r)  = BI.builder $ \k br -> readIORef r >>= \b -> BI.runBuilderWith b k br
  seg (Pending io) = BI.builder $ \k br -> io >>= \l -> BI.runBuilderWith (renderLog l) k br

-- | True if the log is empty.
nullLog :: LogB -> Bool
nullLog = BL.null . toLazyByteString . renderLog

deriving instance Show Log
deriving instance Show FragmentType
deriving instance Read FragmentType

instance Loggable FragmentType

-- | Get the current log data.
getLog :: TransMonad m => m Log
getLog= gets mfLog

-- | Set the log data.
putLog :: TransMonad m => Log -> m ()
putLog l= modify $ \st -> st{mfLog= l}

-- | Modify the log data and return the new value.
modifyLog :: TransMonad m => (Log -> Log) -> m Log
modifyLog f= do
  st <- get
  let l= f (mfLog st)
  put st{mfLog= l}
  return l

-- | The hash of the execution path ('hashClosure') names the endpoints by their position in the program,
-- so that the same point has the same name in every node and in every replay. Each step of the path
-- is combined with 'hashStep', which is not commutative: the name depends on the order of the steps,
-- not only on how many there are of each kind. (An additive hash gave the same name to different points,
-- e.g. an endpoint inside a previous remote call and an endpoint after it.)

-- | A persistent job record: tracks the closure to resume, the node it runs on,
-- and any error string from the last failed attempt.
data Job= Job {jobClosure :: DBRef LocalClosure,jobNode :: Node, jobError :: Maybe String
              ,jobScoped :: Bool  -- ^ created by 'Transient.Move.Job.jobTask': it is not closed by the sending of a call
              }  deriving (Typeable,Read,Show)
instance TC.Indexable Job where key (Job dbr  _ _ _)= 'J':keyObjDBRef dbr

-- | Build the TCache key for a 'LocalClosure': @\<closureId\>-\<sessionId\>@.
kLocalClos (SessionId idSess) (ClosureId clos) = BC.unpack clos <> "-" <> BC.unpack idSess

-- | Extract the 'SessionId' and 'ClosureId' encoded in a 'LocalClosure' DBRef key.
getSessClosure :: DBRef LocalClosure -> (SessionId, ClosureId)
getSessClosure dbref= let (c,s)= span (/= '-') $ keyObjDBRef dbref
                      in  (SessionId $ BC.pack $ tail s, ClosureId $ BC.pack  c)

instance TC.Indexable LocalClosure where
  key LocalClosure {..} = kLocalClos localSession localClos

instance {-# OVERLAPPABLE #-}  (Show a, Read a) => TC.Serializable a where
  serialize = BL.pack . show
  deserialize = read . BL.unpack

instance TC.Serializable LocalClosure where
  serialize LocalClosure {localClos=ClosureId c,localSession=SessionId s,..} = TC.serialize (c,s, prevClos, localLog, localCaller)
  deserialize str =
    let (localClos,localSession, prevClos, localLog, localCaller) = TC.deserialize str
        block = unsafePerformIO $ newMVar ()
     in LocalClosure (ClosureId localClos) (SessionId localSession)   prevClos  localLog  block Nothing Nothing localCaller

dbClos0= getDBRef $ kLocalClos sessionId0 closureId0 :: DBRef LocalClosure

sessionId0= SessionId "0"
closureId0= ClosureId "0"

type Pool = [Connection]
type SKey = String
type SValue = String
newtype Service =Service (M.Map SKey SValue) deriving (Show,Read,Generic,Eq,Semigroup,Monoid,ToJSON,FromJSON)

instance  Loggable Service where
  serialize (Service s)= serialize s
  deserialize = Service <$> deserialize

instance Default Service where
  def=  Service $ M.fromList [("service","$serviceName")
        ,("executable", "$execName")
        ,("package","$gitRepo")]

instance Default [Service] where
  def= [def]

instance Default TE.Text where
  def=mempty

-- | Wire message between nodes: carries source and destination closure\/session IDs
-- plus the log fragments that form the continuation payload.
data NodeMSG = ClosureData ClosureId SessionId ClosureId SessionId [FragmentType] deriving (Read, Show)

instance Loggable NodeMSG where
  serialize :: NodeMSG -> Builder
  serialize (ClosureData (ClosureId clos) 
                         (SessionId s1) 
                         (ClosureId clos') 
                         (SessionId s2) build) =
    byteString clos 
      <> "/" 
      <> byteString s1 
      <> "/"
      <> byteString clos'
      <> "/"
      <> byteString s2
      <> "/"
      <> serialize  (coerce build ::[FragmentType])

  deserialize :: TransIO NodeMSG
  deserialize =
    ClosureData 
      <$> (ClosureId <$> readit) 
      <*> (SessionId <$> readit)
      <*> (ClosureId <$> readit)
      <*> (SessionId <$> readit)
      <*>  coerce (deserialize :: TransIO [FragmentType])

    where
      readit= BL.toStrict <$> tTakeWhile (/= '/') <* tChar '/'
      restOfIt = lazyByteString <$> giveParseString


-- The remote closure ids for each node connection
type Closure = DBRef LocalClosure -- Closure SessionId ClosureId [Int] deriving (Read, Show, Typeable)


-- | Thrown when a connection to a remote node fails.
data ConnectionError = ConnectionError String Node deriving (Read)

instance Show ConnectionError where
  show (ConnectionError str n)= "Connection Error : "<> str <> " \n\nNode:\n\n" <> BL.unpack (encode n)

instance Exception ConnectionError

-- | HTTP request method used in 'HTTPReq'.
data HTTPMethod = GET | POST deriving (Read, Show, Typeable, Eq,Generic)

instance Loggable HTTPMethod

instance ToJSON HTTPMethod

-- | Map from endpoint name to its 'HTTPReq' descriptor; sent to the browser so it
-- can discover and invoke available endpoints.
newtype Endpoints= Endpoints (M.Map BL.ByteString HTTPReq) deriving Show

-- | Describes a single HTTP endpoint: method, URL (possibly containing @\$type@
-- placeholders), extra headers, and a default JSON body for POST requests.
data HTTPReq = HTTPReq
  { reqtype :: HTTPMethod,
    requrl :: BL.ByteString,
    reqheaders :: BL.ByteString,
    reqbody :: Value
  }
  deriving (Read, Show, Typeable, Generic)

instance Semigroup Value where
  Null <> val= val
  val  <> Null= val
  v <> v' = error "Value monoid"
 

instance Monoid Value where
  mempty  = Null
  mappend = (<>)


type RemoteClosure = (Node, ClosureId)

newtype JobGroup = JobGroup (M.Map BC.ByteString RemoteClosure) deriving (Typeable)


-- | An endpoint registered via 'publish': its name, display message, and 'HTTPReq' descriptor.
data InputData = InputData {idInput :: String, message :: BL.ByteString, hTTPReq :: HTTPReq} deriving (Show, Read, Typeable)

newtype Cookies= Cookies  [(BL.ByteString,BL.ByteString)]



-- | set a cookie in the browser.
-- Example

-- > setCookie "<cookie-name>" "<cookie-value>; Domain=<domain-value>; Secure; HttpOnly"
-- 
-- See https://developer.mozilla.org/es/docs/Web/HTTP/Headers/Set-Cookie for cookie options
setCookie :: BL.ByteString -> BL.ByteString -> TransIO ()
setCookie name valueandparams= do
  ttr "setCookie"
  Cookies cs <- getCookies
  setState $ Cookies $ (name,valueandparams):cs
  where
  getCookies :: TransIO Cookies
  getCookies= tryState <|> return (Cookies [])


-- | Read a named cookie from the current HTTP request headers.
-- Returns 'Nothing' if the cookie is absent or the header list is empty.
getCookie :: BL.ByteString -> TransIO (Maybe BS.ByteString)
getCookie name= do
  HTTPHeaders _ headers :: HTTPHeaders <- tryState <|>  return (HTTPHeaders undefined [])
  tr ("getCookie HTTP HEADERS",headers)
  let receivedCookie= lookup "Cookie" headers

  liftIO $ print ("cookie", receivedCookie)
  case receivedCookie of
    Just str->  (withParseString (BS.fromStrict str) search) <|> return Nothing
    Nothing -> return Nothing
    where
    search= do
       tr "search cookie"
       d <- isDone
       if d then return Nothing else do
                dropSpaces
                name' <- tTakeWhile' (/='=')
                val <- tTakeWhile' (/=';')
                liftIO $ print (name',val)
                if name'== name then return $ Just $ BS.toStrict val else search

