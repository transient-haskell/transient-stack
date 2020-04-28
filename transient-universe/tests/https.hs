#!/usr/bin/env execthirdlinedocker.sh
--  info: use "sed -i 's/\r//g' yourfile" if report "/usr/bin/env: ‘execthirdlinedocker.sh\r’: No such file or directory"
-- LIB="/home/vsonline/workspace/transient-stack" && runghc    -i${LIB}/transient/src -i${LIB}/transient-universe/src -i${LIB}/transient/src -i${LIB}/transient-universe-tls/src -i${LIB}/axiom/src   $1  ${2} ${3}

-- LIB="/home/vsonline/workspace/transient-stack" && ghc  -DDEBUG   -i${LIB}/transient/src -i${LIB}/transient-universe/src    $1 && ./`basename $1 .hs` ${2} ${3}


{-# LANGUAGE ScopedTypeVariables, OverloadedStrings   #-}
module Main where

import Transient.Base
import Transient.Move.Internals
import Transient.Move.Services
import Transient.TLS
import Transient.Move.Utils
import Control.Applicative
import Data.Monoid

import Control.Monad.State

import Data.Aeson

import qualified Data.ByteString as BS




getGoogleService = [("service","google"),("type","HTTPS")
                   ,("nodehost","www.google.com")
                   ,("HTTPstr",getGoogle)]

getGoogle= "GET / HTTP/1.1\r\n"
         <> "Host: $hostnode\r\n" 
         <> "\r\n" :: String

type Literal = BS.ByteString  -- appears with " "
type Symbol= String  -- no "  when translated 



main= keep' $ do
    initTLS
    r <-runCloud $ callService getGoogleService ():: TransIO Raw

    liftIO $ print r
