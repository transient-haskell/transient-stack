{-# LANGUAGE CPP, OverloadedStrings, JavaScriptFFI #-}
-- the input of the chat inside Cloud (local . render), node and browser from the same source
module Main where

import Prelude hiding (div)
import Transient.Base (keep, (<**))
import Transient.Move
import GHCJS.HPlay.View
import GHCJS.HPlay.Cell
import Control.Applicative

app :: Cloud ()
app = onBrowser $ do
  let entry= boxCell "msg" ! atr "size" "60"
  (nick,text) <- local . render $  (,) <$> ((getString (Just "anonymous") ! atr "size" "10") `fire` OnChange <|> return "anonymous")
                                       <*> mk entry Nothing `fire` OnChange
                                       <** inputSubmit ("send" :: String)
                                       <++ br
  local . render $ rawHtml (p (nick ++ "> " ++ text))
  empty

main :: IO ()
main = keep (initNode app) >> return ()

#ifdef BROWSER
foreign export javascript "hs_start" main :: IO ()
#endif
