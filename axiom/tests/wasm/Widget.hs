{-# LANGUAGE CPP, OverloadedStrings, JavaScriptFFI #-}
-- A text box that raises the event: its code runs in the continuation, reads the page and returns the content.
module Main where

import Prelude hiding (div)
import Transient.Base (keep, TransIO)
import GHCJS.HPlay.View

page :: TransIO ()
page = do
  name <- render $ inputString (Just "world") `fire` OnChange
  render $ rawHtml (p ("hello " ++ name))

main :: IO ()
main = keep page >> return ()

#ifdef BROWSER
foreign export javascript "hs_start" main :: IO ()
#endif
