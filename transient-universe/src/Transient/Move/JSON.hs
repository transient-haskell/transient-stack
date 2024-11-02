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

import Control.Monad.State
import Control.Applicative

import Data.Typeable

serializeToJSON :: ToJSON a => a -> Builder
serializeToJSON = lazyByteString . encode

deserializeJSON :: FromJSON a => TransIO a
deserializeJSON = do
  modify $ \s -> s{execMode=Serial}
  -- tr ("BEFOFE DECODE")
  s <- jsElem
  tr ("decode", s)

  case eitherDecode s of
    Right x -> return x
    Left err -> empty
  
jsElem :: TransIO BS.ByteString -- just delimites the json string, do not parse it
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

instance FromJSON a => Read a where
  readsPrec _ ss = error "Read FromJSON: not implemented"
    --  let (s,rest)= fragment $ BS.pack ss
    --      mr = decode s
    --  in if isJust mr then [(fromJust mr, BS.unpack rest)] else []

instance {-# OVERLAPPABLE #-} (Typeable a, ToJSON a, FromJSON a) => Loggable (AsJSON a) where
  serialize (AsJSON a)= serializeToJSON a
  deserialize = AsJSON <$> deserializeJSON

newtype AsJSON a= AsJSON a 


-- | to force JSON deserialization
instance FromJSON a => FromJSON  (AsJSON a) where
   parseJSON val= AsJSON <$> parseJSON val

instance ToJSON a => ToJSON (AsJSON a) where
  toJSON (AsJSON x)= toJSON x