#!/usr/bin/env ./execthirdline.sh

-- set -e &&  port=`echo ${3} | awk -F/ '{print $(3)}'` && docker run -it -p ${port}:${port} -v /c/Users/magocoal/OneDrive/Haskell/devel:/devel testtls  bash -c "cd /devel/transient-universe-tls/tests/; runghc  -j2 -isrc -i/devel/transient/src -i/devel/transient-universe/src -i/devel/transient-universe-tls/src -i/devel/ghcjs-hplay/src -i/devel/ghcjs-perch/src $1 $2 $3 $4"

-- compile it with ghcjs and  execute it with runghc
-- set -e && port=`echo ${3} | awk -F/ '{print $(3)}'` && docker run -it -p ${port}:${port} -v $(pwd):/work agocorona/transient:05-02-2017  bash -c "runghc /work/${1} ${2} ${3}"

{- execute as ./api.hs  -p start/<docker ip>/<port>

 invoque: curl http://<docker ip>/<port>/api/hello/john
          curl http://<docker ip>/<port>/api/hellos/john
          curl --data "birthyear=1905&press=%20OK%20" http://1
92.168.99.100:8080/api/
-}
{-# LANGUAGE ScopedTypeVariables #-}
import Transient.Internals
import Transient.TLS
import Transient.Move
import Transient.Move.Utils
import Transient.Logged
import Transient.Indeterminism
import Control.Applicative
import Control.Concurrent(threadDelay)
import Control.Monad.IO.Class
import qualified Data.ByteString.Lazy.Char8 as BS
import Control.Exception hiding (onException)

main = do
  initTLS
  keep' $ initNode   apisample

apisample= api $ gets <|> posts --  <|> err
    where
    posts= do
       received POST
       postParams <- param
       liftIO $ print (postParams :: PostParams)
       let msg= "received" ++ show postParams
           len= length msg
       return $ BS.pack $ "HTTP/1.0 200 OK\nContent-Type: text/plain\nContent-Length: "++ show len
                   ++ "\nConnection: close\n\n" ++ msg

    gets= received GET >>  hello <|> hellostream

    hello= do
        received "hello"
        name <- param
        let msg=  "hello " ++ name ++ "\n"
            len= length msg
        return $ BS.pack $ "HTTP/1.0 200 OK\nContent-Type: text/plain\nContent-Length: "++ show len
                 ++ "\nConnection: close\n\n" ++ msg

    hellostream = do
        received "hellos"
        name <- param

        threads 0 $ header <|> stream name
        where
        header=async $ return $ BS.pack $
                       "HTTP/1.0 200 OK\nContent-Type: text/plain\nConnection: close\n\n"++
                       "here follows a stream\n"
        stream name= do
            i <-  choose [1 ..]
            liftIO $ threadDelay 1000000
            return . BS.pack $ " hello " ++ name ++ " "++ show i

--    err= return $ BS.pack $ "HTTP/1.0 404 Not Founds\nContent-Length: 0\nConnection: close\n\n"


