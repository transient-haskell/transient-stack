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

#ifdef BROWSER
foreign export javascript "hs_start" hs_start :: IO ()
hs_start :: IO ()
hs_start = keep (initNode app) >> return ()
main :: IO ()
main = return ()
#else
main :: IO ()
main = keep (initNode app) >> return ()
#endif
