#!/usr/bin/env execthirdlinedocker.sh
--  info: use "sed -i 's/\r//g' yourfile" if report "/usr/bin/env: ‘execthirdlinedocker.sh\r’: No such file or directory"
-- LIB="/home/vsonline/workspace/transient-stack" && runghc -DDEBUG -i${LIB}/transient/src -i${LIB}/transient-universe/src  -i${LIB}/transient-universe-tls/src -i${LIB}/axiom/src   $1  ${2} ${3}


{-# LANGUAGE ScopedTypeVariables, OverloadedStrings   #-}
module Main where

import Transient.Base
import Transient.Parse
import Transient.Move.Internals
import Transient.Move.Services
import Transient.TLS
import Data.List(nub,sort)
import Data.Char(isNumber)
import Data.Monoid
import Control.Monad.State
import qualified Data.ByteString.Lazy.Char8 as BS
import Control.Applicative
import Data.Typeable

getGoogleService = [("service","google"),("type","HTTPS")
                   ,("nodehost","www.google.com")
                   ,("HTTPstr",getGoogle)]

getGoogle= "GET / HTTP/1.1\r\n"
         <> "Host: $hostnode\r\n" 
         <> "\r\n" :: String

getGoogleSearchService = [("service","google"),("type","HTTP")
        ,("nodehost","www.google.com")
        ,("HTTPstr","GET /search?q=+$1+site:hackage.haskell.org HTTP/1.1\r\nHost: $hostnode\r\n\r\n" )]


main=do
  initTLS

  keep'  $ do
    Raw r <-unCloud $ callService getGoogleService ()

    liftIO $ do putStr "100 chars of web page: "; print $ BS.take 100 r
    empty
    Pack packages <- unCloud $ callService getGoogleSearchService ("Control.Monad.State" :: BS.ByteString) 

    liftIO $ do putStr "Search results: " ; print packages

newtype Pack= Pack [BS.ByteString] deriving (Read,Show,Typeable)
instance Loggable Pack where
    serialize (Pack p)= undefined
    
    deserialize= Pack . reverse . sort . nub  <$> (many $ do
        tDropUntilToken "hackage.haskell.org/package/" 
        r <- tTakeWhile (\c -> not (isNumber c) && c /= '&' && c /= '/') 
        let l= BS.length r -1
        return $ if ( BS.index r l == '-') then BS.take l r else r)
 