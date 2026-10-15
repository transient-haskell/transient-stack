{-# LANGUAGE OverloadedStrings, JavaScriptFFI #-}
module Main where
import Prelude hiding (div, id)
import GHCJS.Perch

ui :: Perch
ui = div ! atr "id" "box" $ do
  p ("hello perch" :: String)
  addEvent' (button ("go" :: String) ! atr "id" "btn") Click $ \_ -> do
    body <- getBody
    _ <- build (p ("clicked" :: String)) body
    return ()

main :: IO ()
main = do
  body <- getBody
  _ <- build ui body
  return ()

foreign export javascript "hs_start" main :: IO ()
