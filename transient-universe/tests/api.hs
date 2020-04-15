#!/usr/bin/env execthirdlinedocker.sh

--  runghc    -i../transient/src -i../transient-universe/src  $1  ${2} ${3} 


{- execute as ./tests/api.hs  -p start/<docker ip>/<port>

 invoque: GET:  curl http://<docker ip>/<port>/api/hello/john
                curl http://<docker ip>/<port>/api/hellos/john
          POST: curl http://localhost:8000/api -d "name=Hugh&age=30"
-}

import Transient.Internals
import Transient.Move
import Transient.Move.Utils
import Transient.Indeterminism
import Control.Applicative
import Transient.Logged
import Control.Concurrent(threadDelay)
import Control.Monad.IO.Class
import qualified Data.ByteString.Lazy.Char8 as BS
import qualified Data.ByteString as BSS
import Data.Aeson

main = keep $ initNode   apisample

apisample= api $ do

    gets <|> posts <|> badRequest
    where
    posts= postParams <|> postJSON
    postJSON= try $ do
       received POST    -- both postParams and PostJSON check for POST, so both need `try`, to backtrack
                        -- not necessary if POST is checked once.
       liftIO $ print "AFTER POST"

       received "json"
       liftIO $ print "AFTER JSON"
       json <- param
       liftIO $ print ("JSON received:",json :: Value)
       let msg= "received\n"
       return $ BS.pack $ "HTTP/1.1 200 OK\nContent-Type: text/plain\nContent-Length: "++ show (length msg)
                 ++ "\n\n" ++ msg -- "\nConnection: close\n\n" ++ msg

    postParams= try $ do
       received POST
       received "params"
       postParams <- param
       liftIO $ print (postParams :: PostParams)
       let msg= "received\n"
       return $ BS.pack $ "HTTP/1.1 200 OK\nContent-Type: text/plain\nContent-Length: "++ show (length msg)
                 ++  "\n\n" ++ msg -- "\nConnection: close\n\n" ++ msg

    gets= do
        received GET        -- "GET" is checked once, so no try necessary.
        hello <|> hellostream
    hello= do
        received "hello"
        name <- param
        let msg=  "hello " ++ name ++ "\n"
            len= length msg
        return $ BS.pack $ "HTTP/1.1 200 OK\nContent-Type: text/plain\nContent-Length: "++ show len
                 ++ "\n\n" ++ msg -- "\nConnection: close\n\n" ++ msg


    hellostream = do
        received "hellos"
        name <- param
        header <|> stream name
        
        where
        
        header=async $ return $ BS.pack $
                       "HTTP/1.0 200 OK\nContent-Type: text/plain\nConnection: close\n\n"++
                       "here follows a stream\n"
        stream name= do
            i <- threads 0 $ choose [1 ..]
            liftIO $ threadDelay 100000
            return . BS.pack $ " hello " ++ name ++ " "++ show i
            
    badRequest =  return $ BS.pack $
                       let resp="Bad Request\n\
                         \Usage: GET:  http//host:port/api/hello/<name>, http://host:port/api/hellos/<name>\n\
                         \       POST: http://host:port/api\n"
                       in "HTTP/1.0 400 Bad Request\nContent-Length: " ++ show(length resp)
                         ++"\nConnection: close\n\n"++ resp
                       
                       