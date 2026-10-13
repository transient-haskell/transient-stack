-- Applicative of two REST inputs (minput) and a third endpoint that publishes the result.
--   appminput -p start/127.0.0.1/9100
--   curl http://127.0.0.1:9100/t1/hello ; curl http://127.0.0.1:9100/t2/world   (in either order)
-- APPMINPUT_CASE=derived uses (<>) of Cloud (derived); the default is liftA2 (<>) (the applicative of Cloud)
module Main where

import Transient.Base
import Transient.Move
import Transient.Move.Web
import Transient.Move.Utils (initNode)
import Control.Applicative
import Control.Monad (void)
import System.Environment (lookupEnv)

main :: IO ()
main = void $ keep $ initNode $ do
  derived <- localIO $ maybe False (== "derived") <$> lookupEnv "APPMINPUT_CASE"
  let a = minput "t1" ("first"  :: String) :: Cloud String
      b = minput "t2" ("second" :: String) :: Cloud String
  r <- if derived then a <> b else liftA2 (<>) a b
  localIO $ putStrLn $ "MINPUT RESOLVED " <> r
  minput "final" ("RESULT" :: String, r) :: Cloud ()
