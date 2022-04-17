module Transient.Move.Web where
import Transient.Internals
import Transient.Move.Internals


data InitSendSequence= InitSendSequence

data IsCommand= IsCommand deriving Show
data InputData= InputData String BS.ByteString deriving(Show,Read,Typeable)



minput :: (Loggable a,ToRest a) => String -> String -> Cloud a
minput ident msg=  response

 where
 response= do
  idSession <- local $ fromIntegral <$> genPersistId

  modify $ \s -> s{execMode=if execMode s == Remote then Remote else Parallel}
  local $ do
      log <-getLog
      conn <- getState -- if connection not available, execute alternative computation

      let closLocal= hashClosure log
      closdata@(Closure sess closRemote _) <- getIndexData (idConn conn) `onNothing` return (Closure 0 0 [])
      mynode <- getMyNode
      let url= str "http://" <> str (nodeHost mynode) <> str ":" <> intt (nodePort mynode) </>
                                    intt idSession </> intt closLocal </>
                                    intt sess </> intt closRemote </>
                                    toRest (type1 response)
      setState $ InputData msg url

      connected log idSession conn closLocal sess closRemote   url <|> commandLine conn log url

 commandLine conn log url = r
    where
    r= do
      guard (not $ recover log)

      cdata <- liftIO $ readIORef $ connData  conn
      mcommand <- getData :: TransIO (Maybe IsCommand)

      guard ( isJust mcommand || case cdata of Just Self ->  True; _ ->   False)
      if null ident then do liftIO $ putStrLn msg ; empty else do
        option ident  $ msg <> "\turl:\t"<> BS.unpack url
        setState IsCommand


        if typeOf r /= typeOf (undefined :: TransIO ()) then inputParse deserialize  msg else return $ unsafeCoerce ()



  -- connected :: Loggable a => TransIO a
 connected log  idSession conn closLocal sess closRemote   url= do


    pstring <- giveParseString
    if (not $ recover log)  || BS.null pstring

      then  do
        tr "EN NOTRECOVER"

        ty <- liftIO $ readIORef $ connData conn
        case ty of
         Just Self -> do
          -- liftIO $ print url
          receive conn  idSession
          tr "SELF XXX"

          logged $ error "insuficient parameters 1" -- read the response





         _ -> do

          -- insertar typeof response
          let tosend= str "{ \"msg\"=\""  <> str msg  <> str "\", \"url\"=\""  <> url <> str "\"}"
          let l = fromIntegral $ BS.length tosend

          ms <- getRData  -- avoid more than one onWaitthread, add "{" at the beguinning of the response
          case ms of
            Nothing -> do
               onWaitThreads $ const $  msend conn $ str "1\r\n]\r\n0\r\n\r\n"
               setRState InitSendSequence
               msend conn "1\r\n[\r\n"
            Just InitSendSequence -> msend conn $ str "2\r\n\n,\r\n"


          -- keep HTTP 1.0 no chunked encoding. HTTP 1.1 Does not render progressively well. It waits for end.
          -- msend conn $ str "HTTP/1.0 200 OK\r\nContent-Length: " <> str(show l) <> str "\r\n\r\n" <> tosend 
          -- mclose conn
          msend conn $  toHex l <> str "\r\n" <> tosend <> "\r\n"-- <>  "\r\n0\r\n\r\n"
          tr "after msend"
          -- store the msg and the url and the alias
          -- se puede simular solo con los datos actuales

          receive conn  idSession
          tr "after receive"
          delRState InitSendSequence

          logged $ error "not enough parameters 2" -- read the response, error if response not logged

      else do
        receive conn  idSession
        tr "else"
        logged $ error "insuficient parameters 3" -- read the response

      where


      toHex 0= mempty
      toHex l=
          let (q,r)= quotRem  l 16
          in toHex q <> (BS.singleton $ if r <= 9  then toEnum( fromEnum '0' + r) else  toEnum(fromEnum  'A'+ r -10))

 (</>) x y= x <> str "/" <> y
 str=   BS.pack
 intt= str . show
 type1:: Typeable a => Cloud a -> a
 type1 cx= r
        where
        r= error $ show $ typeOf r




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
            tr ("decode",s)

            case eitherDecode s !> "DECODE" of
              Right x -> return x
              Left err      -> empty





data HTTPHeaders= HTTPHeaders  (BS.ByteString, B.ByteString, BS.ByteString) [(CI BC.ByteString,BC.ByteString)] deriving Show



rawHTTP :: Loggable a => Node -> String  -> TransIO  a
rawHTTP node restmsg = do
  abduce   -- is a parallel operation
  tr ("***********************rawHTTP",nodeHost node)
  --sock <- liftIO $ connectTo' 8192 (nodeHost node) (PortNumber $ fromIntegral $ nodePort node)
  mcon <- getData :: TransIO (Maybe Connection)
  c <- do

      c <- mconnect' node
      tr "after mconnect'"
      sendRawRecover c  $ BS.pack restmsg

      c <-  getState <|> error "rawHTTP: no connection?"
      let blocked= isBlocked c    -- TODO: the same flag is used now for sending and receiving
      tr "before blocked"
      liftIO $ takeMVar blocked
      tr "after blocked"
      ctx <- liftIO $ readIORef $ istream c

      liftIO $ writeIORef (done ctx) False
      modify $ \s -> s{parseContext= ctx}  -- actualize the parse context

      return c
   `while` \c ->do
       is <- isTLS c
       px <- getHTTProxyParams is
       tr ("PX=", px)
       (if isJust px then return True else do c <- anyChar ; tPutStr $ BS.singleton c; tr "anyChar"; return True) <|> do
                TOD t _ <- liftIO $ getClockTime
                -- ("PUTMVAR",nodeHost node)
                liftIO $ putMVar (isBlocked c)  $ Just t
                liftIO (writeIORef (connData c) Nothing) 
                mclose c
                tr "CONNECTION EXHAUSTED,RETRYING WITH A NEW CONNECTION"
                return False

  modify $ \s -> s{execMode=Serial}
  let blocked= isBlocked c    -- TODO: the same flag is used now for sending and receiving
  tr "after send"
  --showNext "NEXT" 100
  --try (do r <-tTake 10;liftIO  $ print "NOTPARSED"; liftIO $ print  r; empty) <|> return()
  first@(vers,code,_) <- getFirstLineResp <|> do 
                                        r <- notParsed
                                        error $ "No HTTP header received:\n"++ up r
  tr ("FIRST line",first)
  headers <- getHeaders
  let hdrs= HTTPHeaders first headers
  setState hdrs

--tr ("HEADERS", first, headers)
  
  guard (BC.head code== '2') 
     <|> do Raw body <- parseBody headers
            error $ show (hdrs,body) --  decode the body and print

  result <- parseBody headers

  when (vers == http10                       ||
    --    BS.isPrefixOf http10 str             ||
        lookup "Connection" headers == Just "close" )
        $ do
            TOD t _ <- liftIO $ getClockTime

            liftIO $ putMVar blocked  $ Just t
            liftIO $ mclose c
            liftIO $ takeMVar blocked
            return()
  
  --tr ("result", result)
  
  
  --when (not $ null rest)  $ error "THERE WERE SOME REST"
  ctx <- gets parseContext
  -- "SET PARSECONTEXT PREVIOUS"
  liftIO $ writeIORef (istream c) ctx 
  
  

  TOD t _ <- liftIO $ getClockTime
  -- ("PUTMVAR",nodeHost node)
  liftIO $ putMVar blocked  $ Just t

  
  if (isJust mcon) then setData (fromJust mcon) else delData c
  return result
  where
  isTLS c= liftIO $ do
     cdata <- readIORef $ connData c
     case cdata of
          Just(TLSNode2Node _) -> return True
          _ -> return False

  while act fix= do r <- act; b <- fix r; if b then return r else act

parseBody headers= case lookup "Transfer-Encoding" headers of
          Just "chunked" -> dechunk |- deserialize

          _ ->  case fmap (read . BC.unpack) $ lookup "Content-Length" headers  of

                Just length -> do
                      msg <- tTake length
                      tr ("GOT", length)
                      withParseString msg deserialize
                _ -> do
                  str <- notParsed   -- TODO: must be strict to avoid premature close
                  BS.length str  `seq` withParseString str deserialize


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




dechunk=  do

           n<- numChars
           if n== 0 then do string "\r\n";  return SDone else do
               r <- tTake $ fromIntegral n   !> ("numChars",n)
               --tr ("message", r)
               trycrlf
               tr "SMORE1"
               return $ SMore r

     <|>   return SDone !> "SDone in dechunk"
 
    where
    trycrlf= try (string "\r\n" >> return()) <|> return ()
    numChars= do l <- hex ; tDrop 2 >> return l
