{-#Language RecordWildCards,DeriveGeneric,CPP, UndecidableInstances
, OverlappingInstances,FlexibleInstances,GeneralizedNewtypeDeriving, OverloadedStrings #-}
{-# LANGUAGE InstanceSigs,ScopedTypeVariables #-}

-- Dedicado a Jesucristo, mi salvador

module Transient.Move.Defs where

import Transient.Internals
import Transient.EVars
import Transient.Loggable
import Transient.Parse

import Data.ByteString.Builder
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
import Control.Monad.State
import Control.Applicative


-- The cloud monad is a thin layer over Transient in order to make sure that the type system
-- forces the logging of intermediate results
newtype Cloud a = Cloud {unCloud :: TransIO a}
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
      MonadState TranShip
    )


-- instance Monoid a => Monoid (Cloud a) where
--   mappend = (<>) 
--   mempty= return mempty

-- instance Semigroup a => Semigroup (Cloud a) where
--   a <> b= (<>) <$> a <*> b
  
-- instance Applicative Cloud where
--   return :: a -> Cloud a
--   return x = Cloud $ return x
  
--   (<*>) :: Cloud (a -> b) -> Cloud a -> Cloud b
--   Cloud f <*> Cloud g = Cloud $ sandboxData (ofType :: PrevClos) 
--                               $ sandboxData (ofType :: M.Map Int Closure) 
--                               $ do
--         tr "ISAPP"
--         -- modifyState' (\(PrevClos dbr _ _) -> PrevClos dbr False True) (PrevClos dbClos0 False True)
--         f <*> g

instance ToJSON B.ByteString where
  toJSON = Data.Aeson.String . TE.decodeUtf8

instance FromJSON B.ByteString where
  parseJSON = Data.Aeson.withText "ByteString" $ \t ->
    return (TE.encodeUtf8 t)

instance ToJSON BL.ByteString where
  toJSON = toJSON . BL.toStrict

instance FromJSON BL.ByteString where
  parseJSON v = BL.fromStrict <$> parseJSON v

newtype ClosureId = ClosureId BC.ByteString deriving (Typeable,Read,Show,Eq,Ord,Generic,FromJSON,ToJSON)
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
                        , isApplicative :: Bool
                        , isCollect     :: Bool
                        } deriving Show

-- | last remote closure in a teleport waiting for responses in the execution flow
newtype ClosToRespond= ClosToRespond (DBRef LocalClosure) -- {remSession :: SessionId, remClosure :: ClosureId}



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

    -- for each remote closure that points to local closure 0,
    -- a new container of child processMessagees
    -- in order to treat them separately
    -- so that 'killChilds' do not kill unrelated processMessagees
    -- used by `single` and `unique`
    closChildren :: IORef (M.Map Int TranShip)
  }
  deriving (Typeable)

instance Show Connection where
  show x= show $ lazy $ readIORef $ remoteNode x


-- last usage+ blocking semantics for sending
type Blocked = MVar (Maybe Integer)

type BuffSize = Int

-- type PortID = Int

data HTTPHeaders = HTTPHeaders (BL.ByteString, B.ByteString, BL.ByteString) NWS.Headers deriving (Show)
emptyHeaders= HTTPHeaders (mempty,mempty,mempty)[]

instance Show WS.Connection where
  show _ = "WS"

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

data LocalClosure = LocalClosure
  { localClos     :: ClosureId,
    localSession  :: SessionId,
    prevClos      :: DBRef LocalClosure,
    localLog      :: FragmentType,
    localMvar     :: MVar (),
    localEvar     :: Maybe (EVar (Either CloudException (StreamData [FragmentType], SessionId, ClosureId, PolyMap))),
    localCont     :: Maybe TranShip
  } 

instance Show LocalClosure where show lc= keyResource lc

-- instance Read LocalClosure where 
--   readsPrec _ s= 
--     let (key,rest): _ = readsPrec 0 s
--     in [(lazy $ getResource key `onNothing` error ("Read LocalClosure error in "<> s),rest)]


-- | The 'Log' data type represents the current log data, which includes information about whether recovery is enabled, the partial log builder, and the hash closure.
data Log  = Log{ recover :: Bool , partLog :: Builder, restLog :: [FragmentType],  hashClosure :: Int} deriving (Show)

-- [[Builder]] example:  [["e/f/x/w/u","b/l/ah/"],["single/branch"]... : 
-- The first group correspond with a collectc of two branches.
-- Normally thereis one branch 

-- Each restlog is a transition from a closure to another. closures are in sequence, except in the case of a jump

type ClosureKey = String

data FragmentType= Fragment{unFragment :: Builder} | Collect [Builder] | Jump ClosureKey deriving (Read,Show)

instance Loggable FragmentType

-- | Get the current log data.
getLog :: TransMonad m => m Log
getLog= getData `onNothing` return emptyLog

emptyLog= Log False  mempty []  0


kLocalClos (SessionId idSess) (ClosureId clos) = BC.unpack clos <> "-" <> BC.unpack idSess

getSessClosure :: DBRef LocalClosure -> (SessionId, ClosureId)
getSessClosure dbref= let (c,s)= span (/= '-') $ keyObjDBRef dbref
                      in  (SessionId $ BC.pack $ tail s, ClosureId $ BC.pack  c)

instance TC.Indexable LocalClosure where
  key LocalClosure {..} = kLocalClos localSession localClos

instance {-# OVERLAPPABLE #-}  (Show a, Read a) => TC.Serializable a where
  serialize = BL.pack . show
  deserialize = read . BL.unpack

instance TC.Serializable LocalClosure where
  serialize LocalClosure {localClos=ClosureId c,localSession=SessionId s,..} = TC.serialize (c,s, prevClos, localLog)
  deserialize str =
    let (localClos,localSession, prevClos, localLog) = TC.deserialize str
        block = unsafePerformIO $ newMVar ()
     in LocalClosure (ClosureId localClos) (SessionId localSession)   prevClos  localLog  block Nothing Nothing

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


data ConnectionError = ConnectionError String Node deriving (Read)

instance Show ConnectionError where
  show (ConnectionError str n)= "Connection Error : "<> str <> " \n\nNode:\n\n" <> BL.unpack (encode n)

instance Exception ConnectionError

data HTTPMethod = GET | POST deriving (Read, Show, Typeable, Eq,Generic)

instance Loggable HTTPMethod

instance ToJSON HTTPMethod

newtype Endpoints= Endpoints (M.Map BL.ByteString HTTPReq) deriving Show

data HTTPReq = HTTPReq
  { reqtype :: HTTPMethod,
    requrl :: BL.ByteString,
    reqheaders :: BL.ByteString,
    reqbody :: Value -- BL.ByteString
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


data InputData = InputData {idInput :: String, message :: BL.ByteString, hTTPReq :: HTTPReq} deriving (Show, Read, Typeable)
-- instance Loggable InputData

{-# NOINLINE firstEndpointName #-}
firstEndpointName :: IORef String
firstEndpointName = unsafePerformIO $ newIORef ""


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
  getCookies= getState <|> return (Cookies [])


getCookie :: BL.ByteString -> TransIO (Maybe BS.ByteString)
getCookie name= do
  HTTPHeaders _ headers :: HTTPHeaders <- getState <|>  return (HTTPHeaders undefined [])
  ttr ("getCookie HTTP HEADERS",headers)
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

