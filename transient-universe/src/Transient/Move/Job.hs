module Transient.Move.Job(job, runJobs) where
import Transient.Internals
import Transient.Move.Internals
import Transient.Indeterminism
import Transient.Logged
import qualified Data.ByteString.Char8 as BC
import Control.Monad.IO.Class
import Data.TCache hiding (onNothing)
import qualified Data.TCache.DefaultPersistence as TC

import Control.Applicative
import Data.List


data Jobs= Jobs{pending :: [(Int,BC.ByteString)]}  deriving (Read,Show)
instance TC.Indexable Jobs where key _= "__Jobs"

-- | if the state of the program is commited (saved) the created thread is restored
-- when the program is restarted by `initNode` as a job.
--
-- if the thread and all his children becomes inactive, the job is removed and the list of result are returned
job mx = do
  this@(idSession,_) <- local $ do
    idSession <- fromIntegral <$> genPersistId
    log <- getLog <|> error "job: no log"
    let this = (idSession,BC.pack $ show $ hashClosure log + 10000000) -- es la siguiente closure

    Jobs  pending <- liftIO $ atomically $ readDBRef rjobs `onNothing` return (Jobs[])
    liftIO $ print ("creating job",this)
    liftIO $ atomically $ writeDBRef rjobs $ Jobs $ this:pending
    return this

  local $ do
      (clos,_)<- setCont Nothing idSession 
      liftIO $ print $ localClos clos

  rs <- local $ collect 0 $ runCloud mx
  
  local $ remove this -- snd $ head rs
  return $  rs

  
  where

  remove conclos= liftIO $ atomically $ do
        unsafeIOToSTM $ print "REMOVE"
        Jobs  pending <- readDBRef rjobs `onNothing` return (Jobs [])
        writeDBRef rjobs $ Jobs  $ pending \\ [conclos]

rjobs = getDBRef "__Jobs"

runJobs= local $ fork $ do
    Jobs  pending <-liftIO $ atomically $ readDBRef rjobs `onNothing` return (Jobs  [])
    -- th <- liftIO myThreadId
    -- liftIO $ print ("runJobs",pending,th )
    (id,clos) <- choose pending
    noTrans $  restoreClosure id clos