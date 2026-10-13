{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverlappingInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE CPP, LambdaCase #-}

module Transient.Move.JSON where

import Transient.Internals
import Transient.Loggable
import Transient.Parse
import Data.Aeson
import Data.Maybe
import Data.ByteString.Builder
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Lazy.Char8 as BS
import Data.Default
import Control.Monad.State
import Control.Applicative
import Data.Typeable

-- | Encode a value to JSON and wrap it in a lazy 'Builder'.
serializeToJSON :: ToJSON a => a -> Builder
serializeToJSON = lazyByteString . encode

-- | Parse the next JSON element from the parse stream and decode it.
-- Fails with 'empty' if decoding produces a 'Left'.
deserializeJSON :: FromJSON a => TransIO a
deserializeJSON = do
  modify $ \s -> s{execMode=Serial}
  s <- jsElem
  tr ("decode", s)

  case eitherDecode s of
    Right x -> return x
    Left err -> empty
  
-- | Consume one top-level JSON value from the stream and return it as a raw bytestring
-- (object, array, or atom).  Does not fully parse — just delimits the extent.
jsElem :: TransIO BS.ByteString
jsElem = dropSpaces >> ( jsonObject <|> array <|> atom)
    where
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
         tTakeWhile (\c -> c /= '}' && c /= ']' && c /= ',' && c /= '/' && c /= ' ')

instance {-# OVERLAPPING #-} Loggable Value where
  serialize = serializeToJSON
  deserialize = deserializeJSON

instance {-# OVERLAPPABLE #-} ToJSON a => Show a where
  show = BS.unpack . toLazyByteString . serializeToJSON . toJSON

instance (Typeable a,FromJSON a) => Read a where
  readsPrec _ ss =  error $ "Read FromJSON: not implemented:' " <> show (typeOf (undefined :: a)) <>"'"

instance {-# OVERLAPPABLE #-} (Show a, Read a,Typeable a, ToJSON a, FromJSON a) => Loggable (AsJSON a) where
  serialize (AsJSON a)= serializeToJSON a
  deserialize = AsJSON <$> deserializeJSON

-- | Newtype wrapper that gives any 'ToJSON'\/'FromJSON' type a 'Loggable' instance
-- using JSON serialization instead of the default @Show@\/@Read@.
newtype AsJSON a= AsJSON a

instance ToJSON a => Show (AsJSON a) where 
   show (AsJSON x)= BS.unpack . toLazyByteString . serializeToJSON . toJSON $ x

instance Read (AsJSON a) where
   readsPrec _ ss = error "Read FromJSON: not implemented"

-- | to force JSON deserialization
instance FromJSON a => FromJSON  (AsJSON a) where
   parseJSON val= AsJSON <$> parseJSON val

instance ToJSON a => ToJSON (AsJSON a) where
  toJSON (AsJSON x)= toJSON x

instance Default a => Default (AsJSON a) where  def= AsJSON def