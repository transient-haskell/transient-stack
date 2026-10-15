{-# LANGUAGE CPP, OverloadedStrings, JavaScriptFFI #-}
-- A client-side form: a text box and a button. The click reevaluates the widget and the rest of the computation.
module Main where

import Prelude hiding (div)
import GHCJS.HPlay.View

greeting :: Widget ()
greeting = do
  name <- (div <<< inputString (Just "world")) <* (inputSubmit ("greet" :: String) `fire` OnClick)
  rawHtml (p ("hello " ++ name))

main :: IO ()
main = runBody greeting >> return ()

#ifdef BROWSER
foreign export javascript "hs_start" main :: IO ()
#endif
