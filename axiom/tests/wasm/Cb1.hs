{-# LANGUAGE CPP, JavaScriptFFI #-}
-- checkboxes (two boxes with getCheckBoxes)
module Main where

import Prelude hiding (div)
import Transient.Base (keep, TransIO)
import GHCJS.HPlay.View
import Data.String

page :: TransIO ()
page = do
  rs <- render $ br ++> br ++> getCheckBoxes (
                  ((setCheckBox False "Red" <++ b "red") `fire` OnClick)
               <> ((setCheckBox True "Green" <++ b "green") `fire` OnClick))
  render $ rawHtml $ fromString " returns: " <> b (show rs)

main :: IO ()
main = keep page >> return ()

#ifdef BROWSER
foreign export javascript "hs_start" main :: IO ()
#endif
