{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE InstanceSigs #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}
{-# HLINT ignore "Use typeRep" #-}

#ifndef ghcjs_HOST_OS


module Transient.Move.Web
  ( minput,
    followup,
    output,
    moutput,
    publish,
    publishn,
    published,
    showURL,
    getURL,
    ToHTTPReq (..),
    POSTData (..),
    HTTPReq (..),
    AsJSON (..),
    rawHTTP,
    serializeToJSON,
    deserializeJSON,
    IsCommand,
    optionEndpoints,
    getCookie,
    setCookie,
    
  )
where

import Control.Applicative
import Control.Concurrent.MVar
import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.State
import Data.Aeson
import Data.ByteString.Builder
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Lazy.Char8 as BS
import Data.Char
import Data.Default
import Data.IORef
import qualified Data.Map as M
import Data.Maybe
import Data.TCache hiding (onNothing)
import qualified Data.TCache.DefaultPersistence as TC
import Data.Typeable
import GHC.Generics
import System.IO.Unsafe
import System.Time
import Transient.Console
import Transient.Internals
import Transient.Move.Logged
import Transient.Loggable(Raw(..))
import Transient.Move.Defs
import Transient.Move.Internals
import Transient.Parse
import Transient.Move.JSON
import Transient.Move.Job
import Unsafe.Coerce
import Data.List

-- for set/getCookieData

import Foreign.StablePtr
import GHC.Stable (newStablePtr, deRefStablePtr, freeStablePtr)
import Foreign.Ptr (Ptr, ptrToIntPtr, intPtrToPtr)
import Data.Time.Clock
import Data.Word (Word64)
import Text.Read (readMaybe)

import Control.Exception hiding(try,onException)

data InitSendSequence = InitSendSequence

type ShowIt= Bool
data Publishing = Publishing ShowIt [String]

data IsCommand = IsCommand deriving (Show)




instance ToJSON HTTPReq

instance Monoid HTTPReq where
  mempty = HTTPReq GET mempty mempty mempty

instance Semigroup HTTPReq where
  (<>) (HTTPReq a b c d) (HTTPReq a' b' c' d') =
    HTTPReq
      (if a == POST || a' == POST then POST else GET)
      (b <> b')
      (c <> c')
      (d <> d')

-- | A composable web input endpoint.
--
-- Registers an HTTP endpoint (GET or POST)
--
-- @minput@ calls are fully composable: they can be combined with '<|>', '>>=',
-- and other transient/cloud primitives to build interactive flows that are
-- streamed to the client as chunked HTTP responses.
--
-- = Parameters
--
-- [@ident@]: The endpoint name. Used as the URL path segment
--   (@\/ident@) and as the console prompt label.
--
-- [@msg@]: A JSON-encodable value sent to the caller as the response payload
--   for this step. It is included in the field "msg" of the JSON response. The rest
--   of the JSON response is the "req" field of the `HTTPReq` datatype.
--
--  = Example:
--
-- >  POSTData( i :: Int) <- minput "endp"  "enter a int" 
--
-- Send this message to the client:
--
-- > [{ "msg":"enter a int", "req":{"reqbody":0,"reqheaders":"","reqtype":"POST","requrl":"http://localhost:8080/endp"}}]
--
--  This:
--
--  (i :: Int) <- input "endp"  "enter a int"
--
-- Send this message to the client:
--
-- > [{ "msg":"enter a int", "req":{"reqbody":null,"reqheaders":"","reqtype":"GET","requrl":"http://localhost:8080/endp/$int"}}]
--
-- GET requests to be sent to the server include a variable in the requrl
--
-- reqbody, in  POST messages contains the default value for the type to be returned. 
-- The "msg" and the "req" fields contains all the information necessary for the next iteration with the server.
-- With this information, the client can compose a valid response following the HATEOAS model.
-- Note that the response is enclosed in an array. The reason is because that an expression using minput
-- can send a finite or infinite stream of JSON responses. Explanation below.
--
-- = Return value
--
-- The value submitted by the caller — parsed from the HTTP request body\/query
-- string — deserialized into type @a@.
--
-- Example
--
-- > (minput "name"    "Enter your name"    >>= processName)    <|>
-- > (minput "product" "Enter product code" >>= processProduct) <|>
-- > stream
-- > where
-- >   stream = foldl (<|>) empty $ map moutput eventList
--
-- All branches are sent as a single chunked HTTP response; the connection stays
-- open until every @minput@ and 'moutput' in the composition has finished.
--
-- For programs distributed across nodes (including web nodes) that share the
-- same code base, prefer 'runAt' and other distributed primitives over
-- @minput@. @minput@ is the primary way to interact with external clients that
-- do not share the application code.

-- | Initialize the session from the browser's 'state' cookie, or create a new
-- one if absent.  Returns the (possibly updated) session ID and 'PrevClos' DBRef.
initSession :: BC.ByteString -> TransIO ()
initSession idSession = when (idSession == "0") $ do
  ttr "INITSESSION"
  session <-  getSessionFromCookieAndLog 
  setSession session
 <|> return()
  where
  getSessionFromCookieAndLog= logged $ do
      HTTPHeaders _ headers <- tryState <|> return (HTTPHeaders undefined [])
      when (null headers) $
          error "initSession: no Headers"  -- sin contexto HTTP (Self/cross-call/replay): no generar sesión
      mc <- getCookie "state"
      case mc of
        Just c | not (BC.null c) -> return c
        _ -> do s <- genSessionId
                setCookie "state" $ BS.fromStrict s <> "; Path=/"
                return s

minput
  :: (ToJSON p, Loggable a, ToHTTPReq a, Typeable p) =>
     String -> p -> Cloud a

minput (ident :: String) msg' = onAll $ sandboxData (ofType :: ClosToRespond) $ unCloud response
  where
    msg= encode msg'
    response = do
      ttr ("MINPUT", ident)
      delState (ofType :: ClosToRespond)
      modify $ \s -> s {execMode = if execMode s == Remote then Remote else Parallel}
      local $ do
        log <- getLog
        conn <- tryState -- if connection not available, execute alternative computation
        let closLocal = hashClosure log
        mynode <- getMyNode
        PrevClos dbprevclos mn _ _ _ :: PrevClos <- getData `onNothing` noExState "minput"
        ttr ("prevclos",dbprevclos, keyObjDBRef dbprevclos)
        let SessionId idSession = fromMaybe (fst $ getSessClosure dbprevclos) mn
        let urlbase =
              str "http://" <> str (nodeHost mynode) <> str ":" <> intt (nodePort mynode)
                </> str ident
                -- </> "S" <> BS.fromStrict idSession
                -- </> BL.fromStrict closRemote
                -- </> intt sess
                -- </> intt idcontext ::
                -- BS.ByteString

        params <- toHTTPReq $ type1 response
        ttr ("params",params)
        let httpreq = mempty {requrl = urlbase} <> params :: HTTPReq
            httpreqsess= mempty {requrl = urlbase  </> "S" <> BS.fromStrict idSession} <> params :: HTTPReq
            -- msgdat must be valid JSON. `msg = encode msg'` already covers all cases:
            -- String -> "text", number -> 42, tuple -> [..]. sendOption inserts it raw.
            msgdat = msg

        -- publish immediately if we're inside a publish block
        Publishing visible keys <- tryState  <|> return (Publishing True [])
        let idata = InputData ident msgdat httpreqsess
        liftIO $ mapM_ (\k -> atomicModifyIORef rpublished $ \map ->
            (let idatas = idata : fromMaybe [] (M.lookup k map) in M.insert k idatas map, ())) keys
        connected visible log  idSession conn closLocal  httpreq -- <|> commandLine conn log httpreq


    connected visible log  idSession conn closLocal  httpreq = do

      cdata <- liftIO $ readIORef $ connData conn

      Endpoints endpts <- getEndpoints
      ttr ("insert endpoint",ident)
      setRState $ Endpoints  $ M.insert (str ident) httpreq endpts
      ttr ("ADDED ENDPOINT",ident,httpreq, "previous endpoints:", M.keys endpts)
      result <- do -- (idcontext' :: BC.ByteString, result) <- do
        pstring <- giveParseString
        if not (recover log) || BS.null pstring
          then do
            tr "EN NOTRECOVER"

            case cdata of
              Just Self -> do
                endpointEtc
                tr "SELF XXX"
                (string "e/" >> string "e/") <|> return "e/"
                r <- readResponse
                initSession idSession
                return r


              _ -> do
                sendCookies conn
                ttr ("sendIT? visibe, recovrer?",visible, recover log)
                when (visible && not (recover log)) $ do
                  let tosend = str "{ \"msg\":" <>  msg <> str ", \"req\":" <> encode httpreq <> str "}"
                  let l = fromIntegral $ BS.length tosend
                  msend conn $ toHex l <> str "\r\n" <> tosend <> "\r\n"
                tr "after msend"
                endpointEtc
                r <- readResponse
                initSession idSession
                return r

          else do
            -- the program has just restarted and recovered and this endpoint is active waiting for requests.
            -- Perhaps a request waked up that endpoint

            endpointEtc
            -- logged will deserialize the request parameters
            r <- readResponse
            initSession idSession
            return r

            
      ttr ("MINPUT RESULT",result)
      delRState InitSendSequence
      delState IsCommand
      return result `asTypeOf` return (type1 response)

      where

      readResponse= logged $ error "minput: insuficient parameters" -- only read from the log. if the log is consumed before generating a valid response, raises the error
    
      endpointEtc= do
        
        endpoint (Just $ BC.pack ident)
        -- for cross-sessions where there is a jump
        -- in which one user/session invokes a link/endpoint of another
        mmfdata <- getSessionData
      
        when (isJust mmfdata) $ do
          ttr ("mmfdata",mmfdata)
          let mfdata= fromJust mmfdata

          -- merge the state of the computation that created the encpoint with the state of the coming computation
          modify $ \s-> s{mfData= merge mfdata $ mfData s}
          -- endpoint (Just $ BC.pack ident) <|> return()

      merge = M.unionWithKey combine
      combine :: TypeRep -> SData -> SData -> SData
      combine t x y | t == typeOf (ofType :: Connection) = x
                    | t == typeOf (ofType :: PrevClos) = 
                           let pc= unsafeCoerce y
                           in unsafeCoerce  $ pc{pnewSession= Just $ fst . getSessClosure $ prevDBRef $ unsafeCoerce x} 
                    -- | t == typeOf (ofType :: PrevClos) = y
                    | t == typeOf (ofType :: Log) = y
                    | otherwise= x

    (</>) x y = x <> str "/" <> y
    str = BS.pack
    intt = str . show
    type1 :: Typeable a => Cloud a -> a
    type1 cx = r
      where
        r = error $ show $ typeOf r


-- | in a sequence of minputs it may be mind bending to have inputs without outpts
-- since each minput send the response of the previous minput.
-- It is more natural to invert the minput arguments so that the second argument (the response) becomes the first
-- and the endpoint string becomes the second so that:
--
-- >  name <- minput "name" "enter your name"
-- >  surname <- folloup ("ok " <> name <> " send your surname now")  "surname"
-- >  mooutput $ "great " <> name <> " " <> surname <> " thanks!"

followup :: (Loggable a, ToHTTPReq a,ToJSON b,Typeable b) => b -> String  -> Cloud a
followup = flip minput

{-# NOINLINE rpublished#-}
rpublished= lazy $ newIORef (M.empty :: M.Map String [InputData])
-- | makes a `minput`  to be discoverable by  `publish` so that the endpoint may be available for other users.
-- The first parameter is the key where many endpoints may be published. The second parameter is the endpoint (`minput`) itself
publish visible k i= publishn visible [k] i

-- | Like 'publish' but registers the endpoint under multiple keys simultaneously.
publishn :: ShowIt -> [String] -> Cloud a -> Cloud a
publishn visible keys inp= do
  ttr ("publish",keys)
  job  -- to force the execution so that the endpoint is in rpublished 
  Cloud $ sandboxData (ofType :: Publishing) $ do
    setState $ Publishing visible keys
    unCloud inp
  


-- | Send all endpoints registered under @key@ via 'publish' to the connected browser.
-- Call this at the start of a session to surface pending interactions to the user.
published ::  String -> Cloud ()
published k=  local $ do
    log <- getLog
    when (not $ recover log) $ do
      inputdatas <- ( liftIO (readIORef rpublished) >>= return . M.lookup k) `onNothing` return []
      ttr ("PUBLISHED", inputdatas)
      foldr ((<>) . (\(InputData id msg url ) ->  sendOption msg url)) mempty inputdatas
      empty

-- | Retrieve the current 'Endpoints' map from recoverable state, or an empty map.
getEndpoints= getRState <|> return (Endpoints M.empty)

-- | show the URL that may be called to access that functionality within a program 
showURL= getURL >>= liftIO . print

-- | Get the URL string for the current point in the computation
getURL :: TransIO String
getURL = do
  mprev <- tryState
  (SessionId sess, ClosureId clos) <- case mprev of
    Nothing -> return (sessionId0, closureId0)
    Just prev -> liftIO $ do
      mprevClos <- atomically $ readDBRef prev
      case mprevClos of
        Just prevClos -> return (localSession prevClos, localClos prevClos)
        Nothing -> return (sessionId0,closureId0)

  log <- getLog  -- get path
  n <- getMyNode
  let logBytes = toLazyByteString (renderLog $ partLog log)
  return $ concat
    [ "http://"
    , nodeHost n
    , ":"
    , show (nodePort n)
    , "/"
    , BC.unpack clos
    , "/S"
    , show sess
    , "/"
    , BC.unpack (BL.toStrict logBytes)
    ]







-- | menu to show info about the endpoints available
optionEndpoints :: Loggable a => Cloud a
optionEndpoints = do
    ttr ("optionEndpoints")
    onAllDeep $ newRState $ Endpoints M.empty
    local $ do
      option ("endpt" :: String) "info about a endpoint"
      Endpoints endpts <- getEndpoints

      liftIO $ do putStr "endpoints available: "; print $ M.keys endpts
      ident:: BS.ByteString <- input' "" (const True) "enter the endpoint for which you want to know the interface"
      ttr ("endpt ident",ident)
      let murl = M.lookup ident  endpts
      case murl of
        Nothing ->  liftIO $ do putStr  "No such endpoint: " ; print ident
        Just req -> liftIO $ putStrLn "\nYou can invoque this endpoint with:" >> printURL req
      empty
    where
    printURL req= liftIO $ putStrLn $ "\n" <> BS.unpack (("curl " <>
                      (if reqtype req== GET then mempty else ("-H 'content-type: application/json' -XPOST -d " <>
                        "\"" <> encode (reqbody req)) <> "\" ")) <> requrl req)

-- | Flush any pending @Set-Cookie@ headers accumulated via 'setCookie' to the connection.
sendCookies :: Connection -> TransIO ()
sendCookies conn= do
      cookies <- getCookiesStr
      ttr ("COOKIES",cookies)
      when (not $ BS.null cookies) $ msend conn cookies
  where
  getCookies= tryState <|> return (Cookies [])


  getCookiesStr= do
    Cookies cs <- getCookies
    setState $ Cookies []
    return $  BS.concat (map (\(n,v)->  "Set-Cookie: " <> n <>"="<> v <> "\r\n" ) cs)

str = BS.pack

----




data SessionEntry = Entry { entryData :: StablePtr PolyMap, created :: UTCTime } deriving Show

instance Show (StablePtr a) where
  show x= show $ ptrToInt x

--

{-# NOINLINE storeSessionData#-}
storeSessionData = unsafePerformIO  $ newMVar (M.empty :: M.Map BC.ByteString SessionEntry)

ptrToInt :: StablePtr a -> Int
ptrToInt sp = fromIntegral (ptrToIntPtr (castStablePtrToPtr sp))

intToPtr :: Int -> StablePtr a
intToPtr i = castPtrToStablePtr (intPtrToPtr (fromIntegral i))

timeoutOk :: UTCTime -> UTCTime -> Bool
timeoutOk now created = diffUTCTime now created < 3600  -- 1h timeout

-- | Store the current computation state in memory keyed by the browser session ID.
-- Used by 'sendOption' so that clicking a 'published' link restores the correct context.
setSessionData ::  PolyMap -> TransIO ()
setSessionData val = do
  SessionId sessionId <- (tryState >>= return . fst . getSessClosure . prevDBRef) <|> return  sessionId0
  ttr ("setSessionData",sessionId)
  liftIO $ do
    now <- getCurrentTime
    sp <- newStablePtr $ M.delete (typeOf (ofType :: HTTPHeaders)) val
    liftIO $ modifyMVar_ storeSessionData $ \v -> do
      let mreg= M.lookup sessionId v
      v' <- case mreg of
             Just (Entry sp' _)  -> do
              freeStablePtr sp'
              return $ M.delete sessionId v
             Nothing -> return v
      ttr ("sessionId",sessionId)
      return $ M.insert sessionId (Entry sp now)  v'


-- | Retrieve and consume the stored state for the current session (see 'setSessionData').
-- Returns 'Nothing' if no cross-session state exists or it has expired (1-hour timeout).
getSessionData ::  TransIO (Maybe PolyMap)
getSessionData = do
  now <- liftIO $ getCurrentTime
  cleanup  now  -- erase olds
  midxStr <- getCookie "state"
  tr ("midxStr",midxStr)
  case midxStr of
    Nothing -> return Nothing
    Just key -> liftIO $  modifyMVar storeSessionData $ \v -> do
        ttr ("LENGHT V",M.size v,"KEY",key,M.keys v)
        case M.lookup key v of
          Just (Entry sp _) -> do
            ttr ("sp for",key)
            val <- deRefStablePtr sp
            freeStablePtr sp
            return (M.delete key  v, Just val)
          Nothing ->  return (v, Nothing)
  where
  cleanup :: MonadIO m =>  UTCTime -> m ()
  cleanup  now = liftIO $ modifyMVar_ storeSessionData $ return . (M.filter (timeoutOk now . created))

--------------------------------------------------------


-- | Send a single discoverable endpoint option to the browser.
-- Saves the current computation state so it is restored when the link is clicked.
sendOption :: BS.ByteString -> HTTPReq -> TransIO ()
sendOption msg req = do
  -- to make computation state to pass across jumps after the option is clicked
  mfdata <- gets mfData
  setSessionData mfdata

  SessionId key <- (tryState >>= return . fst . getSessClosure . prevDBRef) <|> return  sessionId0

  mfdatakey <- gets mfData

  PrevClos dbr _ _ _ _ :: PrevClos <- getData `onNothing` noExState "sendOption"
  let (SessionId id',_) = getSessClosure dbr
      id= BS.fromStrict id'
  let url'= requrl req 
  sendFragment $ "{ \"msg\":" <>  msg <> ", \"req\":" <> encode (req {requrl = url'}) <> "}"

  where
  long id= do
    s <- tTakeUntilToken "/T"
    ses <-tTakeUntilToken "/"
    tDropUntilToken ("/")
    rest <- giveParseString
    return $ s <> "/T" <> ses <> "/" <>   id <> "/" <> rest

  short id= do
    s <- tTakeUntilToken "/S" -- "/0/0/"
    ses <-tTakeUntilToken "/"
    rest <- giveParseString
    return $ s <> "/T" <> ses <> "/" <>  id <> "/" <> rest



-- | append JSON data to the response.
output :: ToJSON a => a -> TransIO ()
output = sendFragment . encode

-- | It is  used as the last response in a flow.
-- it is used to stream to the client since the response is sent using chunked encoding and
-- until all minputs and moutputs have finised the HTTP response is not closed.
--
-- >   auctionStream prod= do
-- >    stateBid <- getStateAuction prod
-- >    minput "/enterAuction" stateBid   -- the user opt for that product
-- >    (minput "/enterBid" "send a bid" >>= updateState >> empty)  <|> streamBids
-- >  where
-- >    streamBids = do bid <- readEVar bids; moutput bid
-- >    updataState bid= do setStateAuction bid prod; writeEVar bids bid
-- >
--  This produces a bidirectional stream: it can send bids and it receives a stream of bids (with chunked encoding)
--  from all the users
moutput :: ToJSON a => a -> Cloud ()
moutput = local . output

-- | Send a raw JSON fragment over the current chunked HTTP connection.
-- Resolves the live browser connection via 'ensureWebConn' before sending.
sendFragment :: BS.ByteString -> TransIO ()
sendFragment tosend = do
  conn <- tryState
  ttr ("sendFragment conn", idConn conn, "remoteNode", unsafePerformIO $ readIORef $ remoteNode conn)
  let l = fromIntegral $ BS.length tosend
  ttr ("TOSEND",tosend,l)
  conn' <- ensureWebConn conn
  msend conn' $ toHex l <> "\r\n" <> tosend <> "\r\n"



-- | Convert a Haskell type into an 'HTTPReq' description for 'minput'.
-- GET types append a @\/$type@ path segment; POST types ('POSTData') set the request body.
-- The default implementation uses the lowercase type name as the URL variable.
class  Typeable a => ToHTTPReq a where
  toHTTPReq :: a -> TransIO HTTPReq
  toHTTPReq x= do
      v <- varunique $ lowertype x
      ttr ("varunique",v)
      return $ mempty{requrl= "/" <> v}

lowertype x = "$" <> BS.pack (map toLower (typeOfR x))
  where typeOfR x = show $ typeOf x





instance ToHTTPReq () where
  toHTTPReq _ = return $ mempty {requrl = "/u"}

instance {-# OVERLAPPING #-}ToHTTPReq String  where
  toHTTPReq _ = do
    v <- varunique  "$string"
    return $ mempty{requrl= "/" <> v}

instance ToHTTPReq BS.ByteString  where
  toHTTPReq x = do
    v <- varunique  "$string"
    return $ mempty{requrl= "/" <> v}


instance ToHTTPReq Int

instance ToHTTPReq Integer

instance ToHTTPReq a => ToHTTPReq [a] where
  toHTTPReq :: ToHTTPReq a => [a] -> TransIO HTTPReq
  toHTTPReq xs= (return $ mempty {requrl = "["}) <> toHTTPReq ( f xs) <> (return $ mempty {requrl = "]"})
    where
    f :: [a] -> a
    f= undefined


instance (ToHTTPReq a, ToHTTPReq b) => ToHTTPReq (a, b) where
   toHTTPReq x = toHTTPReq (fst x) <> toHTTPReq (snd x)

instance (ToHTTPReq a, ToHTTPReq b,ToHTTPReq c) => ToHTTPReq(a,b,c) where
    toHTTPReq x=  toHTTPReq (fst x) <>   toHTTPReq (snd x)<>  toHTTPReq (trd x)
      where
      fst (x,_,_)= x
      snd (_,x,_)= x
      trd (_,_,x)= x

instance (ToHTTPReq a, ToHTTPReq b,ToHTTPReq c,ToHTTPReq d) => ToHTTPReq(a,b,c,d) where
    toHTTPReq x=  toHTTPReq (fst x) <>   toHTTPReq (snd x)<>  toHTTPReq (trd x) <> toHTTPReq (fr x)
      where
      fst (x,_,_,_)= x
      snd (_,x,_,_)= x
      trd (_,_,x,_)= x
      fr  (_,_,_,x)= x

newtype POSTData a = POSTData a deriving (ToJSON, FromJSON, Typeable, Show, Read)  -- POSTData is recovered from POST HTTP data

instance (Loggable a, ToJSON a, FromJSON a) => Loggable (POSTData a)  where
  serialize (POSTData x)=  serializeToJSON x
  deserialize =   POSTData <$> deserializeJSON


data Vars= Vars[BS.ByteString]
varunique s= do
      Vars vars <- tryState <|> let v= Vars [] in setState v >> return v
      if null $ filter (== s) vars then do setState $ Vars (s:vars); return s
                                    else varunique $ BS.snoc s 'x'

instance  {-# OVERLAPPING #-} (Default a, ToJSON a, Typeable a) => ToHTTPReq (POSTData a) where
  toHTTPReq (POSTData x) =
    do
      setState $ Vars []
      -- pc <- jsonObject $ encode (def `asTypeOf` x)
      -- ttr ("JSONOBJECT TO PARSE",encode (def `asTypeOf` x), pc)
      return $ mempty {reqtype = POST, reqbody =  (toJSON $ def `asTypeOf` x)}
    --  <|> do
    --    t <- jsonType  x
    --    return mempty{reqtype=POST,reqbody= t}

    where


    jsonType x=do
        -- convert the type into a valid JSON string with $type placeholders to insert the parameter values
        let types = show $ typeOf x
        withParseString (BS.pack types) elemType

        where
        elemType =   tuple  <|> list <|> single
        -- si tipo empieza por(
        -- es una tupla, coger el tipo, cambiar ( por [, meter $ delante de los tokens, cambiar [Char] por string

        tuple=   parens $ "[" <> elemType  <> chainMany (<>) (comma <>  elemType) <> "]"
        list=  (sandbox' (string "[Cha") >> single) {- <|> deflist -} <|> (tChar '[' >> ("[" <> elemType <> (tChar ']' >> "]"))) -- (brackets $ tTakeWhile (/= ']')) <> "'s")

        single=   chainManyTill BS.cons (toLower <$> anyChar) (tCharn ',' <|> tCharn ')' <|> done) >>= stringFix

        -- not consuming tChar
        tCharn c= tChar c <* tPutStr (BS.singleton c)
        done= do i <- isDone; guard i; return ' ';

        type1=  tTakeWhile (\c -> c /= ',' && c /= ')') >>= stringFix
        deflist= let r= encode (def `asTypeOf` x) in if r /= "[]" then  escape r else empty
        -- escape the double quotes of the expression
        escape r= withParseString r $ chainMany mappend $ (tChar '\"' >> return "\\\"") <|> (anyChar >>= return . BS.singleton)
        stringFix r
          | BS.null r = return r
          | otherwise = if BS.head r == '[' then    "\\\"$" <> varunique "string" <>"\\\""  else  "$" <> varunique (BS.map toLower r)

    -- use a default value to generate a JSON pattern, with variables $NNN where N is a number, that are
    -- placeholders to insert the actual values, given as paramenters.
    jsonObject json = withParseString json $ do
        sandbox' $ tChar '{'
        BL.concat
          <$> withParseString
            json
            ( many $ do
                prev <- tTakeUntilToken "\""
                var  <- tTakeUntilToken "\""

                tDropUntilToken ":"
                dropSpaces
                isq <- anyChar

                -- chainManyTill BS.cons anyChar (sandbox $ tChar ',' <|> tChar '}')
                tTakeWhile (\c -> c /= ',' && c /= '}')

                sep <- anyChar -- tChar ',' <|> tChar '}'
                var' <- varunique var
                -- let r = prev <> "\\\"" <> var <> "\\\": " <> q isq <> "$" <> var' <> q isq <> BS.singleton sep
                let r = prev <> "\"" <> var <> "\": " <> q isq <> "$" <> var' <> q isq <> BS.singleton sep

                return r
            )
        where
          q is= if is=='\"' then "\\\"" else mempty





-------------------------------  RAW HTTP client ---------------



-- | Execute a raw HTTP request to @node@ using the given path/query string.
-- Handles connection reuse, TLS detection, and chunked response parsing.
-- The result type must be 'Loggable' so it can be checkpointed via 'logged'.
rawHTTP :: (Typeable a, Loggable a) => Node -> String -> TransIO a
rawHTTP node restmsg =res
 where
 res= sandbox $ do
  abduce -- is a parallel operation
  tr ("***********************rawHTTP", nodeHost node,nodePort node, restmsg)
  --sock <- liftIO $ connectTo' 8192 (nodeHost node) (PortNumber $ fromIntegral $ nodePort node)
  mcon <- getData :: TransIO (Maybe Connection)
  c <-
    do
      c <- mconnect' node
      -- tr ("after mconnect'")
      cc <- liftIO $ readIORef $ connData c
      -- tr ("CONDATA",isJust cc)

      sendRawRecover c $ BS.pack restmsg

      c <- tryState <|> error "rawHTTP: no connection?"
      let blocked = isBlocked c -- TODO: the same flag is used now for sending and receiving
      -- tr "before blocked"
      liftIO $ takeMVar blocked
      -- tr "after blocked"
      ctx <- liftIO $ readIORef $ istream c

      liftIO $ writeIORef (done ctx) False
      modify $ \s -> s {parseContext = ctx} -- actualize the parse context
      return c
      `while` \c -> do
        is <- isTLS c
        px <- getHTTProxyParams is
        -- tr ("PX=", px)
        (if isJust px then return True else do c <- anyChar; tPutStr $ BS.singleton c;  return True) <|> do
          TOD t _ <- liftIO $ getClockTime
          -- ("PUTMVAR",nodeHost node)
          liftIO $ putMVar (isBlocked c) $ Just t
          liftIO (writeIORef (connData c) Nothing)
          mclose c
          tr "CONNECTION EXHAUSTED,RETRYING WITH A NEW CONNECTION"
          return False

  modify $ \s -> s {execMode = Serial}
  let blocked = isBlocked c -- TODO: the same flag is used now for sending and receiving
  -- tr "after send"

  first@(vers, code, _) <-
    getFirstLineResp <|> do
      r <- notParsed
      endthings c mcon http10 blocked []
      error $ "No HTTP header received:\n" ++ up r
  -- tr ("FIRST line", first)
  headers <- getHeaders
  let hdrs = HTTPHeaders first headers
  setState hdrs

  -- tr ("HEADERS", first, headers)

  guard (BC.head code == '2')
    <|> do
      Raw body <- parseBody  headers
      endthings c mcon vers blocked headers
      error $ "Transient.Move.Web: ERROR in REQUEST: \n" <> restmsg  <> show body <> "\nRESPONSE HEADERS:\n " <> show hdrs
  tr ("HEADERS",headers)

  result <- parseBody headers
  -- let mresult = decode r 
  --     result= fromMaybe (error $ "can not decode JSON string:" <> show(BS.unpack r) <> " to type: " <> show(typeOf (type1 res))) mresult

  tr ("RESULT BODY",result)
  endthings c mcon vers blocked headers
  return result
  where
  type1 :: TransIO a -> a
  type1= error "type level"
  endthings c mcon vers blocked headers= do
    -- modify $ \s -> s{parseContext=ParseContext (return SDone) mempty (unsafePerformIO $ newIORef True)}

    when
      ( vers == http10
          ||
          lookup "Connection" headers == Just "close"
      )
      $ do
        TOD t _ <- liftIO $ getClockTime

        liftIO $ putMVar blocked $ Just t
        liftIO $ mclose c
        liftIO $ takeMVar blocked
        return ()

    --tr ("result", result)

    --when (not $ null rest)  $ error "THERE WERE SOME REST"
    ctx <- gets parseContext
    -- "SET PARSECONTEXT PREVIOUS"
    liftIO $ writeIORef (istream c) ctx

    TOD t _ <- liftIO $ getClockTime
    -- ("PUTMVAR",nodeHost node)
    liftIO $ putMVar blocked $ Just t

    if isJust mcon then setData (fromJust mcon) else delData c

  isTLS c = liftIO $ do
      cdata <- readIORef $ connData c
      case cdata of
        Just (TLSNode2Node _) -> return True
        _ -> return False

  while act fix = do r <- act; b <- fix r; if b then return r else act



#endif