 {-#Language OverloadedStrings, ScopedTypeVariables #-}
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
import Data.Text.Encoding as TE

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


instance   (Typeable a, Loggable a) => Loggable [a]  where
    serialize []= byteString "[]"
    serialize s@(x:xs)
              | typeOf x== typeOf (ofType :: Char) = serialize $ BS.pack (unsafeCoerce s)
              | otherwise = byteString "[" <> serializeNoString x <> serialize' xs
          where
          serialize' []= byteString "]"
          serialize' (x:xs)= byteString "," <> serializeNoString x <>  serialize' xs

          serializeNoString x
            | typeOf x== typeOf (ofType :: String) =
                        byteString "\""
                        <> serialize (BS.pack (unsafeCoerce x))
                        <> byteString "\""
            | otherwise = serialize x

    deserialize= r
      where
      ty :: TransIO [a] -> [a]
      ty = undefined
      r= if typeOf (ty r) /= typeOf (ofType :: String)
              then (tChar '[' *> commaSep deserialize <* tChar ']')
              else
                  
                -- do sandbox(tChar ']') ; empty -- return  (unsafeCoerce "")
                --  <|> 
                 do
                  -- either is a string in with " "
                        sandbox' $ tChar '\"'
                        -- s <- getParseBuffer
                        withGetParseString $ \s -> maybe empty return (deserializePure s)
                 <|> 
                  (unsafeCoerce . BS.unpack <$> deserialize)

-- | Consume a @/@ separator (or skip leading spaces) between fields.
sspace= tChar '/' <|> (many (tChar ' ') >> return ' ')

instance Loggable Char
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

instance Loggable Text where
    serialize =  byteString . TE.encodeUtf8 
    deserialize= do
       bs <- deserialize
       case TE.decodeUtf8' bs of
            Left err  -> throwt err
            Right txt -> return txt

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

