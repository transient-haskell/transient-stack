{-# LANGUAGE CPP, OverloadedStrings, JavaScriptFFI #-}
-- a text area and a button (as the map-reduce widget of distributedApps): the button gives the content of the area
module Main where

import Prelude hiding (div)
import Transient.Base (keep, TransIO, (<**))
import GHCJS.HPlay.View
import Data.String

page :: TransIO ()
page = do
  c <- render $ h1 ("Area" :: String) ++>
                p ("Return the frequencies" :: String) ++>
                textArea "" ! atr "placeholder" "enter the content"
                           ! atr "rows" "4"
                           ! atr "cols" "80"
                <++ br
                <** inputSubmit ("send" :: String) `fire` OnClick
                <++ br
  render $ rawHtml (p ("got: " ++ c))

main :: IO ()
main = keep page >> return ()

#ifdef BROWSER
foreign export javascript "hs_start" main :: IO ()
#endif
