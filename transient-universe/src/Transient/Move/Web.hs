{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
-- {-# LANGUAGE OverlappingInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE InstanceSigs #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}
{-# HLINT ignore "Use typeRep" #-}

-- All of this for the glory of God and His mother Mary

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
minput
  :: (ToJSON p, Loggable a, ToHTTPReq a, Typeable p) =>
     String -> p -> Cloud a

minput (ident :: String) msg' = onAll $ sandboxData (ofType :: ClosToRespond) $ unCloud response
  where
    msg= encode msg'
    response = do
      ttr "MINPUT"
      delState (ofType :: ClosToRespond)
      modify $ \s -> s {execMode = if execMode s == Remote then Remote else Parallel}
      local $ do
        log <- getLog
        conn <- getState -- if connection not available, execute alternative computation
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
            msgdat
              | typeOf msg' == typeOf (ofType :: String) = BS.pack  $ unsafeCoerce  msg'
              | typeOf msg' == typeOf (ofType :: BS.ByteString) = unsafeCoerce msg'
              | otherwise = msg
        setState $ InputData ident msgdat httpreqsess
        first <- liftIO $ atomicModifyIORef firstEndpointName $ \x -> if null x then (ident, True) else (x, False)
        when first $ liftIO $ print urlbase

        connected log  idSession conn closLocal  httpreq -- <|> commandLine conn log httpreq


    connected log  idSession conn closLocal  httpreq = do

      cdata <- liftIO $ readIORef $ connData conn

      -- onException $ \( e :: SomeException) -> do -- 
      --                   let tosend = {- header404Chunked <> -} str "{\"error\"," <> str (show $ show e) <> str "}"
      --                   output tosend
      --                   msend conn $ str "1\r\n]\r\n0\r\n\r\n"
      --                   let l= fromIntegral $ BS.length tosend
      --                   msend conn $ toHex l <> str "\r\n" <> tosend <> "\r\n0\r\n\r\n"
      --                   empty

      -- onException $ \(e :: SomeException) -> do liftIO $ print "THROWT"; throwt e; empty

      -- liftIO $ atomically $ writeDBRef (getDBRef $ show idSession) ctx -- store the state, the id will be in the URL
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
                readResponse
              _ -> do
                checkComposeJSON conn

                let tosend = str "{ \"msg\":" <>  msg <> str ", \"req\":" <> encode httpreq <> str "}"
                let l = fromIntegral $ BS.length tosend
                -- for HTTP 1.0 no chunked encoding:
                -- msend conn $ str "HTTP/1.0 200 OK\r\nContent-Length: " <> str(show l) <> str "\r\n\r\n" <> tosend
                -- mclose conn
                msend conn $ toHex l <> str "\r\n" <> tosend <> "\r\n" -- <>  "\r\n0\r\n\r\n"
                tr "after msend"
                endpointEtc
                readResponse

          else do
            -- the program has just restarted and recovered and this endpoint is active waiting for requests.
            -- Perhaps a request waked up that endpoint

            endpointEtc
            -- logged will deserialize the request parameters
            readResponse

            
      tr ("MINPUT RESULT",result)
      delRState InitSendSequence
      delState IsCommand
      return result `asTypeOf` return (type1 response)

      where

      readResponse= logged $ error "minput: insuficient parameters" -- only read from the log. if the log is consumed before generating a valid response, raises the error
    
      endpointEtc= do
        


        endpoint (Just $ BC.pack ident)

        mmfdata <- getSessionData
      
        when (isJust mmfdata) $ do
          tr ("mmfdata",mmfdata)
          let mfdata= fromJust mmfdata

          -- merge the state of the computation that created the encpoint with the state of the coming computation
          modify $ \s-> s{mfData= merge mfdata $ mfData s}
            -- endpoint (Just $ BC.pack ident) <|> return()

      merge = M.unionWithKey combine
      combine t x y=  if t == typeOf (ofType :: Connection) 
                           || t == typeOf(ofType :: PrevClos) 
                           || t == typeOf(ofType :: Log) then y else x

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
publish k i= publishn [k] i

publishn ::  [String] -> Cloud a -> Cloud a
publishn keys inp= inp  <|> onAllNodes (do
  ttr ("PUBLISH",keys)
  idata :: InputData  <-  getState  <|> error "publish: no inputdata"
  mapM_ (add idata) keys
  ttr ("publish",idata,keys)
  empty)
  where
  add idata k= liftIO $ do
    atomicModifyIORef rpublished $ \map -> 
        ( let idatas= fromMaybe [idata] (M.lookup k map) in M.insert k idatas map,())
    -- inputdatas <- ( liftIO (readIORef rpublished) >>= return . M.lookup k) `onNothing` return []
    -- ttr ("PUBLISHED",inputdatas)



published ::  String -> TransIO ()
published k=  do
    inputdatas <- ( liftIO (readIORef rpublished) >>= return . M.lookup k) `onNothing` return []
    ttr ("PUBLISHED", inputdatas)
    foldr ((<>) . (\(InputData id msg url ) ->  sendOption msg url)) mempty inputdatas

-- | set a pending endpoint for a key. if the endpoint is executed, it dissapears from the list for this key. 
-- For example an userid or a wallet may be the key. 
--
-- An use case:  in the middle of a some smart contract or in 
-- general, in any workflow the user/wallet does not complete the transaction but the endpoint is marked as pending . 
-- When the user return to the application, 'published key' has this endpoint and may be made visible in the first interaction of this
-- new session. 
-- pending key inp= do
--   idata <- local getState
--   r <- publish key inp
--   local $ liftIO $ withResource(InputDatas key undefined) $ \case 
--               Nothing                  -> InputDatas key []
--               Just(InputDatas k lcks) -> InputDatas k $ delete  idata lcks
--   return r



-- | send to the cllient all the endpoints published by `publish` with the given key
-- published1 :: Loggable a => String -> TransIO a
-- published1 k=  do
--     InputDatas _ inputdatas <- getIndexRData k `onNothing` return (InputDatas k [])--  liftIO $ getResource (InputDatas k undefined)  `onNothing` return (InputDatas k []) -- getRState
--     tr ("PUBLISHED", inputdatas)

--     mcommand <- getData :: TransIO (Maybe IsCommand)
--     if isNothing mcommand
--       then do foldr ((<|>) . (\(InputData id msg url) ->  sendOption msg url)) empty inputdatas; empty
--       else do foldr ((<|>) . (\(InputData id msg url) ->  optionl id  (BS.unpack msg <> "\t\"endpt " <> id <> "\" for endpoint details")  url)) empty inputdatas
--     empty
--     where
--     -- for console interaction
--     optionl id msg url = do
--       Endpoints endpts <- getEndpoints
--       setRState $ Endpoints $ M.insert (str id) url endpts -- ((str id, url): endpts)

--       option id msg
--       pars' <- input (const True) "enter the parameters > "
--       tr ("PARS'",pars')
--       -- substitute spaces by '/'
--       pars <- withParseString (BS.pack pars') $ chainMany mappend (tTakeWhile' (/= ' ') <> ((tChar ' ' >>tTakeWhile' (==' ') >> "/") <|> mempty))
--       tr ("PARS",pars)
--       let p = requrl url
--       (cl,s,cl',s',ids) <- withParseString p $  do
--            string "http://" ; tTakeWhile' (/='/')
--           --  (,,,,) <$> deserialize <*> deserialize <*> deserialize <*> deserialize <*> deserialize 
--            (,,,,) <$> tTakeWhile' (/='/') <*> tTakeWhile' (/='/')  <*> tTakeWhile' (/='/') <*> tTakeWhile' (/='/') <*> tTakeWhile' (/='/')
--       tr ("CL S",cl,s,cl',s',ids)
--       Transient $ processMessage (SessionId $ BS.toStrict s) 
--                                  (ClosureId $ BS.toStrict cl)  
--                                  (SessionId $ BS.toStrict s') 
--                                  (ClosureId $ BS.toStrict cl') 
--                                  (Right $ [[lazyByteString $ ids <> "/" <> pars]]) False
--       return ()




getEndpoints= getRState <|> return (Endpoints M.empty) -- |error "NO ENDPOINT state: use optionEndpoints" -- return (Endpoints M.empty)

-- | show the URL that may be called to access that functionality within a program 
showURL= getURL >>= liftIO . print

-- | Get the URL string for the current point in the computation
getURL :: TransIO String
getURL = do
  mprev <- getState
  (SessionId sess, ClosureId clos) <- case mprev of
    Nothing -> return (sessionId0, closureId0)
    Just prev -> liftIO $ do
      mprevClos <- atomically $ readDBRef prev
      case mprevClos of
        Just prevClos -> return (localSession prevClos, localClos prevClos)
        Nothing -> return (sessionId0,closureId0)

  log <- getLog  -- get path
  n <- getMyNode
  let logBytes = toLazyByteString (partLog log)
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

 -- | extract the URL of a data object within the computation.
 -- if the log has been saved and the computation completed, the computation will be restored to give his value
-- cloudRef x= do
--   prevsession <- local getSession
--   r <- onAll getURL
--   local $ return x
--   session <- local getSession
--   guard $ session== prevsession
--   return r







-- | menu to show info about the endpoints available
optionEndpoints :: Loggable a => Cloud a
optionEndpoints = do
  -- Endpoints endpts <- getEndpoints
  -- guard(not $ null endpts)
    ttr ("optionEndpoints")
    onAllNodes $ newRState $ Endpoints M.empty
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

-- | add the chunked fragments of the beguinning '[', the comma separator and the end ']' of the JSON packet for a set of `minput` statements
-- that are sent in parallel (for example, with the alterenative operator)
checkComposeJSON :: Connection -> TransIO ()
checkComposeJSON conn = do
  ms <- getRData -- avoid more than one onWaitthread, add "{" at the beguinning of the response
  -- and send the final chunk when no thread is active.
  case ms of
    Nothing -> do
      onWaitThreads $ const $ msend conn $ str "1\r\n]\r\n0\r\n\r\n"
      setRState InitSendSequence

      sendCookies conn
      msend conn  {- header200Chunked <> -} "\r\n1\r\n[\r\n"
      delState $ Cookies []

    Just InitSendSequence -> msend conn $ str "2\r\n\n,\r\n"
  -- to protect the state  upto now  if an exception arrives in order to incorporate exception data to the JSON message sent
  where
  sendCookies :: Connection -> TransIO ()
  sendCookies conn= do
      cookies <- getCookiesStr
      ttr ("COOKIES",cookies)
      when (not $ BS.null cookies) $ msend conn cookies

  getCookies= getState <|> return (Cookies [])


  getCookiesStr= do
    Cookies cs <- getCookies
    setState $ Cookies []
    return $  BS.concat (map (\(n,v)->  "Set-Cookie: " <> n <>"="<> v <> "\r\n" ) cs)

str = BS.pack

----




-- -- | set a cookie in the browser.
-- -- Example

-- -- > setCookie "<cookie-name>" "<cookie-value>; Domain=<domain-value>; Secure; HttpOnly"
-- -- 
-- -- See https://developer.mozilla.org/es/docs/Web/HTTP/Headers/Set-Cookie for cookie options
-- setCookie :: BS.ByteString -> BS.ByteString -> TransIO ()
-- setCookie name valueandparams= do
--   Cookies cs <- getCookies
--   setState $ Cookies $ (name,valueandparams):cs
--   where
--   getCookies :: TransIO Cookies
--   getCookies= getState <|> return (Cookies [])


-- getCookie :: BS.ByteString -> TransIO (Maybe BC.ByteString)
-- getCookie name= do
--   HTTPHeaders _ headers :: HTTPHeaders <- getState <|>  return (HTTPHeaders undefined [])
--   ttr ("getCookie HTTP HEADERS",headers)
--   let receivedCookie= lookup "Cookie" headers

--   liftIO $ print ("cookie", receivedCookie)
--   case receivedCookie of
--     Just str->  (withParseString (BS.fromStrict str) search) <|> return Nothing
--     Nothing -> return Nothing
--     where
--     search= do
--        tr "search cookie"
--        d <- isDone
--        if d then return Nothing else do
--                 dropSpaces
--                 name' <- tTakeWhile' (/='=')
--                 val <- tTakeWhile' (/=';')
--                 liftIO $ print (name',val)
--                 if name'== name then return $ Just $ BS.toStrict val else search

--  cookies for pointers to state data with timeouts. Used to persist the state of the current computation
-- when jump to  publish/published endpoints using HTTP(s). Mainly the state variables

{-
sessionid  stableptr  
  
-}
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

setSessionData ::  PolyMap -> TransIO ()
setSessionData val = do
  SessionId sessionId <- (getState >>= return . fst . getSessClosure . prevDBRef) <|> return  sessionId0
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


sendOption :: BS.ByteString -> HTTPReq -> TransIO ()
sendOption msg req = do
  -- to make computation state to pass across jumps after the option is clicked
  mfdata <- gets mfData
  setSessionData mfdata

  SessionId key <- (getState >>= return . fst . getSessClosure . prevDBRef) <|> return  sessionId0

  mfdatakey <- gets mfData

  PrevClos dbr _ _ _ _ :: PrevClos <- getData `onNothing` noExState "sendOption"
  let (SessionId id',_) = getSessClosure dbr
      id= BS.fromStrict id'
  let url'= requrl req 
  sendFragment $ "{ \"msg\":\"" <>  msg <> "\", \"req\":" <> encode (req {requrl = url'}) <> "}"

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

--  | Send a JSON fragment
sendFragment :: BS.ByteString -> TransIO ()
sendFragment tosend = do
  let l = fromIntegral $ BS.length tosend
  tr ("SENDFRAGMENT000",tosend)
  conn <- getState
  -- let tosend = tostr "{ \"msg\":" <>  toSend <> str "}"
  let l = fromIntegral $ BS.length tosend
  ttr ("TOSEND",tosend,l)

                -- for HTTP 1.0 no chunked encoding:
                -- msend conn $ str "HTTP/1.0 200 OK\r\nContent-Length: " <> str(show l) <> str "\r\n\r\n" <> tosend
                -- mclose conn


  checkComposeJSON conn
  msend conn $ toHex l <> "\r\n" <> tosend <> "\r\n"



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


-- instance  {-# OVERLAPPING #-} 
--           (Default a, ToJSON a, Typeable a
--           ,Default b, ToJSON b, Typeable b) => ToHTTPReq (POSTData(a,b)) where
--     toHTTPReq (POSTData x)=  addbody "["   <> toHTTPReq (POSTData (fst x)) <>
--                               addbody ", " <> toHTTPReq (POSTData (snd x)) <>
--                               addbody "]"
--       where
--       addbody s= return mempty{reqbody=s}

-- instance  (Default a, ToJSON a, Typeable a
--           ,Default b, ToJSON b, Typeable b
--           ,Default c, ToJSON c, Typeable c) => ToHTTPReq (POSTData(a,b,c)) where
--     toHTTPReq (POSTData x)=  addbody "["   <> toHTTPReq (POSTData (fst x)) <>
--                               addbody ", " <> toHTTPReq (POSTData (snd x)) <>
--                               addbody ", " <> toHTTPReq (POSTData (trd x)) <>
--                               addbody "]"
--       where
--       fst (x,_,_)= x
--       snd (_,x,_)= x
--       trd (_,_,x)= x
--       addbody s= return mempty{reqbody=s}

-- instance  (Default a, ToJSON a, Typeable a
--           ,Default b, ToJSON b, Typeable b
--           ,Default c, ToJSON c, Typeable c
--           ,Default d, ToJSON d, Typeable d) => ToHTTPReq (POSTData(a,b,c,d)) where
--     toHTTPReq (POSTData x)=  addbody "["   <> toHTTPReq (POSTData (fst x)) <>
--                               addbody ", " <> toHTTPReq (POSTData (snd x)) <>
--                               addbody ", " <> toHTTPReq (POSTData (trd x)) <>
--                               addbody ", " <> toHTTPReq (POSTData (frt x)) <>
--                               addbody "]"
--       where
--       fst (x,_,_,_)= x
--       snd (_,x,_,_)= x
--       trd (_,_,x,_)= x
--       frt (_,_,_,x)= x
--       addbody s= return mempty{reqbody=s}

instance (ToHTTPReq a, ToHTTPReq b) => ToHTTPReq (a, b) where
   toHTTPReq x = toHTTPReq (fst x) <> toHTTPReq (snd x)

instance (ToHTTPReq a, ToHTTPReq b,ToHTTPReq c) => ToHTTPReq(a,b,c) where
    toHTTPReq x=  toHTTPReq (fst x) <>   toHTTPReq (snd x)<>  toHTTPReq (trd x)
      where
      fst (x,_,_)= x
      snd (_,x,_)= x
      trd (_,_,x)= x

instance (ToHTTPReq a, ToHTTPReq b,ToHTTPReq c,ToHTTPReq d) => ToHTTPReq(a,b,c,d) where
    -- toHTTPReq (a,b,c,d)= toHTTPReq a <>  toHTTPReq b <>  toHTTPReq c <> toHTTPReq  d
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


-- instance ToHTTPReq (POSTData String) where
--   toHTTPReq (POSTData s) = return mempty {reqbody = "$string"}

-- instance ToHTTPReq (POSTData BS.ByteString) where
--   toHTTPReq (POSTData s) = return mempty {reqbody = "$string"}

-- instance ToHTTPReq (POSTData Int) where
--   toHTTPReq x = return mempty {reqbody = lowertype x}

-- instance ToHTTPReq (POSTData Integer) where
--   toHTTPReq x = return mempty {reqbody = lowertype x}


data Vars= Vars[BS.ByteString]
varunique s= do
      Vars vars <- getState <|> let v= Vars [] in setState v >> return v
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

      c <- getState <|> error "rawHTTP: no connection?"
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