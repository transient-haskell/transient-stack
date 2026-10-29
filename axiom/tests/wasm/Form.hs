{-# LANGUAGE CPP, OverloadedStrings, JavaScriptFFI #-}
-- A form: a text box and a button joined with <**. The click executes the box again, which reads the page, and continues with its content.
module Main where

import Prelude hiding (div)
import Transient.Base (keep, TransIO, (<**))
import GHCJS.HPlay.View

page :: TransIO ()
page = do
  name <- render $ (div <<< inputString (Just "world")) <** (inputSubmit ("greet" :: String) `fire` OnClick)
  render $ rawHtml (p ("hello " ++ name))

main :: IO ()
main = keep page >> return ()

#ifdef BROWSER
foreign export javascript "hs_start" main :: IO ()
#endif
