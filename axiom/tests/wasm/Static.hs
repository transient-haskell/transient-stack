{-# LANGUAGE CPP, OverloadedStrings, JavaScriptFFI #-}
-- Rendering without events: the HTML of consecutive widgets of a bind is drawn in order.
module Main where

import Prelude hiding (div)
import GHCJS.HPlay.View

page :: Widget ()
page = do
  rawHtml (p ("one" :: String))
  n <- return (2 :: Int)
  div <<< rawHtml (p ("two " ++ show n))
  rawHtml (p ("three" :: String))

main :: IO ()
main = runBody page >> return ()

#ifdef BROWSER
foreign export javascript "hs_start" main :: IO ()
#endif
