#!/usr/bin/env execthirdlinedocker.sh
--  info: use sed -i 's/\r//g' file if report "/usr/bin/env: ‘execthirdlinedocker.sh\r’: No such file or directory"
-- LIB="/projects/transient-stack" && mkdir -p static && ghcjs -DDEBUG  --make   -i${LIB}/transient/src -i${LIB}/transient-universe/src  -i${LIB}/axiom/src   $1 -o static/out && runghc   -DDEBUG  -i${LIB}/transient/src -i${LIB}/transient-universe/src -i${LIB}/axiom/src   $1 ${2} ${3}
{-# LANGUAGE CPP #-}
import GHCJS.HPlay.View
import Control.Applicative
import Transient.Base
import Transient.Move.Internals
import Control.Monad.IO.Class
#ifndef ghcjs_HOST_OS
import qualified Network.WebSockets.Connection          as WS
import Data.IORef
import qualified Data.ByteString.Lazy.Char8             as BS
#endif
main =  keep $ initNode action

action :: Cloud ()
action =   do
  local $ setRState (0::Int)
  onAll $ liftIO $ print ("ACTION" ::String)
  local $ render $ wbutton "hello" (toJSString "try this")

  r <- local $ getRState <|> return 0
  local $ setRState $ r + 1
  atRemote $ local $ do
      liftIO $ print r 

  local $ render $ wraw (h1 (r :: Int))



