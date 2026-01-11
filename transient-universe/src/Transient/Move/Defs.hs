{-#Language RecordWildCards,DeriveGeneric,CPP, UndecidableInstances
, OverlappingInstances,FlexibleInstances,GeneralizedNewtypeDeriving, OverloadedStrings #-}
{-# LANGUAGE InstanceSigs #-}

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
import qualified Data.Text                              as TE
import Control.Concurrent.MVar
import Data.IORef
import Data.Aeson
import qualified Data.Map                               as M

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
--   pure :: a -> Cloud a
--   pure x = Cloud $ return x
  
--   (<*>) :: Cloud (a -> b) -> Cloud a -> Cloud b
--   Cloud f <*> Cloud g = Cloud $ sandboxData (ofType :: PrevClos) 
--                               $ sandboxData (ofType :: M.Map Int Closure) 
--                               $ do
--         tr "ISAPP"
--         -- modifyState' (\(PrevClos dbr _ _) -> PrevClos dbr False True) (PrevClos dbClos0 False True)
--         f <*> g



-- | previous local checkpointed closure in the execution flow
data PrevClos = PrevClos{dbref:: DBRef LocalClosure, newSession :: Maybe Int, preservePath :: Bool, isApplicative :: Bool} deriving Show

-- | last remote closure in a teleport waiting for responses in the execution flow
newtype ClosToRespond= ClosToRespond (DBRef LocalClosure) -- {remSession :: SessionId, remClosure :: IdClosure}



type IdClosure = BC.ByteString
type SessionId = Int



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



data CloudException = CloudException Node SessionId IdClosure String deriving (Typeable, Show, Read)

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
  { localClos     :: IdClosure,
    localSession  :: Int,
    prevClos      :: DBRef LocalClosure,
    localLog      :: [Builder],
    localMvar     :: MVar (),
    localEvar     :: Maybe (EVar (Either CloudException (StreamData [[Builder]], SessionId, IdClosure, Connection))),
    localCont     :: Maybe TranShip
  }
  -- | ListPrecessors [DBRef LocalClosure]

kLocalClos idSess clos = BC.unpack clos <> "-" <> show idSess

getSessClosure :: DBRef LocalClosure -> (Int, IdClosure)
getSessClosure dbref= let (c,s)= span (/= '-') $ keyObjDBRef dbref
                      in  (read $ tail s, BC.pack  c)

instance TC.Indexable LocalClosure where
  key LocalClosure {..} = kLocalClos localSession localClos

instance (Show a, Read a) => TC.Serializable a where
  serialize = BL.pack . show
  deserialize = read . BL.unpack

instance TC.Serializable LocalClosure where
  serialize LocalClosure {..} = TC.serialize (localClos,localSession, prevClos, localLog)
  deserialize str =
    let (localSession, prevClos, localLog,  localClos) = TC.deserialize str
        block = unsafePerformIO $ newMVar ()
     in LocalClosure localSession prevClos localLog  localClos block Nothing Nothing

dbClos0= getDBRef $ kLocalClos 0 "0" :: DBRef LocalClosure


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

data NodeMSG = ClosureData IdClosure SessionId IdClosure SessionId [[Builder]] deriving (Read, Show)

instance Loggable NodeMSG where
  serialize :: NodeMSG -> Builder
  serialize (ClosureData clos s1 clos' s2 build) =
    byteString clos <> "/" <> intDec s1 <> "/"
      <> byteString clos'
      <> "/"
      <> intDec s2
      <> "/"
      <> serialize build

  deserialize :: TransIO NodeMSG
  deserialize =
    ClosureData <$> (BL.toStrict <$> tTakeWhile (/= '/') <* tChar '/') <*> (int <* tChar '/')
      <*> (BL.toStrict <$> tTakeWhile (/= '/') <* tChar '/')
      <*> (int <* tChar '/')
      <*> deserialize
    where
      restOfIt = lazyByteString <$> giveParseString


-- The remote closure ids for each node connection
type Closure = DBRef LocalClosure -- Closure SessionId IdClosure [Int] deriving (Read, Show, Typeable)


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
    reqbody :: BL.ByteString
  }
  deriving (Read, Show, Typeable, Generic)

