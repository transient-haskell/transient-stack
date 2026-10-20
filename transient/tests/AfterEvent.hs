-- (<**): an event in the second term executes the first term again and continues with its result.
-- The mailbox sends "w1" and "w2" to the second term. Expected, in order:
--   ma2, RESULT2 y      no event in the second term: the first term is executed once
--   ma                  the first term, first execution
--   RESULT hello
--   mb w1               the first event is received by the second term
--   ma                  the first term is executed again
--   RESULT hello        the continuation of (<**) gets "hello", not "w1"
--   mb w2, ma, RESULT hello   the same with the second event
-- usage: aftertest.sh
import Transient.Base
import Transient.Mailboxes
import Control.Monad.IO.Class
import Control.Applicative
import Control.Concurrent
import System.Environment

main :: IO ()
main = do
  [out] <- getArgs
  let say s = appendFile out (s ++ "\n")
  keep $ do
    -- without an event in the second term, the first term is executed once
    y <- (liftIO (say "ma2") >> return "y") <** return ()
    liftIO $ say ("RESULT2 " ++ y)
    x <- (abduce >> liftIO (threadDelay 300000) >> putMailbox "w1" >> liftIO (threadDelay 300000) >> putMailbox "w2" >> empty)
         <|> ((liftIO (say "ma") >> return "hello") <** (do w <- getMailbox :: TransIO String; liftIO (say ("mb " ++ w))))
    liftIO $ say ("RESULT " ++ x)
  return ()
