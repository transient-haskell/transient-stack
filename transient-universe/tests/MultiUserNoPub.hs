-- Multi-user workflow (from mainauction in flow.hs): the endpoint "enterguess" is created dynamically by a
-- session (user 1) and invoked by another session (user 2) through publish / published.
--   multiuser -p start/127.0.0.1/9200
module Main where

import Transient.Base
import Transient.Move
import Transient.Move.Web
import Transient.Move.Utils (initNode)
import Control.Applicative
import Control.Monad (void)

main :: IO ()
main = void $ keep $ initNode $ do
  name <- minput "enterw" ("enter your name" :: String) :: Cloud String
  guessgame name
  where
  guessgame name = do
    minput "guessgame" ("play guessgame" :: String) :: Cloud ()
    lock  <- minput "enterlock" (name <> ": lock a number to guess it") :: Cloud Int
    guess <- publish True "lock" $ minput "enterguess" ("guess the number entered by: " <> name) :: Cloud Int
    localIO $ putStrLn $ "GUESS " <> name <> " " <> show (lock, guess)
    minput "entered" [("entered number", show guess), ("success", show (lock == guess))] :: Cloud ()
