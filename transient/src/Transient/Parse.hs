{-#LANGUAGE FlexibleContexts, ExistentialQuantification, ScopedTypeVariables, OverloadedStrings, TypeSynonymInstances, FlexibleInstances #-}
module Transient.Parse where
import Transient.Internals
import Control.Applicative
import Data.Char
import Data.Monoid

import System.IO.Unsafe
import Control.Monad
import Control.Monad.State
-- import Control.Exception (throw,IOException)
import Control.Concurrent.MVar
import Data.Maybe(fromJust)
import qualified Data.ByteString.Lazy.Char8  as BS
import Data.ByteString.Builder
import Control.Exception hiding (try)
import Data.IORef
import Control.Concurrent
import Data.Maybe

-- | set a stream of strings to be parsed
setParseStream :: TransMonad m =>  TransIO (StreamData BS.ByteString) -> m ()
setParseStream iox=  modify $ \s -> s{execMode=Serial,parseContext= ParseContext iox "" (unsafePerformIO $ newIORef False)} -- setState $ ParseContext iox ""


-- | set a string to be parsed
setParseString :: TransMonad m => BS.ByteString -> m ()
setParseString x = modify $ \s -> s{execMode=Serial,parseContext= ParseContext (return SDone) x (unsafePerformIO $ newIORef False)} --  setState $ ParseContext (return SDone) x 


withParseString ::  BS.ByteString -> TransIO a -> TransIO a
withParseString x parse= do
     p <- gets parseContext -- getState <|> return(ParseContext (return SDone) mempty)
     setParseString x
     r <- parse
     modify $ \s -> s{parseContext= p} --setState (ParseContext c (str :: BS.ByteString))
     return r


withParseStream stream parse= do
     p <- gets parseContext -- getState <|> return(ParseContext (return SDone) mempty)
     setParseStream stream
     r <- parse
     modify $ \s -> s{parseContext= p} --setState (ParseContext c (str :: BS.ByteString))
     return r

-- | The parse context contains either the string to be parsed or a computation that gives an stream of
-- strings or both. First, the string is parsed. If it is empty, the stream is pulled for more.
-- data ParseContext str = IsString str => ParseContext (IO  (StreamData str)) str deriving Typeable


-- | succeed if read the string given as parameter
string :: BS.ByteString -> TransIO BS.ByteString
string s= withGetParseString $ \str -> do
    let len= BS.length s
        ret@(s',_) = BS.splitAt len str

    if s == s'   -- !> ("parse string looked, found",s,s')

      then return ret 
      else empty -- !> "STRING EMPTY"

-- | fast search for a token.
-- If the token is not found, the parse is left in the original state.
tDropUntilToken token= withGetParseString $ \str -> 
    if BS.null str then empty else  drop2 str 
  where 
  drop2 str=
    if token `BS.isPrefixOf` str   -- !> (BS.take 2 str)
          then  return ((),BS.drop (BS.length token) str)
          else if not $ BS.null str then drop2 $ BS.tail str else empty



tTakeUntilToken :: BS.ByteString -> TransIO BS.ByteString
tTakeUntilToken token= withGetParseString $ \str -> takeit mempty str
  where 
  takeit :: Builder -> BS.ByteString -> TransIO ( BS.ByteString, BS.ByteString)
  takeit res str= 
   if BS.null str then return (toLazyByteString res,str) else 
      if token `BS.isPrefixOf` str 
          then  return (toLazyByteString res ,BS.drop (BS.length token) str)
          else  if not $ BS.null str then takeit (  res <> (lazyByteString $ BS.singleton $ BS.head str)) $ BS.tail str else empty
    
    
-- | read an Integer
integer :: TransIO Integer
integer= withGetParseString $ \str -> 
           case BS.readInteger str of  
             Just  x -> return  x
             Nothing -> empty

-- | parse an hexadecimal number
hex ::  TransIO Int
hex = withGetParseString $ \s ->  parsehex (-1) s
  where

  parsehex v s=
    case (BS.null s,v) of
      (True, -1) ->  empty
      (True,_) -> return (v, mempty)
      _  -> do


          let h= BS.head s !> ("HEX",BS.head s)

              t= BS.tail s
              v'= if v== -1 then 0 else v
              x = if h >= '0' && h <= '9' then v' * 16 + ord(h) -ord '0'
                        else if h >= 'A' && h <= 'F' then  v' * 16 + ord h -ord 'A' +10
                        else if h >= 'a' && h <= 'f' then  v' * 16 + ord h -ord 'a' +10
                        else -1
          case (v,x) of
              (-1,-1) -> empty
              (v, -1) -> return (v,s)  
              (_, x) -> parsehex x t           
{-
integer= do
    s <- tTakeWhile isNumber
    if BS.null  s  then empty else return $ stoi 0 s
  :: TransIO Integer

   where
   stoi :: Integer -> BS.ByteString -> Integer
   stoi x s| BS.null s = x
           | otherwise=  stoi (x *10 + fromIntegral(ord (BS.head s) - ord '0')) (BS.tail s)
-}


-- | read an Int
int :: TransIO Int
int= withGetParseString $ \str -> 
           case BS.readInt str of  
             Just  x -> return  x
             Nothing -> empty
{-
int= do 
    s <- tTakeWhile isNumber
    if BS.null s then empty else return $ stoi 0 s

    where
    stoi :: Int -> BS.ByteString -> Int
    stoi x s| BS.null s = x
            | otherwise=  stoi (x *10 + (ord (BS.head s) - ord '0')) (BS.tail s)
-}
-- | read a double in floating point/scientific notation
double :: TransIO Double 
double= do 
    ent  <- integer  -- takes the sign too
    frac <- fracf
    exp <- expf
     
    return $ (fromIntegral  ent * (10 ^ exp)) +- (( (fromIntegral $ fst $ fromJust $ BS.readInteger frac)) 
                       /(10 ^ (fromIntegral (BS.length frac) - exp)))
    where 
    (+-) a b= if a >= 0 then a + b else a - b

    fracf= do 
       tChar '.' 
       tTakeWhile isDigit
      <|> return "0"
    
    expf= do 
        tChar 'e' <|> tChar 'E'
        int
      <|> return 0


-- | read many results with a parser (at least one) until a `end` parser succeed.
manyTill :: TransIO a -> TransIO b -> TransIO [a]
manyTill= chainManyTill (:)

--chainManyTill   :: Monoid m =>  (m -> a -> a) -> TransIO m -> TransIO t -> TransIO a
chainManyTill op p end=   scan
      where
      scan  = do{try end; return mempty }
            <|>
              do{ x <- p; xs <- scan; return (x `op` xs) }

between open close p = do{ open; x <- p; close; return x }

symbol = string 
         
parens p        = between (symbol "(") (symbol ")") p  !> "parens "
braces p        = between (symbol "{") (symbol "}") p  !> "braces "
angles p        = between (symbol "<") (symbol ">") p  !> "angles "
brackets p      = between (symbol "[") (symbol "]") p  !> "brackets "

semi            = symbol ";"  !> "semi"
comma           = symbol ","  !> "comma"
dot             = symbol "."  !> "dot"
colon           = symbol ":"  !> "colon"



sepBy p sep         = sepBy1 p sep <|> return []


sepBy1 = chainSepBy1 (:) 


chainSepBy chain p sep= chainSepBy1 chain p sep <|> return mempty

-- take a byteString of elements separated by a separator and  apply the desired operator to the parsed results
chainSepBy1
  :: (Monad m, Monoid b, Alternative m) =>
     (a -> b -> b) -> m a -> m x -> m b
chainSepBy1 chain p sep= do{ x <- p
                        ; xs <- chainMany chain (sep >> p)
                        ; return (x `chain` xs)
                        }
                        !> "chainSepBy "
       
chainMany chain v= (chain <$> v <*> chainMany chain v) <|> return mempty
       
commaSep p      = sepBy p comma
semiSep p       = sepBy p semi

commaSep1 p     = sepBy1 p comma
semiSep1 p      = sepBy1 p semi

dropSpaces= withGetParseString $ \str ->  return( (),BS.dropWhile isSpace str)

dropTillEndOfLine= withGetParseString $ \str -> return ((),BS.dropWhile ( /= '\n') str) !> "dropTillEndOfLine"



parseString= do
    tr "parseString"
    dropSpaces 
    r <- tTakeWhile (not . isSpace)
    return r


-- | take characters while they meet the condition. if no char matches, it returns empty
tTakeWhile :: (Char -> Bool) -> TransIO BS.ByteString
tTakeWhile cond= -- parse (BS.span cond)
    withGetParseString $ \s -> do 
      let ret@(h,_)= BS.span cond s
      --return () !> ("takewhile'",h,t)
      if BS.null h then empty else return ret
      
   
   
-- | take characters while they meet the condition and drop the next character
tTakeWhile' :: (Char -> Bool) -> TransIO BS.ByteString
tTakeWhile' cond= withGetParseString $ \s -> do
   let (h,t)= BS.span cond s
   return () !> ("takewhile'",h,t)
   if BS.null h then empty else return (h, if BS.null t then t else BS.tail t) 

 
just1 f x= let (h,t)= f x in (Just h,t)

-- | take n characters 
tTake n= withGetParseString $ \s ->  return $ BS.splitAt n s  !> ("tTake",n)

-- | drop n characters
tDrop n= withGetParseString $ \s ->  return $ ((),BS.drop n s)

-- | read a char. If there is no input left it fails with empty
anyChar= withGetParseString $ \s -> if BS.null s then empty else  return (BS.head s ,BS.tail s ) -- !> ("anyChar",s)

-- | verify that the next character is the one expected
tChar c= withGetParseString $ \s -> if BS.null s || BS.head s /= c then empty else return (BS.head s,BS.tail s)  -- !> ("tChar", BS.head s) 
   --  anyChar >>= \x -> if x == c then return c else empty !> ("tChar",x)

{-
withGetParseString2 :: (BS.ByteString -> TransIO (a,BS.ByteString)) -> TransIO a
withGetParseString2 parser=  do

  ParseContext readMore s done <- gets parseContext 

  let str =  s <>  iter 
      iter =  
        let mr =  lazy  !> "READMORE"
        in case mr of
          SMore r ->  r <> iter  !> "SMORE"
          SLast r -> writeIORef done True `seq` r
          SDone   -> writeIORef done True `seq` mempty

      lazy  = unsafePerformIO $ do
        r <- readIORef done
        if r then return SDone else do
          (x,_) <- runTransient readMore 
          tr x
          return $ fromJust x

  (v,str') <- parser str
  modify $ \s -> s{parseContext= ParseContext readMore str' done}
  return  v
  where 
  

-- >>> :set -XOverloadedStrings
-- >>> :m + Transient.Internals Transient.Parse Control.Monad.IO.Class Data.ByteString.Lazy 
-- >>> keep' $ do setParseStream (return  $ SMore "hello") ; r <- withGetParseString2 $ \s-> return(Data.ByteString.Lazy.take 13 s,Data.ByteString.Lazy.drop 13 s); liftIO $ print r
-- >>> keep' $ do setParseString "time-1.9.3/lib/Data/Time/Clock/Internal/SystemTime.hs:1:1: error:" ; r <- (,,) <$> tTakeWhile' (/=':') <*> int <* tChar ':' <*> int; liftIO $ print r
-- "hellohellohel"
-- Nothing
-- ("time-1.9.3/lib/Data/Time/Clock/Internal/SystemTime.hs",1,1)
-- Nothing
--

-}


--
  --

{-
withGetParseString3 :: (BS.ByteString -> TransIO (a,BS.ByteString)) -> TransIO a
withGetParseString3 parser=  do

  ParseContext readMore s done <- gets parseContext 
  
  modify $ \st -> st{execMode= Serial}
  str <-  return s <> iter readMore
  (v,str') <- parser str
  modify $ \s -> s{parseContext= ParseContext readMore str' done}
  return  v
  where
  iter readMore= do
    -- modify $ \s -> s{execMode= Remote}
    mr <-   readMore !> "READMORE"
    case mr of
       SMore r ->  do liftIO $ print "SMORE";  return r <> iter readMore  
       SLast r ->  return r
       SDone   ->  return mempty
       
  
  lazy mx= unsafePerformIO  $ do
      (x,_) <- runTransient mx 
      return $ fromJust x
-}



-- | bring the lazy byteString state to a parser which return the rest of the stream together with the result
-- and actualize the byteString state with it
-- The tuple that the parser returns should be :  (what it returns, what should remain to be parsed)



withGetParseString ::   (BS.ByteString -> TransIO (a,BS.ByteString)) -> TransIO a
withGetParseString parser=  Transient $ do
  
    ParseContext readMore s done <- gets parseContext 
 
    let loop = unsafeInterleaveIO $ do
          r <-readIORef done
          if r then return mempty else do
            (mr,_) <- runTransient readMore
            case mr of 
              Nothing -> mempty 
              Just(SMore r) ->  return r <> do 
                                              d <- readIORef done
                                              tr ("DONE",d)
                                              if d then mempty else loop

              Just(SLast r) -> do tr "LAST"; writeIORef done True ; return r
              Just SDone -> do  tr  "DONE"; writeIORef done True ; return mempty  -- !> "withGetParseString SDONE" 

    -- str <-  liftIO $ (s <> ) `liftM`  loop
    str <- liftIO $ return s <> loop
    if BS.null str then return Nothing else do
        --return () !> ("withGetParseString", BS.take 3 str)
        mr <- runTrans $ parser str
        case mr of
                  Nothing -> return Nothing    --  !> "NOTHING"
                  Just (v,str') -> do
                        --return () !> (v,str') 
                        modify $ \s-> s{parseContext= ParseContext readMore str' done}
                        return $ Just v



-- >>> keep' $ do x <- return "hello" <> lazy (liftIO $ print "world" >> return "world"); liftIO $ print $ take 3 x


-- >>> :set -XOverloadedStrings
-- >>> :m + Transient.Internals Transient.Parse Control.Monad.IO.Class
-- >>> keep' $ do x <- withParseStream (return $ SMore "hello world") $ tTake 2 ; liftIO $ print x
-- *** Exception: ghc: signal: 15
--




-- | bring the data of the parse context as a lazy byteString
giveParseString :: TransIO BS.ByteString
giveParseString= (noTrans $ do
   ParseContext readMore s done<- gets parseContext -- getData `onNothing` error "parser: no context"
                                --  :: StateIO (ParseContext BS.ByteString)  -- change to strict BS

   let loop = unsafeInterleaveIO $ do
           (mr,_) <-  runTransient readMore
           case mr of 
            Nothing -> mempty
            Just(SMore r) ->  (r <>) `liftM` loop
            Just(SLast r) ->  (r <>) `liftM` loop
            Just SDone -> return mempty
   liftIO $ (s <> ) `liftM` loop)

tDropUntil cond= withGetParseString $ \s -> f s
  where 
  f s= if BS.null s then return ((),s) else if cond s then return ((),s) else f $ BS.tail s

tTakeUntil cond= withGetParseString $ \s -> f s
  where 
  f s= if BS.null s then return (s,s) else if cond s then return (s,s) else f $ BS.tail s

-- | True if the stream has finished
isDone :: TransIO Bool
isDone=  noTrans $ do 
    ParseContext _ _ done<- gets parseContext 
    liftIO $ readIORef done

dropUntilDone= (withGetParseString $ \s -> do
    tr "dropUntilDone"
    ParseContext _ _ done <- gets parseContext
    let loop s= do
            if (unsafePerformIO $ readIORef done)== True ||  BS.null s then return((), s) else loop $ BS.tail s
            -- end <- s `seq` liftIO $ readIORef   done
            -- if end then return((), s) else loop $ BS.tail s
    loop s)
   <|> return()
    
               

-- | return the portion of the string not parsed
-- it is useful for testing purposes:
--
-- >  result <- myParser  <|>  (do rest <- notParsed ; liftIO (print "not parsed this:"++ rest))
--
--  would print where myParser  stopped working. 
-- This does not work with (infinite) streams. Use `getParseBuffer` instead
notParsed:: TransIO BS.ByteString
notParsed= withGetParseString $ \s -> return (s,mempty) !> "notParsed"

-- | get the current buffer already read but not yet parsed
getParseBuffer :: TransIO BS.ByteString
getParseBuffer= do
  ParseContext _ s _<- gets parseContext
  return s

-- | empty the buffer
clearParseBuffer :: TransIO ()
clearParseBuffer= 
   modify$ \s -> s{parseContext= let ParseContext readMore _ d= parseContext s in ParseContext readMore mempty d}

-- | Used for debugging. It shows the next N characters in the parse buffer 
showNext msg n= try (do r <- tTake n; liftIO $ print (msg,r); empty) <|> return ()

        
        
        
-- infixl 0 |-

-- | Chain two parsers. The motivation is to parse a chunked HTTP response which contains
-- JSON messages.
--
-- If the REST response is infinite and contains JSON messages, I have to chain the 
-- dechunk parser with the JSON decoder of aeson, to produce a stream of aeson messages. 
-- Since the boundaries of chunks and JSON messages do not match, it is not possible to add a 
-- `decode` to the monadic pipeline. Since the stream is potentially infinite and/or the
-- messages may arrive at any time, I can not wait until all the input finish before decoding 
-- the messages.
--
-- I need to generate a ByteString stream with the first parser, which is the input for
-- the second parser. 
-- 
-- The first parser wait until the second consume the previous chunk, so it is pull-based.
--
-- many parsing stages can be chained with this operator.
--
-- The output is nondeterministic: it can return 0, 1 or more results
--
-- example: https://t.co/fmx1uE2SUd
(|--) :: TransIO (StreamData BS.ByteString) -> TransIO b -> TransIO b
p |-- q =  do
  --addThreads 1
  v  <- liftIO $ newIORef undefined -- :: TransIO (MVar (StreamData BS.ByteString -> IO ()))
  initq v <|> initp v
    -- `catcht`  \(_ :: BlockedIndefinitelyOnMVar) -> empty
-- TODO #2 use react instrad of MVar's? need buffering-contention
  where
  initq v= do
    --abduce
    r <-withParseStream (takev v ) q
    liftIO $ print "AFGRT WITH"
    return r

  initp v= do
    --abduce

    return () !> "INITP"
    repeatIt
    where
    repeatIt= do 
        r <- p
        putv  v r
        return () !> "AFTER PUTV"
        repeatIt
        empty
        -- return () !> ("putMVar")
        -- t <-liftIO  $ (putv v r >> return True)  `catcht` \(_ :: BlockedIndefinitelyOnMVar) -> return  False
        -- if t then repeatIt  else empty

  takev v= do 
       return () !> "BEFORE TAKEV"
       --modify $ \s -> s{execMode= Remote}
       r <- react (writeIORef v) (return()) 
       return () !> ("TAKEV",r)
       liftIO $ threadDelay 5000000
       return r
           

  
  putv v s= liftIO $ do
     proc <-   readIORef v -- :: TransIO (StreamData BS.ByteString -> IO())
     return  () !> ("PUTV", s)
     proc s











(|-) :: TransIO (StreamData BS.ByteString) -> TransIO b -> TransIO b
p |- q =  do
  --addThreads 1
  pcontext <- liftIO $ newIORef $ Just undefined
  v  <- liftIO $ newEmptyMVar
  initp v pcontext <|> initq v pcontext
-- `catcht`  \(_ :: BlockedIndefinitelyOnMVar) -> empty

  where
  initq v pcontext= do
    --abduce
    setParseStream (do r <- liftIO $ takeMVar v; tr ("rec",fmap (BS.take 10) r); return r)--  `catch`  \(_:: SomeException) -> return SDone ) 
    r <- q
    dropUntilDone
    Just p <- liftIO $ readIORef pcontext
    liftIO $ writeIORef pcontext Nothing !> "WRITENOTHING"
    pc <- gets parseContext
    modify $ \ s -> s{parseContext= p{done=done pc}}
    return r

  initp v pcontext= do
    abduce
    ParseContext _ _ done <- gets parseContext

    let repeatIt= do
          pc <- liftIO $ readIORef pcontext
          if isNothing pc then tr "FINNNNNNNNNNNNNNNNNNNNNNNN" >> empty  else do
            d <- liftIO $ readIORef done
            if d then do  tr "sendDone";liftIO  $ putMVar v SDone; repeatIt else do
                r <- p 

                liftIO  $ putMVar v r  -- `catch` \(_ :: BlockedIndefinitelyOnMVar) -> return  False

                p <- gets parseContext
                liftIO $ writeIORef pcontext $ Just p
                case r of
                  SDone -> empty
                  SLast _ -> empty
                  SMore _ -> repeatIt

    repeatIt