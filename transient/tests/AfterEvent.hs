-- (<**): an event in the second term continues with the result of the first term, which is not executed again.
-- The mailbox sends "world" to the second term after 0.3 s. Expected, in order:
--   RESULT hello        the first execution
--   mb world            the event is received by the second term
--   RESULT hello        the continuation of (<**) gets "hello", not "world"
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
    x <- (abduce >> liftIO (threadDelay 300000) >> putMailbox "world" >> empty)
         <|> (return "hello" <** (do w <- getMailbox :: TransIO String; liftIO (say ("mb " ++ w))))
    liftIO $ say ("RESULT " ++ x)
  return ()
