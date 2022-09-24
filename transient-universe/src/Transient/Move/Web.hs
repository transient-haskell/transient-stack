{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverlappingInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE CPP, LambdaCase #-}

#ifndef ghcjs_HOST_OS

module Transient.Move.Web  (minput,out,public,published,ToRest,POSTData(..),HTTPReq(..)
 ,getSessionState,setSessionState,newSessionState,rawHTTP,serializetoJSON,deserializeJSON,IsCommand,optionEndpoints,getCookie,setCookie) where

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
import Transient.Logged
import Transient.Move.Internals
import Transient.Parse
import Unsafe.Coerce
import Data.List
--------------------------WEB--------------------------------------



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

minput :: (Loggable a, ToRest a,ToJSON b) => String -> b -> Cloud a
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
        closdata@(Closure sess closRemote _) <- getIndexData (idConn conn) `onNothing` return (Closure 0 "0" [])
        mynode <- getMyNode
        ctx@(Context idcontext _) <- 
          getState <|> do
            ctx <- Context <$> genSessionId <*> return (M.empty)
            tr("CONTEXR from 0",ctx)
            setState ctx
            return ctx
        let idSession = idcontext
        let urlbase =
              str "http://" <> str (nodeHost mynode) <> str ":" <> intt (nodePort mynode)
                </> str ident
                </> "S" <> intt idSession
                -- </> BL.fromStrict closRemote
                -- </> intt sess
                -- </> intt idcontext ::
                -- BS.ByteString

        params <- toRest $ type1 response

        let httpreq = mempty {requrl = urlbase} <> params :: HTTPReq
        setState $ InputData ident msg httpreq
        connected log ctx idSession conn closLocal sess closRemote httpreq <|> commandLine conn log httpreq

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

          option ident $ BS.unpack msg <> "\t\"endpt " <> ident <> "\" for endpoint details" -- <> "\turl:\t"<> BS.unpack url
          setState IsCommand

          ctx@(Context idc _) <- liftIO $ atomically $ readDBRef ref `onNothing` error "minput: no context"
          setState ctx

          r <- 
            if typeOf response /= typeOf (undefined :: Cloud ())
              then do
                r <-  inputParse deserialize $ BS.unpack msg

                return r
              else return $ unsafeCoerce () 
          (_,r') <- logged $ return(idc,r)
          return r'

    connected log ctx@(Context idcontext _) idSession conn closLocal sess closRemote httpreq = do
      liftIO $ atomically $ writeDBRef (getDBRef $ show idcontext) ctx -- store the state, the id will be in the URL
      Endpoints endpts <- getEndpoints
      let nend= (str ident, httpreq)
      setRState $ Endpoints  $ M.insert (str ident) httpreq endpts -- (nend: (endpts \\ [nend]) )
      tr ("ADDED ENDPOINT",ident,httpreq)
      (idcontext' :: Int, result) <- do
        pstring <- giveParseString
        if (not $ recover log) || BS.null pstring
          then do
            tr "EN NOTRECOVER"

            ty <- liftIO $ readIORef $ connData conn
            case ty of
              Just Self -> do
                receive conn (Just $ BC.pack ident) idSession
                delState IsCommand
                tr "SELF XXX"

                logged $ liftIO $ do error "insuficient parameters 1"; empty -- read the response

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
                logged $ error "not enough parameters 2" -- read the response, error if response not logged
          else do
            receive conn (Just $ BC.pack ident) idSession
            delState IsCommand
            tr ("else",ident)
            logged $ error "insuficient parameters 3" -- read the response
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

        toHex 0 = mempty
        toHex l =
          let (q, r) = quotRem l 16
           in toHex q <> (BS.singleton $ if r <= 9 then toEnum (fromEnum '0' + r) else toEnum (fromEnum 'A' + r -10))

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
        liftIO $ withResource(InputDatas k undefined) $ \case 
                    Nothing                  -> InputDatas k [idata]
                    Just(InputDatas k lcks) -> InputDatas k $ idata:lcks 

        -- InputDatas k lcks <-  liftIO $ getResource (InputDatas k undefined) `onNothing` return (InputDatas k [])
        -- liftIO $  withResources []  [InputDatas k $ idata:lcks] 
        empty

-- | make available all the endpoints published by `public` with the given key
published k=  local $ do
    InputDatas _ inputdatas <-  liftIO $ getResource (InputDatas k undefined)  `onNothing` return (InputDatas k []) -- getRState
    tr ("PUBLISHED", inputdatas)
    
    mcommand <- getData :: TransIO (Maybe IsCommand)
    -- do not continue if not is in command mode or there is no connection
    if (isNothing mcommand) 
      then do foldr (<|>) empty $ map (\(InputData id msg url) ->  sendOption msg url) inputdatas; empty
      else do
            foldr (<|>) empty $ map (\(InputData id msg url) ->  optionl id  (BS.unpack msg <> "\t\"endpt " <> id <> "\" for endpoint details")  url) inputdatas
    where
    optionl id msg url = do
      Endpoints endpts <- getEndpoints
      setRState $ Endpoints $ M.insert (str id) url endpts -- ((str id, url): endpts)

      option id msg
      pars' <- input (const True) "enter the parameters > "
      tr ("PARS'",pars')
      -- substitute spaces by '/'
      pars <- withParseString (BS.pack pars') $ chainMany mappend (tTakeWhile' (/= ' ') <> ((tChar ' ' >>tTakeWhile' (==' ') >> "/") <|> mempty)) 
      tr("PARS",pars)
      let p = requrl url
      (cl,s,cl',s',ids) <- withParseString p $  do 
           string "http://" ; tTakeWhile' (/='/') 
           (,,,,) <$> tTakeWhile' (/='/') <*> tTakeWhile' (/='/')  <*> tTakeWhile' (/='/') <*> tTakeWhile' (/='/') <*> tTakeWhile' (/='/')
      tr("CL S",cl,s,cl',s',ids)
      Transient $ processMessage (read $ BS.unpack s) (BS.toStrict cl)  (read $ BS.unpack s') (BS.toStrict cl') (Right $ lazyByteString $ ids <> "/" <> pars) False
      return()

newtype Endpoints= Endpoints (M.Map BS.ByteString HTTPReq)
getEndpoints= getRState <|> return (Endpoints M.empty)
           

optionEndpoints = do
  newRState $ Endpoints M.empty
  option ("endpt" :: String) "info about a endpoint"
  Endpoints endpts <- getEndpoints
  liftIO $ do putStr "endpoints available: "; print $ M.keys endpts
  ident:: BS.ByteString <- input (const True) "enter the option for which you want to know the interface >"
  
  let murl = M.lookup ident  endpts
  case murl of
    Nothing ->  liftIO $ do putStr $ "there's no URL for " ; print ident
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
      cookies <- getCookiesStr
      liftIO $ print cookies
      msend conn cookies
      msend conn "\r\n1\r\n[\r\n"
      delState $ Cookies []

    Just InitSendSequence -> msend conn $ str "2\r\n\n,\r\n"
  
str = BS.pack

newtype Cookies= Cookies  [(BS.ByteString,BS.ByteString)]

getCookies= getState <|> return (Cookies [])

getCookiesStr= do
  Cookies cs <- getCookies
  return $  BS.concat (map (\(n,v)->  "Set-Cookie: " <> n <>"="<> v <> "\r\n" ) cs) 
               
setCookie name valueandparams=  do
  Cookies cs <- getCookies
  setState $ Cookies $ (name,valueandparams):cs

getCookie name= do
  HTTPHeaders _ headers :: HTTPHeaders <- getState <|>  return (HTTPHeaders undefined [])
  liftIO $ print headers
  let receivedCookie= lookup "Cookie:" headers

  liftIO $ print ("cookie", receivedCookie)
  case receivedCookie of
    Just str->  (withParseString (BS.fromStrict str) search) <|> return Nothing
    Nothing -> return Nothing
    where
    search= do
       d <- isDone 
       if d then return Nothing else do
                dropSpaces
                name' <- tTakeWhile' (/='=')
                val <- tTakeWhile' (/=';')
                liftIO $ print (name',val)
                if name'== name then return $ Just val else search

sendOption msg req = do
  Context id _ <- getState <|> error "sendOption:no minput context, use `minput`"
  url' <- withParseString (requrl req) $ do
    s <- tTakeUntilToken "/0/0/"
    tDropUntil (\s -> BS.head s == '$')
    s' <- giveParseString
    return $ s <> "/0/0/" <> intt id <> "/" <> s'

  sendFragment $ "{ \"msg\":\"" <>  msg <> "\", \"req\":" <> encode (req {requrl = url'}) <> "}"
  where
    intt = BS.pack . show

-- | include JSON data in the response
out :: ToJSON a => a -> TransIO ()
out= sendFragment . encode 


--  | Send a JSON fragment
sendFragment tosend = do
  let l = fromIntegral $ BS.length tosend
  conn <- getState
  checkComposeJSON conn

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
    (\(Context n map) -> (Context n $ M.insert (show $ typeOf x) (toLazyByteString $ serialize x) map))
    (Context 0 $ M.singleton (show $ typeOf x) $ toLazyByteString $ serialize x)
  return ()

genSessionId :: MonadIO m => m Int
genSessionId = liftIO $ do
  n <- randomIO
  return $ if n < 0 then - n else n

instance {-# OVERLAPPABLE #-} ToJSON a => Show a where
  show = BS.unpack . toLazyByteString . serializetoJSON . toJSON

instance FromJSON a => Read a where
  readsPrec _ _ = error "not implemented read for FromJSON class"

instance {-# OVERLAPPABLE #-} (Typeable a, ToJSON a, FromJSON a) => Loggable a where
  serialize = serializetoJSON
  deserialize = deserializeJSON

class  Typeable a => ToRest a where
  toRest :: a -> TransIO HTTPReq
  toRest x=  return $ mempty{requrl= "/"<> lowertype x}
    where
    lowertype x = "$" <> BS.pack (map toLower (typeOfR x))
    typeOfR x = show $ typeOf x

jsonType x=do 
  -- si tipo empieza por(
     -- es una tupla, cojer el tipo, cambiar ( por [, meter $ delante de los tokens, cambiar [Char] por string
  let types = show $ typeOf x
  withParseString (BS.pack types) $ tuple <|> list <|> single 
  where
  tuple=  parens $ "[" <> "$" <> type1  <> chainMany (<>) (comma <> "$" <> type1) <> "]"
  list=  (sandbox (string "[Cha") >> single) <|> ("$list_of_" <>  (brackets $ "[" <> tTakeWhile (/= ']')) <> "]s")
                                                                                    -- chainManyTill BS.cons anyChar (sandbox $ tChar ']')
  single=  "$" <> (stringFix <$>  chainMany BS.cons (toLower <$> anyChar))
  type1= stringFix <$> tTakeWhile (\c -> c /= ',' && c /= ')')  >>= varunique
                       -- 
                       -- chainManyTill BS.cons anyChar (sandbox $ tChar ',' <|> tChar ')')

  
  stringFix r
    | BS.null r = r
    | otherwise = if BS.head r == '[' then  "string" else  BS.map toLower r

  
data Vars= Vars[BS.ByteString]
varunique s= do
  Vars vars <- getState <|> let v= Vars [] in setState v >> return v
  if null $ filter (== s) vars then do setState $ Vars (s:vars); return s
                                else varunique $ BS.snoc s 'x'

instance {-# OVERLAPPABLE #-}  (Default a, ToJSON a, Typeable a) => ToRest (POSTData a) where
  toRest (POSTData x) = 
    do
      setState $ Vars[]
      pc <- process $ encode (def `asTypeOf` x)
      return $ mempty {reqtype = POST, reqbody = pc}
     <|> do
       t <- jsonType x
       return mempty{reqtype=POST,reqbody= t}
    where

      process json = withParseString json $ do
        sandbox $ tChar '{'
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

instance ToRest () where
  toRest _ = return mempty

instance ToRest String where
  toRest _ = return $ mempty {requrl = "/$string"}

instance ToRest BS.ByteString where
  toRest _ = return $ mempty {requrl = "/$string"}

instance ToRest Int

instance ToRest Integer

instance (ToRest a, ToRest b) => ToRest (a, b) where
  toRest x = toRest (fst x) <> toRest (snd x)

instance (ToRest a, ToRest b, ToRest c) => ToRest(a,b,c) where
    toRest x=  toRest (fst x) <>   toRest (snd x) <>  toRest (thr x)
      where
      fst (a,_,_)= a
      snd (_,b,_)= b
      thr (_,_,c)= c

instance (ToRest a, ToRest b,ToRest c,ToRest d) => ToRest(a,b,c,d) where
    toRest x= toRest (fst x) <>  toRest (snd x) <>  toRest (thr x) <> toRest (frt x)
      where
      fst (a,_,_,_)= a
      snd (_,b,_,_)= b
      thr (_,_,c,_)= c
      frt (_,_,_,d)= d

newtype POSTData a = POSTData a deriving (ToJSON, FromJSON, Typeable)

instance (Loggable a, ToJSON a, FromJSON a) => Loggable (POSTData a) where
  serialize (POSTData x)= serialize x
  deserialize = POSTData <$> deserialize 
    

-- instance ToRest (POSTData String) where
--   toRest (POSTData s) = return mempty {reqbody = "$string"}

-- instance ToRest (POSTData BS.ByteString) where
--   toRest (POSTData s) = return mempty {reqbody = "$string"}

-- instance ToRest (POSTData Int) where
--   toRest x = return mempty {reqbody = lowertype x}

-- instance ToRest (POSTData Integer) where
--   toRest x = return mempty {reqbody = lowertype x}


instance (ToJSON a, Default a, Typeable a, ToRest a, ToJSON b, Default b,Typeable b,ToRest b) => ToRest (POSTData (a, b)) where
  toRest (POSTData x) = pfrag "[" <> toRest (POSTData $ fst x) <> pfrag "," <> toRest (POSTData $ snd x) <> pfrag "]"

pfrag s = return $ mempty {reqbody = s}

-- instance (ToRest a, ToRest b, ToRest c) => ToRest(a,b,c) where
--     toRest (POSTData x)=   pfrag "[" <> toRest (POSTData $ fst x)  <> pfrag "," <>  toRest (POSTData $ snd x) <> pfrag "," <> toRest (POSTData $ thr x) <> pfrag "]"
--       where
--       fst (a,_,_)= a
--       snd (_,b,_)= b
--       thr (_,_,c)= c

-- instance (ToRest a, ToRest b,ToRest c,ToRest d) => ToRest(a,b,c,d) where
--     toRest x= toRest (fst x) <>  toRest (snd x) <>  toRest (thr x) <> toRest (frt x)
--       where
--       fst (a,_,_,_)= a
--       snd (_,b,_,_)= b
--       thr (_,_,c,_)= c
--       frt (_,_,_,d)= d



-- <|>  return (lowertype x))


-------------------------------  RAW HTTP client ---------------

serializetoJSON :: ToJSON a => a -> Builder
serializetoJSON = lazyByteString . encode

deserializeJSON :: FromJSON a => TransIO a
deserializeJSON = do
  s <- jsElem
  tr ("decode", s)

  case eitherDecode s of
    Right x -> return x
    Left err -> empty
  where
    jsElem :: TransIO BS.ByteString -- just delimites the json string, do not parse it
    jsElem = dropSpaces >> (jsonObject <|> array <|> atom)

    atom = elemString

    array =   try emptyList <|> (brackets $ return "[" <> jsElem <>  ( chainMany mappend (comma <>jsElem)) ) <> return "]"

    emptyList= string "[" <> (dropSpaces >> string "]")

    jsonObject = try emptyObject <|> (braces $ return "{" <> field  <>  (chainMany mappend (comma <> field)) ) <> return "}"

    emptyObject= string "{" <> (dropSpaces >> string "}")

    field =
      dropSpaces >> string "\"" <> tTakeWhile (/= '\"') <> string "\""
        <> (dropSpaces >> string ":" <> (dropSpaces >> jsElem))

    elemString = do
      dropSpaces
      (string "\"" <> tTakeWhile ( /= '\"' ) <> string "\"" )  <|>
         tTakeWhile (\c -> c /= '}' && c /= ']' && c /= ',')

instance {-# OVERLAPPING #-} Loggable Value where
  serialize = serializetoJSON
  deserialize = deserializeJSON

rawHTTP :: Loggable a => Node -> String -> TransIO a
rawHTTP node restmsg = sandbox $ do
  abduce -- is a parallel operation
  tr ("***********************rawHTTP", nodeHost node)
  --sock <- liftIO $ connectTo' 8192 (nodeHost node) (PortNumber $ fromIntegral $ nodePort node)
  mcon <- getData :: TransIO (Maybe Connection)
  c <-
    do
      c <- mconnect' node
      tr ("after mconnect'")
      cc <- liftIO $ readIORef $ connData c
      tr ("CONDATA",isJust cc)

      sendRawRecover c $ BS.pack restmsg

      c <- getState <|> error "rawHTTP: no connection?"
      let blocked = isBlocked c -- TODO: the same flag is used now for sending and receiving
      tr "before blocked"
      liftIO $ takeMVar blocked
      tr "after blocked"
      ctx <- liftIO $ readIORef $ istream c
      
      liftIO $ writeIORef (done ctx) False
      modify $ \s -> s {parseContext = ctx} -- actualize the parse context
      return c
      `while` \c -> do
        is <- isTLS c
        px <- getHTTProxyParams is
        tr ("PX=", px)
        (if isJust px then return True else do c <- anyChar; tPutStr $ BS.singleton c; tr "anyChar"; return True) <|> do
          TOD t _ <- liftIO $ getClockTime
          -- ("PUTMVAR",nodeHost node)
          liftIO $ putMVar (isBlocked c) $ Just t
          liftIO (writeIORef (connData c) Nothing)
          mclose c
          tr "CONNECTION EXHAUSTED,RETRYING WITH A NEW CONNECTION"
          return False

  modify $ \s -> s {execMode = Serial}
  let blocked = isBlocked c -- TODO: the same flag is used now for sending and receiving
  tr "after send"

  first@(vers, code, _) <-
    getFirstLineResp <|> do
      r <- notParsed
      error $ "No HTTP header received:\n" ++ up r
  tr ("FIRST line", first)
  headers <- getHeaders
  let hdrs = HTTPHeaders first headers
  setState hdrs

  --tr ("HEADERS", first, headers)

  guard (BC.head code == '2')
    <|> do
      Raw body <- parseBody headers
      error $ "Transient.Move.Web: ERROR in REQUEST: \n" <> restmsg  <> show body <> "\nRESPONSE HEADERS:\n " <> show hdrs 
  tr ("HEADERS",headers)

  result <- parseBody headers
  tr ("RESULT BODY",result)
  when
    ( vers == http10
        ||
        --    BS.isPrefixOf http10 str             ||
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
  return result
  where
    isTLS c = liftIO $ do
      cdata <- readIORef $ connData c
      case cdata of
        Just (TLSNode2Node _) -> return True
        _ -> return False

    while act fix = do r <- act; b <- fix r; if b then return r else act

--con<- getState <|> error "rawHTTP: no connection?"
--mclose con xxx
--maybeClose vers headers c str

#endif