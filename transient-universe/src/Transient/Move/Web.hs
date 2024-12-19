{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverlappingInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE CPP, LambdaCase #-}

-- All of this for the glory of God and His mother Mary

#ifndef ghcjs_HOST_OS

module Transient.Move.Web  (minput,moutput,public,published,showURL,ToHTTPReq(..),POSTData(..),HTTPReq(..),
AsJSON(..),getSessionState,setSessionState,newSessionState,rawHTTP,serializeToJSON,deserializeJSON,
 IsCommand,optionEndpoints,getCookie,setCookie) where

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
import System.Random
import System.Time
import Transient.Console
import Transient.Internals
import Transient.Move.Logged
import Transient.Loggable(Raw(..))
import Transient.Move.Defs
import Transient.Move.Internals
import Transient.Parse
import Transient.Move.JSON
import Unsafe.Coerce
import Data.List

import Control.Exception hiding(try,onException)

data InitSendSequence = InitSendSequence

data IsCommand = IsCommand deriving (Show)

data InputData = InputData {idInput :: String, message :: BS.ByteString, hTTPReq :: HTTPReq} deriving (Show, Read, Typeable)
data InputDatas= InputDatas String [InputData]deriving (Show, Read, Typeable)
instance TC.Indexable InputDatas where key (InputDatas key _)= key

instance Loggable InputData

data Context = Context Int (M.Map String BS.ByteString) deriving (Read, Show, Typeable)


instance TC.Indexable Context where key (Context k _) = show k

-- newtype URL= URL BS.ByteString  deriving (Read, Show, Typeable) -- for endpoint urls
data HTTPReq = HTTPReq
  { reqtype :: HTTPMethod,
    requrl :: BS.ByteString,
    reqheaders :: BS.ByteString,
    reqbody :: BS.ByteString
  }
  deriving (Read, Show, Typeable, Generic)

instance ToJSON BL.ByteString where
  toJSON = toJSON . BS.unpack


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

-- Multiple input. It accept a console option as well as  a GET or POST web request at the point where it 
-- is inserted
--
-- minput is fully composable
--
-- It is the main way for interacting with users and programs which do not share the same base code.
-- Otherwise a transient program distributed among different nodes, including web nodes, would use `runAt` and other
-- distributed primitives
minput :: (Loggable a, ToHTTPReq a,ToJSON b,Typeable b) => String -> b -> Cloud a
minput ident msg' = response
  where
    msg= encode msg'
    response = do
      -- idSession <- local $ fromIntegral <$> genPersistId
      modify $ \s -> s {execMode = if execMode s == Remote then Remote else Parallel}
      local $ do
        log <- getLog
        conn <- getState -- if connection not available, execute alternative computation
        let closLocal = hashClosure log
        -- closdata@(Closure sess closRemote _) <- getIndexData (idConn conn) `onNothing` return (Closure 0 "0" [])
        mynode <- getMyNode
        ctx@(Context idcontext _) <-  do
          mc <- getData
          case mc of
            Nothing -> return $ Context 0 (M.empty)
            Just (Context 0 x) ->  do
              ctx <- Context <$>  (unCloud $ logged genSessionId) <*> return x
              tr ("CONTEXR from 0",ctx)
              setState ctx
              return ctx
            Just ct -> return ct


        let idSession = idcontext
        let urlbase =
              str "http://" <> str (nodeHost mynode) <> str ":" <> intt (nodePort mynode)
                </> str ident
                </> "S" <> intt idSession
                -- </> BL.fromStrict closRemote
                -- </> intt sess
                -- </> intt idcontext ::
                -- BS.ByteString

        params <- toHTTPReq $ type1 response

        let httpreq = mempty {requrl = urlbase} <> params :: HTTPReq
            msgdat = if typeOf msg' == typeOf (undefined :: String) then  BS.pack  $ unsafeCoerce  msg'
                     else if typeOf msg' == typeOf (undefined :: BS.ByteString) then unsafeCoerce msg'
                     else msg
        setState $ InputData ident msgdat httpreq

        connected log ctx idSession conn closLocal  httpreq <|> commandLine conn log httpreq

    commandLine conn log httpreq = do
      guard (not $ recover log)
      cdata <- liftIO $ readIORef $ connData conn
      mcommand <- getData :: TransIO (Maybe IsCommand)
      -- do not continue if not is in command mode or there is no connection
      guard (isJust mcommand || case cdata of Just Self -> True; _ -> False)


      if null ident
        -- if no ident it is just a message with no further option
        then do liftIO $ putStrLn $ BS.unpack msg; empty
        else do
          Context n st <-
            getState <|> do
              let ctx = Context 0 M.empty
              setState ctx
              return ctx

          let ref = getDBRef $ show n
          liftIO $ atomically $ writeDBRef ref $ Context n st

          execmode <- gets execMode
          tr ("LOG",execmode)
          option ident $ BS.unpack msg <> "\nEnter\t\x1b[1;31m" ++ "endpt "<> ident <> "\x1b[0m" <> "\tfor this endpoint details"
          setState IsCommand

          ctx@(Context idc _) <- liftIO $ atomically $ readDBRef ref `onNothing` error "minput: no context"
          setState ctx

          r <-
            if typeOf response /= typeOf (undefined :: Cloud ())
              then do
                inputParse deserialize $ BS.unpack msg

              else return $ unsafeCoerce ()
          (_,r') <- unCloud $ logged $ return (idc,r)
          return r'

    connected log ctx@(Context idcontext _) idSession conn closLocal  httpreq = do
      cdata <- liftIO $ readIORef $ connData conn

      onException $ \( e :: SomeException) -> do -- 
                  cdata <- liftIO $ readIORef $ connData conn
                  case cdata of
                   Just Self -> return ()
                   Just _ -> do
                        tr cdata
                        let tosend = str "{\"error\"," <> str (show $ show e) <> str "}"
                        sendFragment tosend
                        -- msend conn $ str "1\r\n]\r\n0\r\n\r\n"
                        --     l= fromIntegral $ BS.length tosend
                        -- msend conn $ toHex l <> str "\r\n" <> tosend <> "\r\n0\r\n\r\n"
                        empty

      -- onException $ \(e :: SomeException) -> do liftIO $ print "THROWT"; throwt e; empty

      liftIO $ atomically $ writeDBRef (getDBRef $ show idcontext) ctx -- store the state, the id will be in the URL
      Endpoints endpts <- getEndpoints
      setRState $ Endpoints  $ M.insert (str ident) httpreq endpts
      tr ("ADDED ENDPOINT",ident,httpreq)
      (idcontext' :: Int, result) <- do
        pstring <- giveParseString
        if not (recover log) || BS.null pstring
          then do
            tr "EN NOTRECOVER"

            -- ty <- liftIO $ readIORef $ connData conn
            case cdata of
              Just Self -> do
                receive conn (Just $ BC.pack ident) idSession
                delState IsCommand
                tr "SELF XXX"

                ps <- giveParseString
                -- log <- getLog

                -- tr ("PARSE BEFORE LOGGED EN MINPUT",ps, recover log)

                -- setData log{recover=True}
                (string "e/" >> string "e/") <|> return "e/"
                unCloud $ logged $  liftIO $ do error "insuficient parameters 1"; empty -- read the response

              _ -> do
                checkComposeJSON conn


                -- insertar typeof response
                let tosend = str "{ \"msg\":" <>  msg <> str ", \"req\":" <> encode httpreq <> str "}"
                let l = fromIntegral $ BS.length tosend

                -- for HTTP 1.0 no chunked encoding:
                -- msend conn $ str "HTTP/1.0 200 OK\r\nContent-Length: " <> str(show l) <> str "\r\n\r\n" <> tosend
                -- mclose conn
                msend conn $ toHex l <> str "\r\n" <> tosend <> "\r\n" -- <>  "\r\n0\r\n\r\n"
                tr "after msend"
                -- store the msg and the url and the alias
                -- se puede simular solo con los datos actuales

                receive conn (Just $ BC.pack ident) idSession
                tr "after receive"
                delState IsCommand
                delRState InitSendSequence
                unCloud $ logged $ error "not enough parameters 2" -- read the response, error if response not logged
          else do
            receive conn (Just $ BC.pack ident) idSession
            delState IsCommand
            tr ("else",ident)
            unCloud $ logged $ error "insuficient parameters 3" -- read the response
            -- maybe another user from other context continues the program
      tr ("MINPUT RESULT",idcontext',result)
      mncontext <- recoverContext idcontext'
      when (isJust mncontext) $ setState (fromJust mncontext :: Context)
      return result `asTypeOf` return (type1 response)
      where
        recoverContext idcontext' = liftIO $
          atomically $ do
            let con = getDBRef $ show idcontext' :: DBRef Context
            mr <- readDBRef con
            case mr of
              Nothing -> return Nothing
              Just (c@(Context n _)) ->
                if n == -1
                  then return Nothing
                  else do
                    -- delDBRef con
                    return $ Just c


    (</>) x y = x <> str "/" <> y
    str = BS.pack
    intt = str . show
    type1 :: Typeable a => Cloud a -> a
    type1 cx = r
      where
        r = error $ show $ typeOf r




-- endpoints = unsafePerformIO $ newIORef M.empty


-- | makes a `minput` available for  `published`. His endpoint will be available for all the users
public key inp= inp  <|> add key
  where
  add  :: Loggable a => String ->  Cloud a
  add k= local $ do
        idata :: InputData  <-  getState
        tr idata
        liftIO $ withResource (InputDatas k undefined) $ \case
                    Nothing                  -> InputDatas k [idata]
                    Just(InputDatas k lcks) -> InputDatas k $ idata:lcks


        empty

-- | set a pending endpoint for a key.if the endpoint is executed, it dissapears from the list for this key. 
-- For example an userid or a wallet may be the key. An use case:  in te middle of a some smart contract or in 
-- general, in any workflow the user/wallet does not complete the transaction but the endpoint is marked as pending . 
-- When he return to the application, 'published key' has this endpoint and may be made visible in the first interaction of this
-- new session. 
-- pending key inp= do
--   idata <- local getState
--   r <- public key inp
--   local $ liftIO $ withResource(InputDatas key undefined) $ \case 
--               Nothing                  -> InputDatas key []
--               Just(InputDatas k lcks) -> InputDatas k $ delete  idata lcks
--   return r



-- | send to the cllient all the endpoints published by `public` with the given key
published k=  local $ do
    InputDatas _ inputdatas <-  liftIO $ getResource (InputDatas k undefined)  `onNothing` return (InputDatas k []) -- getRState
    tr ("PUBLISHED", inputdatas)

    mcommand <- getData :: TransIO (Maybe IsCommand)
    if isNothing mcommand
      then do foldr ((<|>) . (\(InputData id msg url) ->  sendOption msg url)) empty inputdatas; empty
      else do foldr ((<|>) . (\(InputData id msg url) ->  optionl id  (BS.unpack msg <> "\t\"endpt " <> id <> "\" for endpoint details")  url)) empty inputdatas
    empty
    where
    -- for console interaction
    optionl id msg url = do
      Endpoints endpts <- getEndpoints
      setRState $ Endpoints $ M.insert (str id) url endpts -- ((str id, url): endpts)

      option id msg
      pars' <- input (const True) "enter the parameters > "
      tr ("PARS'",pars')
      -- substitute spaces by '/'
      pars <- withParseString (BS.pack pars') $ chainMany mappend (tTakeWhile' (/= ' ') <> ((tChar ' ' >>tTakeWhile' (==' ') >> "/") <|> mempty))
      tr ("PARS",pars)
      let p = requrl url
      (cl,s,cl',s',ids) <- withParseString p $  do
           string "http://" ; tTakeWhile' (/='/')
           (,,,,) <$> tTakeWhile' (/='/') <*> tTakeWhile' (/='/')  <*> tTakeWhile' (/='/') <*> tTakeWhile' (/='/') <*> tTakeWhile' (/='/')
      tr ("CL S",cl,s,cl',s',ids)
      Transient $ processMessage (read $ BS.unpack s) (BS.toStrict cl)  (read $ BS.unpack s') (BS.toStrict cl') (Right $ lazyByteString $ ids <> "/" <> pars) False
      return ()

newtype Endpoints= Endpoints (M.Map BS.ByteString HTTPReq)
getEndpoints= getRState <|> error "NO ENDPOINT state: use optionEndpoints" -- return (Endpoints M.empty)

-- | show the URL that may be called to access that functionality within a program 
showURL= do
       mprev <- getState
       (sess,clos) <- case mprev of
                         Nothing -> return (0,"0")
                         Just prev -> liftIO $ do
                           mprevClos <- atomically $ readDBRef prev
                           case mprevClos of
                            Just prevClos -> return $ (localSession prevClos,localClos prevClos)
                            Nothing -> return (0,"0")

       log <- getLog --get path 
       n <- getMyNode
       liftIO $ do
           putStr  "'http://"
           putStr $ nodeHost n
           putStr ":"
           putStr $show $ nodePort n
           putStr "/"
           putStr $ show clos
           putStr "/S"
           putStr $ show sess
           putStr "/"
           BS.putStr $  toLazyByteString $ partLog log
           putStrLn "'"

{-
give URL for a new session or the current session?
  new ever? current session are not given by the console
-}
-- | menu to show info about the endpoints available
optionEndpoints :: TransIO b
optionEndpoints = do
  -- Endpoints endpts <- getEndpoints
  -- guard(not $ null endpts)
  newRState $ Endpoints M.empty
  option ("endpt" :: String) "info about a endpoint"
  Endpoints endpts <- getEndpoints
  liftIO $ do putStr "endpoints available: "; print $ M.keys endpts
  ident:: BS.ByteString <- input (const True) "enter the endpoint for which you want to know the interface"

  let murl = M.lookup ident  endpts
  case murl of
    Nothing ->  liftIO $ do putStr $ "No such endpoint: " ; print ident
    Just req -> printURL req
  empty
  where
  printURL req= liftIO $ putStrLn $ "\n" <> (BS.unpack $ ("curl " <>
                    (if reqtype req== GET then mempty else ("-H 'content-type: application/json' -XPOST -d " <>
                       "\"" <> reqbody req) <> "\" ")) <> requrl req )

-- | add the chunked fragments of the beguinning '[', the comma separator and the end ']' of the JSON packet for a set of `minput` statements
-- that are sent in parallel (for example, with the alterenative operator)
checkComposeJSON conn = do
  ms <- getRData -- avoid more than one onWaitthread, add "{" at the beguinning of the response
  -- and send the final chunk when no thread is active.
  case ms of
    Nothing -> do
      onWaitThreads $ const $ msend conn $ str "1\r\n]\r\n0\r\n\r\n"
      setRState InitSendSequence

      -- onException $ \(e :: SomeException) -> do liftIO $ print "THROWT"; throwt e

      sendCookies conn
      tr "MSEND ["
      msend conn "\r\n1\r\n[\r\n"
      delState $ Cookies []

    Just InitSendSequence -> msend conn $ str "2\r\n\n,\r\n"
  -- to protect the state  upto now  if an exception arrives in order to incorporate exception data to the JSON message sent

str = BS.pack

----

newtype Cookies= Cookies  [(BS.ByteString,BS.ByteString)]

getCookies= getState <|> return (Cookies [])

sendCookies conn= do
      cookies <- getCookiesStr
      when (not $ BS.null cookies) $ msend conn cookies

  where
  getCookiesStr= do
    Cookies cs <- getCookies
    setState $ Cookies []
    return $  BS.concat (map (\(n,v)->  "Set-Cookie: " <> n <>"="<> v <> "\r\n" ) cs)

-- | set a cookie in the browser.
-- Example

-- > setCookie "<cookie-name>" "<cookie-value>; Domain=<domain-value>; Secure; HttpOnly"
-- 
-- See https://developer.mozilla.org/es/docs/Web/HTTP/Headers/Set-Cookie for cookie options
setCookie name valueandparams= do
  Cookies cs <- getCookies
  setState $ Cookies $ (name,valueandparams):cs

getCookie name= do
  HTTPHeaders _ headers :: HTTPHeaders <- getState <|>  return (HTTPHeaders undefined [])
  liftIO $ print headers
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
                if name'== name then return $ Just val else search
{-
cookies  sesion de programaa - sesion remota
-}
sendOption msg req = do
  Context id _ <- getState <|> error "sendOption:no minput context, use `minput`"
  url' <- withParseString (requrl req) $ short id <|> long id
  sendFragment $ "{ \"msg\":\"" <>  msg <> "\", \"req\":" <> encode (req {requrl = url'}) <> "}"

  where
  long id= do
    s <- tTakeUntilToken "/T"
    ses <-tTakeUntilToken "/"
    tDropUntilToken ("/")
    rest <- giveParseString
    return $ s <> "/T" <> ses <> "/" <>  intt id <> "/" <> rest

  short id= do
    s <- tTakeUntilToken "/S" -- "/0/0/"
    ses <-tTakeUntilToken "/"
    rest <- giveParseString
    return $ s <> "/T" <> ses <> "/" <> intt id <> "/" <> rest


  intt = BS.pack . show

-- | include JSON data in the response.
output :: ToJSON a => a -> TransIO ()
output= sendFragment . encode

-- | It is  used as the last response in a flow
moutput :: ToJSON a => a -> Cloud ()
moutput= local . output

--  | Send a JSON fragment
sendFragment tosend = do
  let l = fromIntegral $ BS.length tosend
  tr ("SENDFRAGMENT000",tosend)
  conn <- getState
  -- let tosend = tostr "{ \"msg\":" <>  toSend <> str "}"
  let l = fromIntegral $ BS.length tosend

                -- for HTTP 1.0 no chunked encoding:
                -- msend conn $ str "HTTP/1.0 200 OK\r\nContent-Length: " <> str(show l) <> str "\r\n\r\n" <> tosend
                -- mclose conn
  checkComposeJSON conn
  msend conn $ toHex l <> "\r\n" <> tosend <> "\r\n"

getSessionState :: (Typeable a, Loggable a) => TransIO a
getSessionState = res
  where
    res = Transient $ do
      mc <- getData
      case mc of
        Nothing -> tr "NO MAP" >> return Nothing
        Just (Context idcontext' mf) -> do
          case M.lookup (show $ typeOf $ ty res) mf of
            Just str -> runTrans $ withParseString str deserialize
            Nothing -> return Nothing
    -- return $ fmap read $ M.lookup (show $ typeOf $ ty res) mf
    ty :: TransIO a -> a
    ty = undefined

newSessionState :: (Loggable a, Typeable a) => a -> Cloud ()
newSessionState x = local $ do
  ctx <- Context <$> genSessionId <*> return (M.singleton (show $ typeOf x) (toLazyByteString $ serialize x))
  setState ctx

-- | set a session value of the given type that last across all the navigation of a given user
setSessionState x = do
  modifyData'
    (\(Context n map) -> Context n $ M.insert (show $ typeOf x) (toLazyByteString $ serialize x) map)
    (Context 0 $ M.singleton (show $ typeOf x) $ toLazyByteString $ serialize x)
  return ()

genSessionId :: MonadIO m => m Int
genSessionId = liftIO $ do
  n <- randomIO
  return $ if n < 0 then - n else n


class  Typeable a => ToHTTPReq a where
  toHTTPReq :: a -> TransIO HTTPReq
  toHTTPReq x= do
      v <- varunique $ lowertype x
      return $ mempty{requrl= "/" <> v}
    where
    lowertype x = "$" <> BS.pack (map toLower (typeOfR x))
    typeOfR x = show $ typeOf x





instance ToHTTPReq () where
  toHTTPReq _ = return $ mempty {requrl = "/u"}

instance ToHTTPReq String where
  toHTTPReq _ = return $ mempty {requrl = "/$string"}

instance ToHTTPReq BS.ByteString where
  toHTTPReq _ = return $ mempty {requrl = "/$string"}

instance ToHTTPReq Int

instance ToHTTPReq Integer

instance ToHTTPReq a => ToHTTPReq [a] where
  toHTTPReq xs= (return $ mempty {requrl = "["}) <> toHTTPReq ( f xs) <> (return $ mempty {requrl = "]"})
    where
    f :: [a] -> a
    f= undefined

instance  (Default a, ToJSON a, Typeable a
          ,Default b, ToJSON b, Typeable b) => ToHTTPReq (POSTData(a,b)) where
    toHTTPReq (POSTData x)=  addbody "["   <> toHTTPReq (POSTData (fst x)) <>
                              addbody ", " <> toHTTPReq (POSTData (snd x)) <>
                              addbody "]"
      where
      addbody s= return mempty{reqbody=s}

instance  (Default a, ToJSON a, Typeable a
          ,Default b, ToJSON b, Typeable b
          ,Default c, ToJSON c, Typeable c) => ToHTTPReq (POSTData(a,b,c)) where
    toHTTPReq (POSTData x)=  addbody "["   <> toHTTPReq (POSTData (fst x)) <>
                              addbody ", " <> toHTTPReq (POSTData (snd x)) <>
                              addbody ", " <> toHTTPReq (POSTData (trd x)) <>
                              addbody "]"
      where
      fst (x,_,_)= x
      snd (_,x,_)= x
      trd (_,_,x)= x
      addbody s= return mempty{reqbody=s}

instance  (Default a, ToJSON a, Typeable a
          ,Default b, ToJSON b, Typeable b
          ,Default c, ToJSON c, Typeable c
          ,Default d, ToJSON d, Typeable d) => ToHTTPReq (POSTData(a,b,c,d)) where
    toHTTPReq (POSTData x)=  addbody "["   <> toHTTPReq (POSTData (fst x)) <>
                              addbody ", " <> toHTTPReq (POSTData (snd x)) <>
                              addbody ", " <> toHTTPReq (POSTData (trd x)) <>
                              addbody ", " <> toHTTPReq (POSTData (frt x)) <>
                              addbody "]"
      where
      fst (x,_,_,_)= x
      snd (_,x,_,_)= x
      trd (_,_,x,_)= x
      frt (_,_,_,x)= x
      addbody s= return mempty{reqbody=s}

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

newtype POSTData a = POSTData a deriving (ToJSON, FromJSON, Typeable)  -- POSTData is recovered from POST HTTP data

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
      pc <- process $ encode (def `asTypeOf` x)
      return $ mempty {reqtype = POST, reqbody = pc}
     <|> do
       t <- jsonType  x
       return mempty{reqtype=POST,reqbody= t}

    where


    jsonType x=do
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


    process json = withParseString json $ do
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
                let r = prev <> "\\\"" <> var <> "\\\": " <> q isq <> "$" <> var' <> q isq <> BS.singleton sep
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

    if (isJust mcon) then setData (fromJust mcon) else delData c

  isTLS c = liftIO $ do
      cdata <- readIORef $ connData c
      case cdata of
        Just (TLSNode2Node _) -> return True
        _ -> return False

  while act fix = do r <- act; b <- fix r; if b then return r else act



#endif