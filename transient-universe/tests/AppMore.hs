-- More applicative shapes, three remote nodes (n1, n2, n3). APPWAIT_CASE selects the shape:
--   right  t1 <*> (t2 <*> t3)           nested on the right
--   four   t1 <*> t2 <*> t3 <*> t4      four terms (t4 in n1)
--   twice  two applicatives in sequence
--   mono   t1 <> t2 <> t3               Semigroup of Cloud (derived, does not use the applicative node)
--   num    t1 + t2 * t3                 Num of Cloud (derived)
--   newop  t1 <+> t2 <+> t3            an operator defined once for any Applicative
--   monoA  liftA2 (<>) ...              the same with (<>) defined by the applicative of Cloud
-- APPWAIT_D="d1,d2,d3,d4" are the delays of the terms in microseconds: the order of termination.
-- After the applicative, there is a call to each node.
module Main where

import Transient.Base
import Transient.Move
import Transient.Move.Utils (initNode, inputNodes)
import Control.Applicative
import Control.Monad (void)
import Control.Concurrent (threadDelay)
import System.Environment (lookupEnv)

-- | A new binary operator, written once for any 'Applicative': 'Cloud' inherits it from 'TransIO'.
(<+>) :: (Applicative f, Semigroup a) => f a -> f a -> f a
(<+>) = liftA2 (<>)

main :: IO ()
main = void $ keep $ initNode $ inputNodes <|> do
  local $ option "go" "run the test"
  [_, n1, n2, n3] <- local getNodes
  c  <- localIO $ maybe "right" id <$> lookupEnv "APPWAIT_CASE"
  ds <- localIO $ maybe [100000, 200000, 300000, 400000] (\s -> read ("[" <> s <> "]")) <$> lookupEnv "APPWAIT_D"

  let term n i = runAt n (localIO $ do threadDelay (ds !! (i - 1)); putStrLn $ "TERM" <> show i <> " executed"; return (i :: Int))
      termL n i = fmap (: []) (term n i)

  r <- case c of
    "right" -> (\a (b, c') -> [a, b, c']) <$> term n1 1 <*> ((,) <$> term n2 2 <*> term n3 3)
    "four"  -> (\a b c' e -> [a, b, c', e]) <$> term n1 1 <*> term n2 2 <*> term n3 3 <*> term n1 4
    "twice" -> do x <- (\a b -> [a, b]) <$> term n1 1 <*> term n2 2
                  y <- (\a b -> [a, b]) <$> term n3 3 <*> term n1 4
                  return (x ++ y)
    "monoA" -> liftA2 (<>) (liftA2 (<>) (termL n1 1) (termL n2 2)) (termL n3 3)   -- (<>) defined with the applicative of Cloud
    "num"   -> fmap (: []) (term n1 1 + term n2 2 * term n3 3)                    -- derived Num: 1 + 2*3 = 7
    "newop" -> (termL n1 1 <+> termL n2 2) <+> termL n3 3                          -- a new operator, defined once for any Applicative
    _       -> termL n1 1 <> termL n2 2 <> termL n3 3

  localIO $ putStrLn $ "RESOLVED " <> show r
  r1 <- runAt n1 $ localIO $ do putStrLn $ "AFTER AT N1 " <> show r; return r
  localIO $ putStrLn $ "BACK FROM N1 " <> show r1
  r2 <- runAt n2 $ localIO $ do putStrLn $ "AFTER AT N2 " <> show r; return r
  localIO $ putStrLn $ "BACK FROM N2 " <> show r2
  r3 <- runAt n3 $ localIO $ do putStrLn $ "AFTER AT N3 " <> show r; return r
  localIO $ putStrLn $ "BACK FROM N3 " <> show r3
  localIO $ putStrLn "TEST END"
