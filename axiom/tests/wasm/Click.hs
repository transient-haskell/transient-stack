{-# LANGUAGE CPP, OverloadedStrings, JavaScriptFFI #-}
-- The smallest event: a button, and a widget after it that is drawn when the button is clicked. No input to read.
module Main where

import Prelude hiding (div)
import GHCJS.HPlay.View

page :: Widget ()
page = do
  _ <- wbutton (1 :: Int) "go"
  rawHtml (p ("clicked" :: String))

main :: IO ()
main = runBody page >> return ()

#ifdef BROWSER
foreign export javascript "hs_start" main :: IO ()
#endif
