#!/usr/bin/env ./execthirdline.sh

-- set -e &&  port=`echo ${3} | awk -F/ '{print $(3)}'` && docker run -it -p ${port}:${port} -v /c/Users/magocoal/OneDrive/Haskell/devel:/devel testtls  bash -c "cd /devel/transient-universe-tls/tests/; runghc  -j2 -isrc -i/devel/transient/src -i/devel/transient-universe/src -i/devel/transient-universe-tls/src -i/devel/ghcjs-hplay/src -i/devel/ghcjs-perch/src $1 $2 $3 $4"

{-# LANGUAGE   CPP,NoMonomorphismRestriction  #-}

module Main where

import Prelude hiding (div,id)
import Transient.Base



--import GHCJS.HPlay.Cell
--import GHCJS.HPlay.View
#ifdef ghcjs_HOST_OS
   hiding (map, input,option)
#else
   hiding (map, option,input)
#endif

import Transient.Base
import Transient.Move
import Transient.Move.Utils
import Transient.EVars
import Transient.Indeterminism
import Transient.TLS

import Control.Applicative
import qualified Data.Vector as V
import qualified Data.Map as M
import Transient.MapReduce
import Control.Monad.IO.Class
import Data.String
import Data.Monoid
import qualified Data.Text as T
#ifdef ghcjs_HOST_OS
import qualified Data.JSString as JS hiding (span,empty,strip,words)
#endif

import Control.Concurrent.MVar
import System.IO.Unsafe

main= do
     let numNodes = 3
     keep' . runCloud $ do
              runTestNodes [2000 .. 2000 + numNodes - 1]
              r <- mclustered $ local $ do
                      ev <- newEVar
                      readEVar ev <|> (writeEVar ev "hello" >> empty)
              localIO $ print r

main2= do
--  initTLS
  node1 <- createNode "192.168.99.100" 8080
--  keep $ initNode $ do
--    local $ option "s" "start"
  node2 <- createNode "localhost" 2001
  runCloudIO $ do

    listen node1 <|> listen node2 <|> return ()
    my <- local getMyNode
    r <-  runAt my (local (return "hello")) <|> runAt node1 (local (return "world"))
    localIO $ print r


test :: Cloud ()
test= onServer $ do
   local $ option "t" "do test"

   r <- wormhole (Node "localhost" 8080 (unsafePerformIO $ newMVar  []) []) $ do
      teleport
      p <- localIO $ print "ping" >> return "pong"
      teleport
      return p
   localIO $ print r

