 {-#Language OverloadedStrings #-}

module Transient.Loggable where

import Transient.Internals
import Transient.Parse
import qualified Data.ByteString.Lazy.Char8 as BS
import qualified Data.ByteString.Char8 as BSS
import Data.Typeable
import Data.ByteString.Builder
import Control.Exception
import qualified Data.Map as M
import Control.Applicative
import System.IO.Unsafe
import Unsafe.Coerce
import Control.Monad


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


    {-
    deserializePure s = r
      where
      -- hideously inefficient
      r= case readsErr $ BS.unpack s   of -- `traceShow` ("deserialize",typeOf $ typeOf1 r,s) of
           []       -> Nothing  -- !> "Nothing"
           (r,t): _ -> return (r, BS.pack t)
      {-# INLINE readsErr #-}
      readsErr s=unsafePerformIO $ return(reads s) `catch`\(e :: SomeException) ->  return []
    -}

    deserialize ::  TransIO a
    deserialize = x
       where
       x=  withGetParseString $ \s -> case deserializePure s of
                    Nothing ->   empty
                    Just x -> return x

separators = "/:\t\n; "


-- | read a fragment of the log path until unescaped separator      
fragment s
       |BS.null s= (mempty,mempty)
       |otherwise=
        let (r,rest)=  BS.span (\c-> not (BS.elem c separators) && c /='\"') s -- to avoid packing/unpacking the entire string
        in trace (r,rest) $ if not (BS.null rest) && BS.head rest== '\"'
            then
                     let (r',rest') = BS.span ( /='\"') $ BS.tail rest
                         (r'',rest'')= fragment $ BS.tail rest'
                         res= (r<> "\"" <> r' <> "\"" <> r'', rest'')
                     in  res
            else     (r,rest)

-- instance Show Builder where
--  show b= show $ toLazyByteString b




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
  deserialize= tChar 'u' >> return ()

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
    serialize (s@(x:xs))
              | typeOf x== typeOf (undefined :: Char) = serialize $ BS.pack (unsafeCoerce s)
              | otherwise = byteString "[" <> serialize x <> serialize' xs
          where
          serialize' []= byteString "]"
          serialize' (x:xs)= byteString "," <> serialize x <>  serialize' xs

    deserialize= r
      where
      ty :: TransIO [a] -> [a]
      ty = undefined
      r= if typeOf (ty r) /= typeOf (undefined :: String)
              then tChar '[' *> commaSep deserialize <* tChar ']' 
              else 
                (do (Transient.Internals.try $ tChar '\"') ; unsafeCoerce <$> BS.unpack <$> deserialize) <|>
                do
                 str <-withGetParseString $ \s -> return $ BS.span (\c -> not $ BS.elem c separators) s
                 return $ unsafeCoerce $ BS.unpack str


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


-- intDec i= Builder $ \s -> pack (show i) <> s
-- int64Dec i=  Builder $ \s -> pack (show i) <> s

-- #endif
instance (Loggable k, Ord k, Loggable a) => Loggable (M.Map k a)  where
  serialize v= intDec (M.size v) <> M.foldlWithKey' (\s k x ->  s <> "/" <> serialize k <> "/" <> serialize x ) mempty v
  deserialize= do
      len <- int
      list <- replicateM len $
                 (,) <$> (tChar '/' *> deserialize)
                     <*> (tChar '/' *> deserialize)
      return $ M.fromList list

dupSlash s= BS.foldl dupCharSlash (lazyByteString "") s where
  dupCharSlash s '/'=  (s <> lazyByteString "//") !> "slash"
  dupCharSlash s c= s <> lazyByteString (BS.singleton c) !> c

undupSlash = do
    s <- tTakeUntil $ \s -> BS.head s == '/'
    do string "//"
       return s <> "/" <> undupSlash
     <|> return s 

instance Loggable BS.ByteString where
        serialize str =   dupSlash str !> "serialize bytestring"
        deserialize= undupSlash
          --  (do
          --   -- for strings between quotes
          --   tChar '"'
          --   r<- tTakeUntil (\s ->  BS.head s /= '\\' && BS.head (BS.tail s) =='"') <> tTake 1
          --   anyChar
          --   return r )

          -- <|> tTakeUntil (\s -> let c= BS.head s in c == '/') -- || c==' ')  -- problems wih "inputParse deserialize" in Web.h?



instance Loggable BSS.ByteString where
        serialize str = serialize $ BS.fromStrict  str
        deserialize   = deserialize >>= return . BS.toStrict

instance Loggable SomeException

newtype Raw= Raw BS.ByteString deriving (Read,Show)
instance Loggable Raw where
  serialize (Raw str)= lazyByteString str
  deserialize= Raw <$> do
        s <- notParsed
        BS.length s `seq` return s  --force the read till the end 

-- data Recover= False | True {-  Restore -} deriving (Show,Eq)
-- recover log= let r =recover log in r== True    --   ||  r== Restore
