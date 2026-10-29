{-# LANGUAGE CPP, OverloadedStrings, JavaScriptFFI #-}
-- the input of the chat of distributedApps: the name has a default value with an alternative
module Main where

import Prelude hiding (div)
import Transient.Base (keep, TransIO, (<**))
import GHCJS.HPlay.View
import GHCJS.HPlay.Cell
import Control.Applicative

page :: TransIO ()
page = do
  let entry= boxCell "msg" ! atr "size" "60"
  (nick,text) <- render $  (,) <$> ((getString (Just "anonymous") ! atr "size" "10") `fire` OnChange <|> return "anonymous")
                                <*> mk entry Nothing `fire` OnChange
                                <** inputSubmit ("send" :: String)
                                <++ br
  render $ rawHtml (p (nick ++ "> " ++ text))

main :: IO ()
main = keep page >> return ()

#ifdef BROWSER
foreign export javascript "hs_start" main :: IO ()
#endif
