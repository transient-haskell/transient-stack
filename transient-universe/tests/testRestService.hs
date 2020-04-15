#!/usr/bin/env execthirdlinedocker.sh
--  info: use sed -i 's/\r//g' file if report "/usr/bin/env: ‘execthirdlinedocker.sh\r’: No such file or directory"
-- LIB="/home/vsonline/workspace" && runghc   -DDEBUG  -i${LIB}/transient/src -i${LIB}/transient-universe/src -i${LIB}/transient-universe-tls/src -i${LIB}/axiom/src   $1  ${2} ${3}

-- LIB="/home/vsonline/workspace" && ghc     -i${LIB}/transient/src -i${LIB}/transient-universe/src -i${LIB}/transient-universe-tls/src -i${LIB}/axiom/src   $1 && ./`basename $1 .hs` ${2} ${3}


{-# LANGUAGE ScopedTypeVariables, OverloadedStrings   #-}
module Main where

import Transient.Base
import Transient.Move.Internals
import Transient.Move.Services

import Transient.Move.Utils
import Control.Applicative
import Data.Monoid

import Control.Monad.State

import Data.Aeson

import qualified Data.ByteString as BS




getRESTReq= "GET /todos/$1 HTTP/1.1\r\n"
         <> "Host: $hostnode\r\n" 
         <> "\r\n" :: String

         
postRESTReq=  "POST /todos HTTP/1.1\r\n"
           <> "HOST: $hostnode\r\n"
           <> "Content-Type: application/json\r\n\r\n" 
           <>"{\"id\": $1,\"userId\": $2,\"completed\": $3,\"title\":$4}"


postRestService= [("service","post"),("type","HTTP")
                 ,("nodehost","jsonplaceholder.typicode.com")
                 ,("nodeport","80"),("HTTPstr",postRESTReq)]
getRestService = [("service","get"),("type","HTTP")
                 ,("nodehost","jsonplaceholder.typicode.com")
                ,("nodeport","80"),("HTTPstr",getRESTReq)]



type Literal = BS.ByteString  -- appears with " "
type Symbol= String  -- no "  when translated 

main= keep $ initNode $ do
      local $ option ("go" ::String)  "go"

      
      r <-callService postRestService (10 :: Int,4 :: Int, "true" :: Symbol ,  "title alberto" :: Literal)  :: Cloud Value
      local $ do
          HTTPHeaders _ headers <- getState <|> error "no headers. That should not happen" 
          liftIO $ print headers 
          liftIO $ print ("POST RESPONSE:",r)
 
      
      r <- callService getRestService (1::Int)
      local $ do
          HTTPHeaders _ headers <- getState <|> error "no headers. That should not happen"
          liftIO $ do
              putStrLn "HEADERS"
              print headers
              putStrLn "RESULT"
              print  ("GET RESPONSE:",r :: Value)
      
      
      r <- callService getRestService (2::Int)
      local $ do
          HTTPHeaders _ headers <- getState <|> error "no headers. That should not happen"
          liftIO $ do
              putStrLn "HEADERS"
              print headers
              putStrLn "RESULT"
              print  ("GET RESPONSE:",r :: Value)