{-# LANGUAGE CPP, OverloadedStrings, JavaScriptFFI #-}
-- Rendering without events: each line is a `render`, in the TransIO monad.
module Main where

import Prelude hiding (div)
import Transient.Base (keep, TransIO)
import GHCJS.HPlay.View

page :: TransIO ()
page = do
  render $ rawHtml (p ("one" :: String))
  n <- return (2 :: Int)
  render $ div <<< rawHtml (p ("two " ++ show n))
  render $ rawHtml (p ("three" :: String))

main :: IO ()
main = keep page >> return ()

#ifdef BROWSER
foreign export javascript "hs_start" main :: IO ()
#endif
