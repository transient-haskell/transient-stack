{-# LANGUAGE CPP, OverloadedStrings, JavaScriptFFI #-}
-- The smallest event: a button, and a render after it that is drawn when the button is clicked. No input to read.
module Main where

import Prelude hiding (div)
import Transient.Base (TransIO)
import GHCJS.HPlay.View

page :: TransIO ()
page = do
  _ <- render $ wbutton (1 :: Int) "go"
  render $ rawHtml (p ("clicked" :: String))

main :: IO ()
main = runBody (Widget page) >> return ()

#ifdef BROWSER
foreign export javascript "hs_start" main :: IO ()
#endif
