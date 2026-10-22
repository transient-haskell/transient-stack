{-# LANGUAGE CPP, OverloadedStrings, JavaScriptFFI #-}
-- (with a menu of links before) the text area and the button of Area.hs inside a Cloud, in a node: the server and the browser run the same source
module Main where

import Prelude hiding (div)
import Transient.Base (keep, (<**))
import Transient.Move
import GHCJS.HPlay.View
import Control.Applicative

app :: Cloud ()
app = do
  local . render . rawHtml $ do
        h1 ("Demo" :: String)
        br; br
  op <- local . render $ wlink ("one" :: String) (b ("link-one" :: String)) <++ (" " :: Perch) <|>
                         wlink "two" (b ("link-two" :: String))
  case op of
    "one" -> areaApp
    _ -> empty

areaApp :: Cloud ()
areaApp = onBrowser $ do
  c <- local . render $ h1 ("Area" :: String) ++>
                p ("Return the frequencies" :: String) ++>
                textArea "" ! atr "placeholder" "enter the content"
                           ! atr "rows" "4"
                           ! atr "cols" "80"
                <++ br
                <** inputSubmit ("send" :: String) `fire` OnClick
                <++ br
  r <- atRemote $ do
         localIO $ print c
         return (length c)
  local . render $ rawHtml (p ("got: " ++ c ++ " " ++ show r))
  empty

main :: IO ()
main = keep (initNode (app <|> thelink)) >> return ()

#ifdef BROWSER
foreign export javascript "hs_start" main :: IO ()
#endif

thelink :: Cloud ()
thelink = do
  local . render $ rawHtml (a ! href "http://x.org" $ ("source code" :: String))
  empty
