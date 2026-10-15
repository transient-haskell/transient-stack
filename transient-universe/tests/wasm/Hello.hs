{-# LANGUAGE CPP, ForeignFunctionInterface, JavaScriptFFI, ScopedTypeVariables #-}
module Main where
import Transient.Base
import Transient.Move
import Transient.Move.Utils
import Control.Monad.IO.Class

-- the same program in the server and in the browser: the browser asks the server
app :: Cloud ()
app = onBrowser $ do
  r <- atRemote $ do
         localIO $ putStrLn "SERVER: request received"
         return ("hello from the server" :: String)
  localIO $ putStrLn ("BROWSER: " ++ r)

main :: IO ()
main = keep (initNode app) >> return ()

#ifdef BROWSER
-- the wasm is a reactor: main does not run, JS calls hs_start
foreign export javascript "hs_start" main :: IO ()
#endif
