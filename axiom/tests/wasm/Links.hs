{-# LANGUAGE CPP, JavaScriptFFI #-}
-- links with a text after each one, as the menu of distributedApps (wlink .. <++ .. <|> wlink .. <++ .. )
module Main where

import Prelude hiding (div)
import Transient.Base (keep, TransIO)
import GHCJS.HPlay.View
import Data.String

page :: TransIO ()
page = do
  op <- render $ wlink "A" (b "link-a") <++ fromString "   " <|>
                 wlink "B" (b "link-b") <++ fromString "   " <|>
                 wlink "C" (b "link-c")
  render $ rawHtml $ fromString " chose: " <> b (show op)

main :: IO ()
main = keep page >> return ()

#ifdef BROWSER
foreign export javascript "hs_start" main :: IO ()
#endif
