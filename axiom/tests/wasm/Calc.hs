{-# LANGUAGE CPP, OverloadedStrings, JavaScriptFFI #-}
-- Computations in the Widget monad without rendering: the bind, liftIO, the applicative and the alternative.
module Main where

import Prelude hiding (div)
import Control.Applicative
import Control.Monad.IO.Class
import GHCJS.HPlay.View
import System.IO

calc :: Widget Int
calc = do
  x <- return 2
  y <- liftIO (return 3)
  z <- (empty <|> return 10)
  w <- (+) <$> return 1 <*> return 4
  return (x + y + z + w)

main :: IO ()
main = do
  hSetBuffering stdout NoBuffering
  putStrLn "START"
  r <- runBody calc
  putStrLn ("RESULT " ++ show r)

#ifdef BROWSER
foreign export javascript "hs_start" main :: IO ()
#endif
