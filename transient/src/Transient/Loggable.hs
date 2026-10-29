 {-#Language OverloadedStrings, ScopedTypeVariables, FlexibleInstances, UndecidableInstances #-}
{-# LANGUAGE InstanceSigs #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}
{-# HLINT ignore "Use typeRep" #-}

-- | The 'Loggable' type class and its standard instances.
--
-- 'Loggable' extends @(Show, Read, Typeable)@ with an efficient binary\/text
-- serialisation layer used by 'Transient.Move.Logged.logged' to checkpoint
-- computation state to disk so it can be resumed after a restart.
--
-- Values are serialised to a 'Data.ByteString.Builder' and deserialised via a
-- 'TransIO' parser (see "Transient.Parse"). Fields are separated by @/@.
module Transient.Loggable where

import Transient.Internals
import Transient.Parse
import qualified Data.ByteString.Lazy.Char8 as BS
import qualified Data.ByteString.Char8 as BSS
import Data.Typeable
import Data.ByteString.Builder
import Control.Exception hiding (try)
import qualified Data.Map as M
import Control.Applicative
import System.IO.Unsafe
import Unsafe.Coerce
import Control.Monad
import Control.Monad.IO.Class
import Data.Text(Text)
import qualified Data.Text as T
import Data.Text.Encoding as TE
import Data.Text.Encoding.Error (lenientDecode)
import Data.Char (ord, chr)
import Data.List (intersperse)
import Data.Proxy

{- | Values that can be serialised to\/from the Transient log format.

Minimal definition: nothing — the default implementations use 'show'\/'reads'
wrapped by 'fragment'.  Override for efficiency or when the default
@Show@\/@Read@ round-trip is unsuitable.
-}
class (Show a, Read a,Typeable a) => Loggable a where
    serialize :: a -> Builder
    serialize = byteString . BSS.pack . show

    deserializePure :: BS.ByteString -> Maybe(a, BS.ByteString)

    deserializePure s' = r
      where
      (s,rest)=  fragment  s' -- to avoid packing/unpacking the entire string
      r= case readsErr $ BS.unpack s   of -- `traceShow` ("deserialize",typeOf $ typeOf1 r,s) of
              []           -> Nothing  -- !> "Nothing"
              (r,rest'): _ -> Just (r,  BS.pack rest' <> rest)

      {-# INLINE readsErr #-}
      readsErr s=unsafePerformIO $  return (reads s) `catch`\(e :: SomeException) ->  return []


    deserialize ::  TransIO a
    deserialize = x
       where
       x=  withGetParseString $ \s -> case deserializePure s of
                    Nothing ->   empty
                    Just x -> return x



-- | Read a segment of the log path up to the next unescaped separator (@/@).
-- Quoted substrings (@\"…\"@) are included verbatim so embedded slashes are preserved.
fragment s
       |BS.null s= (mempty,mempty)
       |otherwise=
        let (r,rest)=  BS.span (\c->c /='/' && c /='\"') s -- to avoid packing/unpacking the entire string
        in  if not (BS.null rest) && BS.head rest== '\"'
            then
                     let (r',rest') = BS.span ( /='\"') $ BS.tail rest
                         (r'',rest'')= fragment $ BS.tail rest'
                         res= (r<> "\"" <> r' <> "\"" <> r'', rest'')
                     in  res
            else     (r,rest)


-- | Default 'Loggable' instance for any @(Show, Read, Typeable)@ type.
-- Uses the default 'serialize' \/ 'deserialize' implementations (show\/reads).
-- Specific instances override this via their higher specificity.
instance {-# OVERLAPPABLE #-} (Show a, Read a, Typeable a) => Loggable a

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

instance Loggable ()  where
  serialize _=  "u"
  deserialize= void (tChar 'u')

instance Loggable Bool where
  serialize b= if b then "t" else "f"
  deserialize = withGetParseString $ \s -> do
            let h= BS.head s
                tail=  BS.tail s
            if h== 't' then return (True,tail)  else if h== 'f' then return (False, tail) else empty

-- instance {-# OVERLAPPING #-} Loggable String where
  -- serialize s= byteString $ BSS.pack s
  -- deserialize= BS.unpack <$> tTakeWhile (/= '/')

instance Loggable Int

instance Loggable Integer


-- | Lists are written as a JSON array whose elements are written with their own 'serialize' (the strings, as JSON
-- strings), so @[Int]@ is @[1,2,3]@ and @[String]@ is @["a","b//c"]@. A @String@ is not a list of characters here:
-- it is a JSON string (see 'jsonString').
instance   (Typeable a, Loggable a) => Loggable [a]  where
    serialize xs
      | isChar    = jsonString $ T.pack (unsafeCoerce xs)
      | otherwise = byteString "[" <> mconcat (intersperse (byteString ",") (map serialize xs)) <> byteString "]"
      where
      isChar = typeRep (Proxy :: Proxy a) == typeRep (Proxy :: Proxy Char)

    deserialize
      | isChar    = unsafeCoerce . T.unpack <$> (deserialize :: TransIO Text)
      | otherwise = tChar '[' *> commaSep deserialize <* tChar ']'
      where
      isChar = typeRep (Proxy :: Proxy a) == typeRep (Proxy :: Proxy Char)

-- | A text as a JSON string literal (standard escapes, UTF-8) in which every @/@ is doubled, so that it can not be
-- taken for the separator of the log. The empty text is @""@, not confusable with the text @[]@.
jsonString :: Text -> Builder
jsonString t = char7 '"' <> T.foldr (\c b -> esc c <> b) mempty t <> char7 '"'
  where
  esc '"'  = byteString "\\\""
  esc '\\' = byteString "\\\\"
  esc '/'  = byteString "//"
  esc '\n' = byteString "\\n"
  esc '\r' = byteString "\\r"
  esc '\t' = byteString "\\t"
  esc '\b' = byteString "\\b"
  esc '\f' = byteString "\\f"
  esc c | c < ' '   = byteString "\\u" <> word16HexFixed (fromIntegral (ord c))
        | otherwise = charUtf8 c

-- | Read a JSON string literal with doubled slashes, or, if the text does not begin with a quote, the old raw format
-- (the text up to the next single @/@, with @//@ read as @/@). The raw format is read so that texts typed by hand
-- (console, URLs) and logs written before keep working; it is never written.
deserializeText :: TransIO Text
deserializeText = withGetParseString $ \s ->
    case parseJsonString s of
      Just r  -> return r
      Nothing -> let (raw, rest) = undupRaw s in return (TE.decodeUtf8With lenientDecode (BS.toStrict raw), rest)

-- | The raw format: up to the first single @/@, with @//@ read as @/@
undupRaw :: BS.ByteString -> (BS.ByteString, BS.ByteString)
undupRaw s =
    let (a, r) = BS.break (== '/') s
    in case BS.unpack (BS.take 2 r) of
         "//" -> let (b, r') = undupRaw (BS.drop 2 r) in (a <> BS.pack "/" <> b, r')
         _    -> (a, r)

parseJsonString :: BS.ByteString -> Maybe (Text, BS.ByteString)
parseJsonString s = case BS.uncons s of
    Just ('"', r) -> go r mempty
    _             -> Nothing
  where
  go r acc = case BS.uncons r of
    Nothing          -> Nothing
    Just ('"', rest) -> either (const Nothing) (\t -> Just (t, rest)) (TE.decodeUtf8' (BS.toStrict (toLazyByteString acc)))
    Just ('/', rest) -> case BS.uncons rest of          -- inside a string every slash is doubled
                          Just ('/', rest') -> go rest' (acc <> char7 '/')
                          _                 -> Nothing
    Just ('\\', rest) -> escape rest acc
    Just (c, rest)   -> go rest (acc <> word8 (fromIntegral (ord c)))   -- the bytes of a UTF-8 text go through

  escape r acc = case BS.uncons r of
    Just ('"', rest)  -> go rest (acc <> char7 '"')
    Just ('\\', rest) -> go rest (acc <> char7 '\\')
    Just ('/', rest)  -> go rest (acc <> char7 '/')
    Just ('b', rest)  -> go rest (acc <> char7 '\b')
    Just ('f', rest)  -> go rest (acc <> char7 '\f')
    Just ('n', rest)  -> go rest (acc <> char7 '\n')
    Just ('r', rest)  -> go rest (acc <> char7 '\r')
    Just ('t', rest)  -> go rest (acc <> char7 '\t')
    Just ('u', rest)  -> do
        (hi, rest') <- hex4 rest
        unicode hi rest' acc
    _ -> Nothing

  -- a code unit; a high surrogate has to be followed by the low half of its pair
  unicode hi rest acc
    | hi >= 0xD800 && hi < 0xDC00 =
        case BS.unpack (BS.take 2 rest) of
          "\\u" -> do
            (lo, rest') <- hex4 (BS.drop 2 rest)
            if lo >= 0xDC00 && lo < 0xE000
              then go rest' (acc <> charUtf8 (chr (0x10000 + (hi - 0xD800) * 0x400 + (lo - 0xDC00))))
              else Nothing
          _ -> Nothing
    | hi >= 0xDC00 && hi < 0xE000 = Nothing
    | otherwise = go rest (acc <> charUtf8 (chr hi))

  hex4 r = let (h, rest) = BS.splitAt 4 r
           in if BS.length h == 4 && BS.all (`elem` ("0123456789abcdefABCDEF" :: String)) h
                then Just (read ("0x" ++ BS.unpack h), rest) else Nothing

-- | Consume a @/@ separator (or skip leading spaces) between fields.
sspace= tChar '/' <|> (many (tChar ' ') >> return ' ')

-- | The character as a Haskell literal. The slash is written @'\\47'@: the separator of the log would cut @'/'@.
instance Loggable Char where
    serialize '/' = byteString "'\\47'"
    serialize c   = byteString . BSS.pack $ show c

    -- the generic reader cuts the text at the first @/@ and takes a @"@ for the start of a quoted string, so it
    -- could not read @'"'@ (it failed with an error): the literal is delimited here by its own quotes
    deserialize = withGetParseString $ \s -> case charLiteral s of
        Just (lit, rest) | [(c, "")] <- reads lit -> return (c, rest)
        _                                         -> empty
      where
      charLiteral s = do
          ('\'', r) <- BS.uncons s
          case BS.uncons r of
            Just ('\\', r1) -> do
                (c, r2) <- BS.uncons r1
                if c == '\''
                  then closing "\\'" r2                          -- the escaped quote: @'\''@
                  else let (body, r3) = BS.break (== '\'') r2 in closing ('\\' : c : BS.unpack body) r3
            _ -> let (body, r3) = BS.break (== '\'') r in closing (BS.unpack body) r3
      closing body r = do
          ('\'', rest) <- BS.uncons r
          return ("'" ++ body ++ "'", rest)
instance Loggable Float
instance Loggable Double
instance Loggable a => Loggable (Maybe a)

instance (Loggable a,Loggable b) => Loggable (a,b) where
  serialize (a,b)= serialize a <> byteString "/" <> serialize b
  deserialize = (,) <$> deserialize <*> (sspace >>  deserialize)

instance (Loggable a,Loggable b, Loggable c) => Loggable (a,b,c) where
  serialize (a,b,c)=  serialize a <> byteString "/" <> serialize b <> byteString "/" <> serialize c
  deserialize =  (,,) <$> deserialize <*> (sspace >>  deserialize) <*> (sspace >>  deserialize)

instance (Loggable a,Loggable b, Loggable c,Loggable d) => Loggable (a,b,c,d) where
  serialize (a,b,c,d)=  serialize a <> byteString "/" <> serialize b <> byteString "/" <> serialize c <> byteString "/" <> serialize d
  deserialize =  (,,,) <$> deserialize <*> (sspace >>  deserialize) <*> (sspace >>  deserialize) <*> (sspace >>  deserialize)

instance (Loggable a,Loggable b, Loggable c,Loggable d,Loggable e) => Loggable (a,b,c,d,e) where
  serialize (a,b,c,d,e)=  serialize a <> byteString "/" <> serialize b <> byteString "/" <> serialize c <> byteString "/" <> serialize d <> byteString "/" <> serialize e
  deserialize =  (,,,,) <$> deserialize <*> (sspace >>  deserialize) <*> (sspace >>  deserialize) <*> (sspace >>  deserialize) <*> (sspace >>  deserialize)

instance (Loggable a,Loggable b, Loggable c,Loggable d,Loggable e,Loggable f) => Loggable (a,b,c,d,e,f) where
  serialize (a,b,c,d,e,f)=  serialize a <> byteString "/" <> serialize b <> byteString "/" <> serialize c <> byteString "/" <> serialize d <> byteString "/" <> serialize e <> byteString "/" <> serialize f
  deserialize =  (,,,,,) <$> deserialize <*> (sspace >>  deserialize) <*> (sspace >>  deserialize) <*> (sspace >>  deserialize) <*> (sspace >>  deserialize) <*> (sspace >>  deserialize)

instance (Loggable a,Loggable b, Loggable c,Loggable d,Loggable e,Loggable f,Loggable g) => Loggable (a,b,c,d,e,f,g) where
  serialize (a,b,c,d,e,f,g)=  serialize a <> byteString "/" <> serialize b <> byteString "/" <> serialize c <> byteString "/" <> serialize d <> byteString "/" <> serialize e <> byteString "/" <> serialize f <> byteString "/" <> serialize g
  deserialize =  (,,,,,,) <$> deserialize <*> (sspace >>  deserialize) <*> (sspace >>  deserialize) <*> (sspace >>  deserialize) <*> (sspace >>  deserialize) <*> (sspace >>  deserialize) <*> (sspace >>  deserialize)

instance (Loggable a,Loggable b, Loggable c,Loggable d,Loggable e,Loggable f,Loggable g,Loggable h) => Loggable (a,b,c,d,e,f,g,h) where
  serialize (a,b,c,d,e,f,g,h)=  serialize a <> byteString "/" <> serialize b <> byteString "/" <> serialize c <> byteString "/" <> serialize d <> byteString "/" <> serialize e <> byteString "/" <> serialize f <> byteString "/" <> serialize g <> byteString "/" <> serialize h
  deserialize =  (,,,,,,,) <$> deserialize <*> (sspace >>  deserialize) <*> (sspace >>  deserialize) <*> (sspace >>  deserialize) <*> (sspace >>  deserialize) <*> (sspace >>  deserialize) <*> (sspace >>  deserialize) <*> (sspace >>  deserialize)

instance (Loggable a,Loggable b, Loggable c,Loggable d,Loggable e,Loggable f,Loggable g,Loggable h,Loggable i) => Loggable (a,b,c,d,e,f,g,h,i) where
  serialize (a,b,c,d,e,f,g,h,i)=  serialize a <> byteString "/" <> serialize b <> byteString "/" <> serialize c <> byteString "/" <> serialize d <> byteString "/" <> serialize e <> byteString "/" <> serialize f <> byteString "/" <> serialize g <> byteString "/" <> serialize h <> byteString "/" <> serialize i
  deserialize =  (,,,,,,,,) <$> deserialize <*> (sspace >>  deserialize) <*> (sspace >>  deserialize) <*> (sspace >>  deserialize) <*> (sspace >>  deserialize) <*> (sspace >>  deserialize) <*> (sspace >>  deserialize) <*> (sspace >>  deserialize) <*> (sspace >>  deserialize)



instance (Loggable a, Loggable b) => Loggable (Either a b)
-- #ifdef ghcjs_HOST_OS


instance (Loggable k, Ord k, Loggable a) => Loggable (M.Map k a)  where
  serialize v= intDec (M.size v) <> M.foldlWithKey' (\s k x ->  s <> "/" <> serialize k <> "/" <> serialize x ) mempty v
  deserialize= do
      len <- int
      list <- replicateM len $
                 (,) <$> (tChar '/' *> deserialize)
                     <*> (tChar '/' *> deserialize)
      return $ M.fromList list

-- | Escape every @/@ in a 'ByteString' as @//@ so it survives the @/@ field separator.
dupSlash s= BS.foldl dupCharSlash (lazyByteString "") s where
  dupCharSlash s '/'=  (s <> lazyByteString "//") !> "slash"
  dupCharSlash s c= s <> lazyByteString (BS.singleton c) !> c

-- | Characters treated as field separators in the log format.
separators = "/:\t\n; " :: String

-- | Inverse of 'dupSlash': unescape @//@ back to @/@ while consuming up to the next bare separator.
undupSlash = do
    sandbox' $ do r <- anyChar ; when (r `elem` ']':separators)  empty

    s <- tTakeUntil $ \s -> BS.head s == '/'
    do string "//"
       return s <> "/" <> undupSlash
     <|> return s

instance Loggable BS.ByteString where
        serialize str =   dupSlash str !> "serialize bytestring"
        deserialize= undupSlash

newtype QuotedBS= Quoted Builder deriving (Read,Show,Typeable)

instance Loggable QuotedBS

-- | A text is a JSON string ('jsonString').
instance Loggable Text where
    serialize   = jsonString
    deserialize = deserializeText

instance Loggable BSS.ByteString where
        serialize str = serialize $ BS.fromStrict str
        deserialize   = deserialize >>= return . BS.toStrict

instance Loggable SomeException

newtype Raw= Raw BS.ByteString deriving (Read,Show)
instance Loggable Raw where
  serialize (Raw str)= lazyByteString str
  deserialize= Raw <$> do
        s <- notParsed
        BS.length s `seq` return s  --force the read till the end 

instance Loggable Builder where
  serialize= id
  deserialize = byteString <$> deserialize

